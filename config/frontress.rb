# typed: false
# frozen_string_literal: true

# Everything that makes this serveme a Team Frontress serveme.
#
# The upstream project hosts Team Fortress 2 servers for a dozen leagues. This
# fork hosts exactly one game, and the difference is not a preference setting:
# the game directory, the AppIDs, the container image, the ruleset files and
# the coordinator that drives it all are fixed, and code that used to branch on
# "is this a TC2 server?" now simply reads these constants.
#
# Everything here is overridable from the environment, because the whole
# deployment story of this fork is one .env and `docker compose up`.
#
# It is required from config/application.rb rather than living in
# config/initializers, because config/environments/production.rb reads it and
# environment files are loaded before initializers. Nothing here touches Rails
# at load time -- only ENV -- so being that early is safe.
module Frontress
  # The game clients and dedicated servers both run as. This is what a Steam
  # auth ticket is issued for and what a GSLT is created against.
  APP_ID = Integer(ENV.fetch("FRONTRESS_APP_ID", 5_147_520))

  # The Steam *Tool* the dedicated payload ships in. It is only how the server
  # files are shipped and updated; the server still serves APP_ID.
  TOOL_APP_ID = Integer(ENV.fetch("FRONTRESS_TOOL_APP_ID", 5_150_320))

  # The mod directory, srcds' -game argument. TF2 is "tf"; we are "tc2".
  GAME_DIR = ENV.fetch("FRONTRESS_GAME_DIR", "tc2").freeze

  # The dedicated server process, for the "is it running" checks. The launcher
  # and the process are both tc2_linux64; srcds_run_64 is the wrapper script.
  SERVER_PROCESS = ENV.fetch("FRONTRESS_SERVER_PROCESS", "tc2_linux64").freeze

  # The container image every game server runs as. Building one is in
  # docker/frontress-server/.
  SERVER_IMAGE = ENV.fetch("FRONTRESS_SERVER_IMAGE", "ghcr.io/gru2007/frontress-server:latest").freeze

  # The image without its tag, and the registry it lives in. Split here rather
  # than in five call sites, because "everything after the last colon is the
  # tag" is wrong for a registry with a port in it.
  def self.server_image_repo
    name = SERVER_IMAGE
    head, sep, tail = name.rpartition(":")
    sep.present? && !tail.include?("/") ? head : name
  end

  # The registry host, or nil for Docker Hub's implicit one.
  def self.server_image_registry
    first = server_image_repo.split("/").first
    first if first&.include?(".") || first&.include?(":")
  end

  # The repository path inside the registry, e.g. "gru2007/frontress-server".
  def self.server_image_path
    parts = server_image_repo.split("/")
    server_image_registry ? parts.drop(1).join("/") : server_image_repo
  end

  # The build the fleet should be on, as steam.inf's PatchVersion. Empty means
  # "do not check": an unknown version must never be read as "everything is
  # outdated", which is how a fleet restarts itself.
  SERVER_VERSION = ENV["FRONTRESS_SERVER_VERSION"].presence&.to_i

  # The map a server boots on when a reservation does not name one. Upstream
  # used ctf_turbine, which is a Team Fortress map we do not ship.
  DEFAULT_MAP = ENV.fetch("FRONTRESS_DEFAULT_MAP", "koth_product_final").freeze

  # Where clients download maps from. Empty leaves sv_downloadurl unset, which
  # means players only get maps that are already in the image.
  FASTDL_URL = ENV.fetch("FRONTRESS_FASTDL_URL", "").freeze

  # The map list the container refreshes from at boot. It is served by this
  # app: /api/maps.txt.
  def self.maps_url
    ENV["FRONTRESS_MAPS_URL"].presence || "#{SITE_URL}/api/maps.txt"
  end

  # Where uploads live: maps, log zips, avatars.
  #
  # Upstream stores them in Cloudflare R2 and SeaweedFS, both of which are
  # configured through Rails credentials. A deployment without credentials --
  # which this fork's docker path deliberately supports -- used to get an S3
  # client built from nils, and *every* page that lists maps died on it with a
  # 500. So the default is the local disk, and object storage is opt-in.
  #
  # ACTIVE_STORAGE_SERVICE names a service from config/storage.yml; the
  # credential check keeps existing R2 deployments on R2 without setting it.
  def self.storage_service
    return ENV["ACTIVE_STORAGE_SERVICE"].to_sym if ENV["ACTIVE_STORAGE_SERVICE"].present?
    return :cloudflare if Rails.application.credentials.dig(:cloudflare, :access_key_id).present?

    :local
  end

  # Reservation zip files (logs and demos) are attached to their own service
  # upstream, because they are large and short-lived.
  def self.zipfile_storage_service
    return ENV["ZIPFILE_STORAGE_SERVICE"].to_sym if ENV["ZIPFILE_STORAGE_SERVICE"].present?
    return :seaweedfs if Rails.application.credentials.dig(:seaweedfs, :endpoint).present?

    storage_service
  end

  # The maps a server can be asked to play, when there is no object storage to
  # list. FRONTRESS_MAPS overrides; otherwise it is every map named in
  # config/league_maps.yml, which is the list this site's map picker, its
  # /api/maps.txt (which each container reads at boot) and its "does this map
  # exist" validation all agree on.
  def self.map_list
    from_env = ENV.fetch("FRONTRESS_MAPS", "").split(/[\s,]+/).reject(&:empty?)
    return from_env if from_env.any?

    LeagueMaps.all_league_maps
  rescue StandardError => e
    Rails.logger&.warn("Frontress.map_list: #{e.class}: #{e.message}")
    []
  end

  # The game coordinator. Reservations it creates are matchmaking reservations,
  # and the agent inside each container reports the match back to it.
  COORDINATOR_URL = ENV.fetch("FRONTRESS_COORDINATOR_URL", "").freeze
  COORDINATOR_SECRET = ENV.fetch("FRONTRESS_COORDINATOR_SECRET", "").freeze

  # The two rulesets a matchmade server can be asked to run. They are config
  # file names on the server, execed before the map change; the list is here so
  # a reservation cannot ask for something that does not exist.
  MATCH_MODES = %w[casual ranked].freeze
  MATCH_CONFIGS = {
    "casual" => "frontress_casual",
    "ranked" => "frontress_ranked"
  }.freeze

  # Ranked is the restricted queue, and the restriction that matters here is
  # that only the coordinator may book a ranked server: a ranked reservation
  # made by hand is a match with no roster and no result.
  def self.match_config_for(mode)
    MATCH_CONFIGS[mode.to_s] || MATCH_CONFIGS["casual"]
  end

  def self.coordinator_configured?
    COORDINATOR_URL.present? && COORDINATOR_SECRET.present?
  end
end
