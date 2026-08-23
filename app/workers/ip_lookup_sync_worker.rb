# typed: true
# frozen_string_literal: true

class IpLookupSyncWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 3

  REGIONS = {
    # Upstream keeps four sites in sync with each other. This fork is one
    # site; FRONTRESS_PEER_SITES ("eu=https://a,na=https://b") is here for a
    # community that grows into more, and empty means nothing is synced.
    **ENV.fetch("FRONTRESS_PEER_SITES", "").split(",").map(&:strip).reject(&:empty?).to_h { |pair|
      key, url = pair.split("=", 2)
      [ key.to_sym, url ]
    }
  }.freeze

  def perform(ip_lookup_id)
    return unless Rails.env.production?

    ip_lookup = IpLookup.find_by(id: ip_lookup_id)
    return unless ip_lookup

    sync_to_other_regions(ip_lookup)
  end

  private

  def sync_to_other_regions(ip_lookup)
    current_region = detect_current_region
    payload = build_payload(ip_lookup)

    REGIONS.each do |region_key, base_url|
      next if region_key == current_region

      sync_to_region(region_key, base_url, payload)
    end
  end

  def detect_current_region
    Frontress::REGION.downcase.to_sym
  end

  def build_payload(ip_lookup)
    {
      ip_lookup: {
        ip: ip_lookup.ip,
        is_proxy: ip_lookup.is_proxy,
        is_residential_proxy: ip_lookup.is_residential_proxy,
        fraud_score: ip_lookup.fraud_score,
        connection_type: ip_lookup.connection_type,
        isp: ip_lookup.isp,
        country_code: ip_lookup.country_code,
        raw_response: ip_lookup.raw_response,
        false_positive: ip_lookup.false_positive,
        is_banned: ip_lookup.is_banned,
        ban_reason: ip_lookup.ban_reason
      }
    }
  end

  def sync_to_region(region_key, base_url, payload)
    api_key = Rails.application.credentials.dig(:serveme, region_key)
    return unless api_key

    conn = Faraday.new(url: base_url) do |f|
      f.request :json
      f.response :json
      f.options.timeout = 10
      f.options.open_timeout = 5
    end

    response = conn.post("/api/ip_lookups") do |req|
      req.headers["Authorization"] = "Bearer #{api_key}"
      req.body = payload
    end

    unless response.success?
      Rails.logger.warn "[IpLookupSync] Failed to sync to #{region_key}: #{response.status}"
    end
  rescue Faraday::Error => e
    Rails.logger.warn "[IpLookupSync] Error syncing to #{region_key}: #{e.message}"
  end
end
