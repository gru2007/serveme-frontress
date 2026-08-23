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
# Named 00_ so it is loaded before anything that reads it.
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

if Frontress::COORDINATOR_URL.blank? && !Rails.env.test?
  Rails.logger&.info(
    "No game coordinator configured. Reservations still work; matchmaking has nothing to talk to. " \
    "Set FRONTRESS_COORDINATOR_URL and FRONTRESS_COORDINATOR_SECRET to connect one."
  )
end
