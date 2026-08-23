# typed: true
# frozen_string_literal: true

# Frontress is defined in config/initializers/00_frontress.rb. Initializers are
# not part of what Tapioca walks, so the module is declared here the same way
# STEAM_API_KEY, SITE_URL and MAPS_DIR are.

module Frontress
  APP_ID = ::T.let(nil, ::T.untyped)
  TOOL_APP_ID = ::T.let(nil, ::T.untyped)
  GAME_DIR = ::T.let(nil, ::T.untyped)
  SERVER_PROCESS = ::T.let(nil, ::T.untyped)
  SERVER_IMAGE = ::T.let(nil, ::T.untyped)
  SERVER_VERSION = ::T.let(nil, ::T.untyped)
  DEFAULT_MAP = ::T.let(nil, ::T.untyped)
  FASTDL_URL = ::T.let(nil, ::T.untyped)
  COORDINATOR_URL = ::T.let(nil, ::T.untyped)
  COORDINATOR_SECRET = ::T.let(nil, ::T.untyped)
  MATCH_MODES = ::T.let(nil, ::T.untyped)
  MATCH_CONFIGS = ::T.let(nil, ::T.untyped)

  def self.server_image_repo; end
  def self.server_image_registry; end
  def self.server_image_path; end
  def self.maps_url; end
  def self.match_config_for(mode); end
  def self.coordinator_configured?; end
end
