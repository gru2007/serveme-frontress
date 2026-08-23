# typed: true
# frozen_string_literal: true

# STEAM_API_KEY is set in config/initializers/00_steam_api_key.rb. Initializers
# are not part of what Tapioca walks, so the constant is declared here the same
# way hidden-definitions declares SITE_URL and MAPS_DIR.

class Object
  STEAM_API_KEY = ::T.let(nil, ::T.untyped)
end
