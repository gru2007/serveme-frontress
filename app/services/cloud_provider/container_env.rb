# typed: strict
# frozen_string_literal: true

require "shellwords"

module CloudProvider
  # Single source of truth for the env-var contract the frontress-server
  # container expects. Two modes:
  #
  #   :vm    — one container per VM (Hetzner/Vultr/Kamatera cloud-init).
  #            SSH_PORT is fixed at 2222 and no game-port offsets are emitted
  #            because the container uses the default 27015 set.
  #   :multi — many containers share a host (Docker/RemoteDocker). Each
  #            container gets a port-offset slot derived from its game port.
  class ContainerEnv
    extend T::Sig

    DEFAULT_VM_SSH_PORT = "2222"

    # The base for srcds' own client port. It must not be 40001: that is the
    # port serveme's log daemon listens on, and on a one-box deployment -- the
    # site and the game servers on the same machine, which is the default here
    # -- the first container would take it and the log daemon would never see a
    # line. Containers run on the host's network, so a collision is a real one.
    CLIENT_PORT_BASE = 41_001
    STEAM_PORT_BASE = 30_001
    SSH_PORT_BASE = 22_000

    sig { params(cloud_server: CloudServer, ssh_public_key: T.nilable(String), mode: Symbol).returns(T::Hash[String, T.untyped]) }
    def self.build(cloud_server, ssh_public_key:, mode:)
      new(cloud_server, ssh_public_key, mode).build
    end

    # Renders the env hash as ["-e", "K=V"] argv pairs for system(*argv).
    sig { params(env: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.to_argv_pairs(env)
      env.flat_map { |k, v| [ "-e", "#{k}=#{v}" ] }
    end

    # Renders the env hash as shell-quoted "-e K=V" tokens for SSH/heredoc use.
    # Only the value is escaped, so "K=V" stays grep-able.
    sig { params(env: T::Hash[String, T.untyped]).returns(T::Array[String]) }
    def self.to_shell_args(env)
      env.map { |k, v| "-e #{k}=#{Shellwords.shellescape(v)}" }
    end

    sig { params(cloud_server: CloudServer, ssh_public_key: T.nilable(String), mode: Symbol).void }
    def initialize(cloud_server, ssh_public_key, mode)
      @cloud_server = cloud_server
      @ssh_public_key = ssh_public_key
      @mode = mode
      @discord_webhook = T.let(nil, T.nilable(String))
      @reservation = T.let(nil, T.nilable(Reservation))
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def build
      env = {
        "CALLBACK_URL"        => callback_url,
        "CALLBACK_TOKEN"      => @cloud_server.cloud_callback_token,
        "SSH_AUTHORIZED_KEYS" => @ssh_public_key,
        "RCON_PASSWORD"       => @cloud_server.rcon
      }
      env.merge!(port_env)
      env["GAME_DIR"] = Frontress::GAME_DIR
      env["MAPLIST_URL"] = Frontress.maps_url
      env["FASTDL_URL"] = Frontress::FASTDL_URL if Frontress::FASTDL_URL.present?
      # Only a configured expected version is passed on. The container reads an
      # empty one as "the payload you were built with is the payload you run",
      # which is what a deployment without a version feed wants.
      env["EXPECTED_SERVER_VERSION"] = Frontress::SERVER_VERSION.to_s if Frontress::SERVER_VERSION

      res = reservation
      if res
        env["ENABLE_PLUGINS"] = res.plugins_enabled? ? "1" : "0"
        env.merge!(match_env(res))
      end
      env["DISCORD_STAC_WEBHOOK_URL"] = discord_webhook if discord_webhook.present?
      if (token = gslt)
        env["GSLT"] = token
      end
      env
    end

    private

    # What a matchmaking reservation adds to a container.
    #
    # The map, the password and the ruleset are already in reservation.cfg, so
    # they are not repeated here. What the container cannot get from a config
    # file is where to report the result: the agent inside it needs the
    # coordinator's address and its shared secret, and it needs to know which
    # match this server is running before the first log line arrives.
    sig { params(res: Reservation).returns(T::Hash[String, String]) }
    def match_env(res)
      return {} unless res.match_id.present? && Frontress.coordinator_configured?

      {
        "GC_URL" => Frontress::COORDINATOR_URL,
        "GC_SECRET" => Frontress::COORDINATOR_SECRET,
        "MATCH_ID" => res.match_id.to_s,
        "MATCH_MODE" => res.match_mode.to_s,
        "SERVER_CONNECT" => res.server&.public_ip ? "#{res.server&.public_ip}:#{res.server&.public_port}" : ""
      }
    end

    sig { returns(T::Hash[String, String]) }
    def port_env
      case @mode
      when :vm
        { "SSH_PORT" => DEFAULT_VM_SSH_PORT }
      when :multi
        game = @cloud_server.port.to_i
        offset = (game - 27015) / 10
        {
          "PORT"        => game.to_s,
          "TV_PORT"     => (game + 5).to_s,
          "SSH_PORT"    => (SSH_PORT_BASE + offset).to_s,
          "CLIENT_PORT" => (CLIENT_PORT_BASE + offset).to_s,
          "STEAM_PORT"  => (STEAM_PORT_BASE + offset).to_s
        }
      else
        raise ArgumentError, "unknown ContainerEnv mode: #{@mode.inspect}"
      end
    end

    # A Game Server Login Token for the game's AppID. Without one a server runs,
    # but players connect with no inventory.
    #
    # A token belongs to one running server at a time -- two servers presenting
    # the same one knock each other off Steam -- so FRONTRESS_GSLT takes a
    # comma-separated list and each container gets the one for its port slot.
    # One token is fine for one server at a time; a host running four wants
    # four.
    sig { returns(T.nilable(String)) }
    def gslt
      tokens = ENV.fetch("FRONTRESS_GSLT", "").split(",").map(&:strip).reject(&:empty?)
      return nil if tokens.empty?

      slot = (@cloud_server.port.to_i - 27_015) / 10
      tokens[slot % tokens.size]
    end

    sig { returns(T.nilable(Reservation)) }
    def reservation
      @reservation ||= Reservation.find_by(id: @cloud_server.cloud_reservation_id)
    end

    sig { returns(String) }
    def callback_url
      callback_host = ENV["CLOUD_CALLBACK_HOST"].presence
      base_url = if callback_host
        if callback_host.start_with?("http://", "https://")
          callback_host
        else
          scheme = SITE_URL.start_with?("http://") ? "http" : "https"
          "#{scheme}://#{callback_host}"
        end
      else
        SITE_URL
      end

      "#{base_url.chomp('/')}/api/cloud_servers/#{@cloud_server.id}/ready"
    end

    sig { returns(T.nilable(String)) }
    def discord_webhook
      @discord_webhook ||= ENV["DISCORD_STAC_WEBHOOK_URL"] ||
                           Rails.application.credentials.dig(:discord, :stac_webhook_url)
    end
  end
end
