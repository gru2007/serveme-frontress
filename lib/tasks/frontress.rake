# frozen_string_literal: true

namespace :frontress do
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
      "Map list" => Frontress.maps_url,
      "Maps known" => MapUpload.available_maps.size,
      "Uploads" => Frontress.storage_service,
      "Local docker" => CloudProvider::Docker.enabled? ? "on (max #{CloudProvider::Docker.max_containers} containers)" : "off",
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
