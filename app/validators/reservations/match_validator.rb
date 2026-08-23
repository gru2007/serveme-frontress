# typed: true
# frozen_string_literal: true

module Reservations
  # Guards the matchmaking fields on a reservation.
  #
  # A matchmaking reservation is not a booking with extra labels: the match id
  # ends up in sv_tags, the mode picks the ruleset the server execs, and the
  # agent inside the container reports the result to the coordinator against
  # that id. All three are how a match is scored, so who may set them matters.
  #
  # Ranked is the strict case. A ranked reservation made by hand is a server
  # running the ranked ruleset with no roster behind it, and any result it
  # reports is a result against a match the coordinator never formed. So only
  # the coordinator -- a trusted API user, or an admin -- may create one.
  class MatchValidator < ActiveModel::Validator
    def validate(record)
      mode = record.match_mode.presence
      if mode && !Frontress::MATCH_MODES.include?(mode)
        record.errors.add(:match_mode, "must be one of: #{Frontress::MATCH_MODES.join(', ')}")
      end

      if record.match_id.present? && record.match_id.to_s.length > 64
        record.errors.add(:match_id, "is too long")
      end

      if mode.present? && record.match_id.blank?
        record.errors.add(:match_id, "is required for a match reservation")
      end

      return unless record.ranked?
      return if trusted?(record.user)

      record.errors.add(:match_mode, "ranked reservations can only be made by the game coordinator")
    end

    private

    def trusted?(user)
      return false unless user

      user.admin? || user.trusted_api?
    end
  end
end
