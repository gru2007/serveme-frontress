# frozen_string_literal: true

namespace :frontress do
  # Can this process actually start a container? The two ways it cannot are a
  # socket it may not open and an image that does not exist, and both look
  # identical from the reservation page: "failed to create server".
  def local_docker_status
    return "off" unless CloudProvider::Docker.enabled?

    require "open3"
    out, status = Open3.capture2e("docker", "version", "--format", "{{.Server.Version}}")
    unless status.success?
      hint = out.to_s.strip.lines.last.to_s.strip
      hint += " (set DOCKER_GID in .env to the host's docker group)" if hint.include?("permission denied")
      return "UNUSABLE: #{hint}"
    end

    image, image_status = Open3.capture2e("docker", "image", "inspect", "--format", "{{.Id}}", Frontress::SERVER_IMAGE)
    unless image_status.success?
      return "daemon #{out.strip}, but the image is not pulled yet (#{image.to_s.strip.lines.last.to_s.strip})"
    end

    "daemon #{out.strip}, image present (max #{CloudProvider::Docker.max_containers} containers)"
  rescue Errno::ENOENT
    "UNUSABLE: no docker CLI in this container"
  end

  # Where the SSH key comes from, which is the difference between "servers can
  # be configured" and a provisioning failure with a confusing message.
  def ssh_key_source
    return "tmp/cloud_ssh_key" if File.exist?(Rails.root.join("tmp", "cloud_ssh_key"))
    return "FRONTRESS_SSH_PRIVATE_KEY" if ENV["FRONTRESS_SSH_PRIVATE_KEY"].present?
    return "credentials" if Rails.application.credentials.dig(:cloud_servers, :ssh_private_key).present?
    return "generated (site_settings)" if SiteSetting.get(Frontress::SSH_KEY_SETTING).present?

    "generated on first use"
  end

  desc "Show the effective Team Frontress configuration"
  task doctor: :environment do
    rows = {
      "Game AppID" => Frontress::APP_ID,
      "Dedicated Tool AppID" => Frontress::TOOL_APP_ID,
      "Game directory" => Frontress::GAME_DIR,
      "Server image" => Frontress::SERVER_IMAGE,
      "Expected build" => Frontress::SERVER_VERSION || "(not checked)",
      "Default map" => Frontress::DEFAULT_MAP,
      "FastDL" => Frontress::FASTDL_URL.presence || "(none: clients get only what the image ships)",
      "Site" => SITE_URL,
      "Servers reach us at" => Frontress.direct_host,
      "Logs go to" => Frontress.log_address,
      "Map list" => Frontress.maps_url,
      "Maps known" => MapUpload.available_maps.size,
      "Uploads" => Frontress.storage_service,
      "SSH key" => ssh_key_source,
      "Local docker" => local_docker_status,
      "Container sees us as" => ENV["DOCKER_HOST_IP"].presence || "(DOCKER_HOST_IP unset)",
      "Callback host" => ENV["CLOUD_CALLBACK_HOST"].presence || SITE_HOST,
      "Remote docker hosts" => DockerHost.active.count,
      "Coordinator" => Frontress::COORDINATOR_URL.presence || "(none)",
      "Coordinator secret" => Frontress::COORDINATOR_SECRET.present? ? "set" : "(missing)"
    }
    width = rows.keys.map(&:length).max
    rows.each { |k, v| puts "#{k.ljust(width)}  #{v}" }

    puts
    if Frontress.coordinator_configured?
      puts "Matchmaking is wired up. The coordinator books servers through /api/reservations,"
      puts "and the agent in each container reports results to #{Frontress::COORDINATOR_URL}."
    else
      puts "No coordinator configured: reservations work, matchmaking has nothing to talk to."
      puts "Set FRONTRESS_COORDINATOR_URL and FRONTRESS_COORDINATOR_SECRET."
    end
  end

  desc "Print the SSH public key this site uses to reach game servers"
  task ssh_key: :environment do
    puts Frontress.ssh_public_key
    puts
    puts "Game server containers get this automatically. A docker host you add"
    puts "by hand needs it in root's ~/.ssh/authorized_keys."
  end

  # "No server available" from the coordinator only ever means find_servers
  # answered with an empty list, and that one answer covers half a dozen very
  # different situations. This asks each of them separately, as the coordinator's
  # own user and over the window it actually books.
  desc "Why matchmaking cannot get a server (API_KEY=... [MINUTES=180])"
  task availability: :environment do
    key = ENV["API_KEY"].presence
    user = key ? User.find_by(api_key: key) : User.joins(:group_users).find_by(group_users: { group_id: Group.trusted_api_group.id })
    minutes = Integer(ENV.fetch("MINUTES", "180"))
    starts_at = Time.current
    ends_at = minutes.minutes.from_now

    unless user
      abort "No user to check. Pass API_KEY= the coordinator's key, or run frontress:coordinator_key first."
    end

    puts "As #{user.nickname} (donator: #{user.donator?}, trusted api: #{user.trusted_api?})"
    puts "For #{starts_at} .. #{ends_at} (#{minutes} minutes, from the coordinator's pool.max_match_secs)"
    puts

    limit = SiteSetting.free_server_limit
    reached = SiteSetting.free_server_limit_reached?(user, starts_at, ends_at)
    overlapping = SiteSetting.free_user_reservation_count(starts_at, ends_at)

    local = CloudProvider::Docker.enabled? ? CloudProvider::Docker.available_during?(starts_at, ends_at) : false
    containers = CloudProvider::Docker.enabled? ? CloudProvider::Docker.container_count_during(starts_at, ends_at) : 0
    hosts = DockerHost.available_during(starts_at, ends_at).count
    bare = ServerForUserFinder.new(user, starts_at, ends_at).servers.count

    rows = {
      "free_server_limit" => limit.nil? ? "(unset: no quota)" : limit,
      "limit reached for this user" => reached,
      "overlapping non-donator reservations" => overlapping,
      "local docker" => CloudProvider::Docker.enabled? ? "on, #{containers}/#{CloudProvider::Docker.max_containers} containers booked" : "off",
      "local docker offerable" => local,
      "remote docker hosts free" => hosts,
      "bare-metal servers free" => bare
    }
    width = rows.keys.map(&:length).max
    rows.each { |k, v| puts "#{k.ljust(width)}  #{v}" }

    puts
    offered = (local ? 1 : 0) + hosts + bare
    if offered.positive?
      puts "find_servers would offer #{offered} server(s). Matchmaking should be able to book one."
    elsif reached
      puts "Nothing is offered because this user's free-server quota is spent, not because the"
      puts "machines are busy: every non-donator reservation overlapping the window counts, and"
      puts "the coordinator books #{minutes} minutes at a time. Either put the coordinator's user in"
      puts "the donator group, raise free_server_limit, or clear the reservations still holding it."
    else
      puts "Nothing is offered and no quota is in the way: every server really is booked for that"
      puts "window. Reservations that never ended hold their server for the full booking, so check"
      puts "for stale ones -- Reservation.where('ends_at > ?', Time.current).order(:id)."
    end
  end

  desc "Create (or show) the game coordinator's API user and key"
  task coordinator_key: :environment do
    uid = ENV.fetch("COORDINATOR_STEAM_UID", "76561197960265728") # the anonymous account, as a placeholder identity
    user = User.find_or_initialize_by(uid: uid)
    if user.new_record?
      user.nickname = "Game Coordinator"
      user.name = "Game Coordinator"
      user.provider = "steam"
      user.password = SecureRandom.hex(32) if user.respond_to?(:password=)
      user.save!
      puts "Created the coordinator user (uid #{uid})."
    end

    # Trusted API is what lets it book ranked servers: MatchValidator refuses a
    # ranked reservation from anybody else, because a ranked match nobody
    # formed still reports a result.
    unless user.trusted_api?
      user.groups << Group.trusted_api_group
      puts "Added it to the Trusted API group."
    end

    key = user.api_key.presence || user.generate_api_key!
    puts
    puts "Put this in the coordinator's serveme provider:"
    puts
    puts %(  { "kind": "serveme", "base_url": "#{SITE_URL}", "api_key": "#{key}", "prefer_docker": true })
  end
end
