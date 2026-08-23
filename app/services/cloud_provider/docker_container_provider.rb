# typed: strict
# frozen_string_literal: true

require "shellwords"

module CloudProvider
  # Shared logic for providers that drive `docker run` directly on an
  # existing host (rather than provisioning a fresh VM). Subclasses
  # supply the executor (local exec vs SSH).
  class DockerContainerProvider < Base
    sig { override.returns(T::Boolean) }
    def self.vm?
      false
    end

    sig { params(cloud_server: CloudServer).returns(String) }
    def container_name(cloud_server)
      "res-#{cloud_server.cloud_reservation_id}-cloud-#{cloud_server.id}"
    end

    sig { overridable.returns(String) }
    def docker_image
      Frontress::SERVER_IMAGE
    end

    # The seccomp profile srcds needs. A host set up by DockerHostSetupService
    # has it; a laptop running `docker compose up` does not, and docker refuses
    # to start a container whose profile file is missing. So it is used when it
    # is there and skipped when it is not, rather than being a step every
    # machine has to be prepared with -- which is the whole point of the
    # docker-first deployment.
    SECCOMP_PROFILE = "/etc/docker/seccomp-tf2.json"

    sig { returns(T::Boolean) }
    def seccomp_profile?
      File.exist?(SECCOMP_PROFILE)
    end

    # Argv for local exec: each element is one argv slot, no shell escaping.
    sig { params(cloud_server: CloudServer).returns(T::Array[String]) }
    def docker_run_argv(cloud_server)
      [
        "docker", "run", "-d", "--net=host",
        *(seccomp_profile? ? [ "--security-opt", "seccomp=#{SECCOMP_PROFILE}" ] : []),
        "--name", container_name(cloud_server),
        *ContainerEnv.to_argv_pairs(env_hash(cloud_server)),
        docker_image
      ]
    end

    # Single shell string for SSH exec. Values are shell-escaped; flag
    # names stay literal so SigNoz greps keep working.
    sig { params(cloud_server: CloudServer).returns(String) }
    def docker_run_command(cloud_server)
      parts = [
        "docker run -d --net=host",
        # Remote hosts are provisioned by DockerHostSetupService, which writes
        # the profile, so this one stays unconditional.
        "--security-opt seccomp=#{SECCOMP_PROFILE}",
        "--name #{Shellwords.shellescape(container_name(cloud_server))}",
        *ContainerEnv.to_shell_args(env_hash(cloud_server)),
        docker_image
      ]
      parts.join(" ")
    end

    sig { params(raw: T.nilable(String)).returns(String) }
    def parse_docker_state(raw)
      case raw.to_s.strip
      when "running" then "running"
      when "created", "restarting" then "provisioning"
      when "exited", "dead", "removing" then "stopped"
      else "provisioning"
      end
    end

    private

    sig { params(cloud_server: CloudServer).returns(T::Hash[String, T.untyped]) }
    def env_hash(cloud_server)
      ContainerEnv.build(
        cloud_server,
        ssh_public_key: cloud_server.cloud_ssh_public_key,
        mode: :multi
      )
    end
  end
end
