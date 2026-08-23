# typed: false
# frozen_string_literal: true

# Frontress itself is loaded from config/application.rb, before there is a
# logger to talk to. This is the part that has something to say.
if Frontress::COORDINATOR_URL.blank? && !Rails.env.test?
  Rails.logger&.info(
    "No game coordinator configured. Reservations still work; matchmaking has nothing to talk to. " \
    "Set FRONTRESS_COORDINATOR_URL and FRONTRESS_COORDINATOR_SECRET to connect one."
  )
end
