# typed: true
# frozen_string_literal: true

module Reservations
  class CloudServerConcurrencyValidator < ActiveModel::Validator
    def validate(record)
      return unless record.user
      return unless record.server&.cloud?
      return if record.server.cloud_provider.in?(%w[docker remote_docker])
      # One cloud server at a time is a per-person rule. The coordinator runs
      # as many matches as the pool allows, each on its own server, so the same
      # rule applied to it means the second concurrent match never gets one.
      return if record.user.trusted_api?

      active = record.user.active_cloud_reservation
      return unless active
      return if active.id == record.id

      record.errors.add(:server, "you already have an active cloud server")
    end
  end
end
