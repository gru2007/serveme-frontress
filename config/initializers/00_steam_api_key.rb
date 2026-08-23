# typed: false
# frozen_string_literal: true

# The Steam Web API key, from an environment variable or from Rails
# credentials, in that order.
#
# It is the one secret a serveme deployment cannot do without -- Steam sign-in
# is the only way in -- so it should not be the one secret that forces you to
# set up encrypted credentials. Reading it from the environment first is the
# same order the rest of this app already uses for IPQS, Fraudlogix and the
# cloud providers.
#
# Named 00_ so it is loaded before omni_auth.rb and steam_condenser.rb, which
# both need it.
STEAM_API_KEY = (
  ENV["STEAM_API_KEY"].presence || Rails.application.credentials.dig(:steam, :api_key)
).freeze

if STEAM_API_KEY.blank? && !Rails.env.test?
  Rails.logger&.warn(
    "No Steam API key. Set STEAM_API_KEY, or add steam.api_key to Rails credentials. " \
    "Steam sign-in will not work until you do."
  )
end
