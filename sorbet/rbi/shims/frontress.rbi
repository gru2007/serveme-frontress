# typed: true
# frozen_string_literal: true

# Frontress is defined in config/frontress.rb, required from
# config/application.rb. Config files are not part of what Tapioca walks, so
# the module is declared here the same way STEAM_API_KEY, SITE_URL and
# MAPS_DIR are.

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
  SERVER_USER = ::T.let(nil, ::T.untyped)
  SSH_KEY_SETTING = ::T.let(nil, ::T.untyped)
  DISCORD_URL = ::T.let(nil, ::T.untyped)
  DISCORD_COMMAND = ::T.let(nil, ::T.untyped)
  SOURCE_URL = ::T.let(nil, ::T.untyped)
  TRADE_URL = ::T.let(nil, ::T.untyped)
  REGION = ::T.let(nil, ::T.untyped)

  def self.server_image_repo; end
  def self.server_image_registry; end
  def self.server_image_path; end
  def self.maps_url; end
  def self.match_config_for(mode); end
  def self.coordinator_configured?; end
  def self.storage_service; end
  def self.zipfile_storage_service; end
  def self.map_list; end
  def self.ssh_private_key; end
  def self.ssh_public_key; end
  def self.ssh_private_key_from_file; end
  def self.generated_ssh_private_key; end
  def self.direct_host; end
  def self.log_address; end
end
