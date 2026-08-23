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

    # The port the first container on this machine gets; CloudServer counts up
    # from here per container. Shown before a reservation exists, when which
    # port it will land on is not known yet.
    DEFAULT_GAME_PORT = 27015

    # The address players connect to for a container started here. --net=host
    # means it is the machine's own address, which is what DOCKER_HOST_IP names
    # and what server_ip hands back once the container is up.
    sig { returns(String) }
    def self.public_host
      ENV["DOCKER_HOST_IP"].presence || Frontress.direct_host
    end

    # This machine's container capacity as one pickable "server". The web form,
    # the JSON API and the coordinator all offer the same entry, so it is
    # described once here instead of in three views that drift apart.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.virtual_server_entry
      host = public_host
      {
        id: LOCAL_VIRTUAL_SERVER_ID,
        name: "Local (Docker)",
        flag: LOCATIONS.fetch("local").fetch(:flag),
        ip: host,
        port: DEFAULT_GAME_PORT.to_s,
        ip_and_port: "#{host}:#{DEFAULT_GAME_PORT}",
        resolved_ip: nil,
        sdr: false,
        latitude: nil,
        longitude: nil
      }
    end

    # Total slots, for the "x / y servers available" counters. Zero when local
    # containers are switched off, so the totals do not advertise capacity that
    # cannot be booked.
    sig { returns(Integer) }
    def self.total_slots
      enabled? ? max_containers : 0
    end

    sig { params(starts_at: T.any(Time, ActiveSupport::TimeWithZone), ends_at: T.any(Time, ActiveSupport::TimeWithZone)).returns(Integer) }
    def self.slots_available_during(starts_at, ends_at)
      return 0 unless enabled?

      [ max_containers - container_count_during(starts_at, ends_at), 0 ].max
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

    # Steam Linux Runtime 3 launches the dedicated server through
    # pressure-vessel/bubblewrap. That inner sandbox creates user/mount
    # namespaces, which Docker's default seccomp profile blocks. On hosts where
    # the Docker daemon uses AppArmor (notably Ubuntu/Debian), docker-default
    # blocks the same operation as well. Relax only those two outer-container
    # policies for the game server; this is deliberately not --privileged and
    # does not add CAP_SYS_ADMIN.
    sig { override.returns(T::Array[String]) }
    def docker_run_security_argv
      args = [ "--security-opt", "seccomp=unconfined" ]
      args.concat([ "--security-opt", "apparmor=unconfined" ]) if docker_apparmor_enabled?
      args
    end

    sig { override.params(cloud_server: CloudServer).returns(String) }
    def create_server(cloud_server)
      Rails.logger.info "Docker: Creating container for cloud_server #{cloud_server.id}"
      name = container_name(cloud_server)
      # capture2e, not system: what docker said is the whole diagnosis. "failed
      # to start" on its own sent people looking at the game image when the
      # real answer was one line about the socket's permissions.
      output, status = Open3.capture2e(*T.unsafe(docker_run_argv(cloud_server)))
      raise "Docker container failed to start: #{name}: #{docker_error_hint(output)}" unless status.success?

      Rails.logger.info "Docker: Created container #{name}"
      name
    end

    # Turns docker's own error into something an operator can act on.
    sig { params(output: String).returns(String) }
    def docker_error_hint(output)
      message = output.to_s.strip.lines.last.to_s.strip
      if message.include?("permission denied") && message.include?("docker.sock")
        return "#{message} -- this app is not in the host's docker group. " \
               "Set DOCKER_GID in .env to `getent group docker | cut -d: -f3` and restart."
      end
      if message.match?(/no such (image|host)|not found|manifest unknown/i)
        return "#{message} -- the image #{docker_image} could not be pulled. Build or push it first."
      end

      message.presence || "docker said nothing"
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

    sig { returns(T::Boolean) }
    def docker_apparmor_enabled?
      return @docker_apparmor_enabled unless @docker_apparmor_enabled.nil?

      output, status = Open3.capture2("docker", "info", "--format", "{{json .SecurityOptions}}")
      @docker_apparmor_enabled = T.let(status.success? && output.include?("apparmor"), T.nilable(T::Boolean))
      @docker_apparmor_enabled || false
    rescue StandardError => e
      Rails.logger.warn("Docker: could not detect AppArmor support: #{e.class}: #{e.message}")
      @docker_apparmor_enabled = T.let(false, T.nilable(T::Boolean))
      false
    end

    sig { returns(String) }
    def detect_host_ip
      output, = Open3.capture2("hostname", "-I")
      output.split.first || "127.0.0.1"
    end
  end
end
