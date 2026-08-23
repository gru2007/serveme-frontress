# typed: true
# frozen_string_literal: true

require "open3"

module CloudProvider
  # Containers on the machine this app runs on.
  #
  # It is the deployment this fork is built around: one box, `docker compose
  # up`, and game servers as containers next to the site. There is no host to
  # provision, no SSH key to distribute and no cloud account -- the docker
  # socket is already there.
  #
  # Enabled with FRONTRESS_LOCAL_DOCKER=1 (and always in development). The app
  # needs the docker socket mounted to use it, which docker-compose.yml does.
  class Docker < DockerContainerProvider
    LOCATIONS = T.let({
      "local" => { name: "Local", country: "LAN", region: "LAN", flag: "eu" }
    }.freeze, T::Hash[String, T::Hash[Symbol, String]])

    # The id the API hands out for "a container here". DockerHost numbers its
    # own virtual servers from 1e9; this sits above them so the two can never
    # be confused for one another.
    LOCAL_VIRTUAL_SERVER_ID = 2_000_000_000

    sig { returns(T::Boolean) }
    def self.enabled?
      ENV["FRONTRESS_LOCAL_DOCKER"].present? || Rails.env.development?
    end

    sig { params(server_id: T.any(String, Integer)).returns(T::Boolean) }
    def self.local_server_id?(server_id)
      server_id.to_i == LOCAL_VIRTUAL_SERVER_ID
    end

    # How many containers this machine will run at once. A box that can host
    # four 24-slot servers is not the same box as one that can host twenty.
    sig { returns(Integer) }
    def self.max_containers
      Integer(ENV.fetch("FRONTRESS_LOCAL_DOCKER_MAX_CONTAINERS", 4))
    end

    sig { params(starts_at: T.any(Time, ActiveSupport::TimeWithZone), ends_at: T.any(Time, ActiveSupport::TimeWithZone)).returns(Integer) }
    def self.container_count_during(starts_at, ends_at)
      Reservation.joins(:server)
        .where(servers: { type: "CloudServer", cloud_provider: "docker" })
        .where.not(servers: { cloud_status: "destroyed" })
        .where("reservations.starts_at < ? AND reservations.ends_at > ?", ends_at, starts_at)
        .count
    end

    sig { params(starts_at: T.any(Time, ActiveSupport::TimeWithZone), ends_at: T.any(Time, ActiveSupport::TimeWithZone)).returns(T::Boolean) }
    def self.available_during?(starts_at, ends_at)
      return false unless enabled?

      container_count_during(starts_at, ends_at) < max_containers
    end

    sig { override.params(cloud_server: CloudServer).returns(String) }
    def create_server(cloud_server)
      Rails.logger.info "Docker: Creating container for cloud_server #{cloud_server.id}"
      name = container_name(cloud_server)
      success = system(*T.unsafe(docker_run_argv(cloud_server)))
      raise "Docker container failed to start: #{name}" unless success

      Rails.logger.info "Docker: Created container #{name}"
      name
    end

    sig { override.returns(String) }
    def estimated_provision_time
      "less than a minute"
    end

    sig { override.params(provider_id: String).returns(String) }
    def server_status(provider_id)
      output, status = Open3.capture2("docker", "inspect", "-f", "{{.State.Status}}", provider_id)
      return "provisioning" unless status.success?

      parse_docker_state(output)
    end

    sig { override.params(_provider_id: String).returns(T.nilable(String)) }
    def server_ip(_provider_id)
      @server_ip ||= ENV.fetch("DOCKER_HOST_IP") { detect_host_ip }
    end

    sig { override.params(provider_id: String).returns(T::Boolean) }
    def destroy_server(provider_id)
      Rails.logger.info "Docker: Destroying container #{provider_id}"
      result = system("docker", "rm", "-f", provider_id) || false
      Rails.logger.info "Docker: Destroy container #{provider_id} result: #{result}"
      result
    end

    private

    sig { returns(String) }
    def detect_host_ip
      output, = Open3.capture2("hostname", "-I")
      output.split.first || "127.0.0.1"
    end
  end
end
