# typed: true
# frozen_string_literal: true

# Asks the registry what the current game server image is.
#
# Two registries are understood, because the image can live in either: Docker
# Hub (the upstream project's home) and GHCR (ours). Anything else answers nil,
# and every caller treats nil as "unknown" and carries on -- image readiness is
# fail-open by design.
class DockerImageRegistryClient
  extend T::Sig


  # The content digest of the :latest manifest, or nil on failure.
  sig { returns(T.nilable(String)) }
  def fetch_digest
    token = fetch_token
    return nil unless token

    manifest_response = registry_connection.head("/v2/#{image}/manifests/latest") do |req|
      req.headers["Authorization"] = "Bearer #{token}"
      req.headers["Accept"] = "application/vnd.docker.distribution.manifest.v2+json"
    end

    manifest_response.headers["docker-content-digest"]
  rescue Faraday::Error, JSON::ParserError => e
    Rails.logger.warn "DockerImageRegistryClient: Failed to check registry: #{e.message}"
    nil
  end

  # The highest numeric (build version) tag in the registry as a string, or nil
  # when there are no version tags or the lookup fails.
  sig { returns(T.nilable(String)) }
  def fetch_latest_version_tag
    token = fetch_token
    return nil unless token

    tags_response = registry_connection.get("/v2/#{image}/tags/list") do |req|
      req.headers["Authorization"] = "Bearer #{token}"
    end
    return nil unless tags_response.success?

    tags = JSON.parse(tags_response.body)["tags"] || []
    tags.select { |tag| tag.match?(/\A\d+\z/) }.map(&:to_i).max&.to_s
  rescue Faraday::Error, JSON::ParserError => e
    Rails.logger.warn "DockerImageRegistryClient: Failed to fetch tags: #{e.message}"
    nil
  end

  private

  # Read from Frontress at call time rather than frozen into constants: which
  # image this deployment runs is an environment question, and a test that
  # cannot change it is a test that only works on one registry.
  sig { returns(String) }
  def image
    Frontress.server_image_path
  end

  sig { returns(T.nilable(String)) }
  def registry
    Frontress.server_image_registry
  end

  # Memoized so a single client instance reuses one token across calls
  # (e.g. DockerImagePollWorker calls fetch_digest + fetch_latest_version_tag).
  sig { returns(T.nilable(String)) }
  def fetch_token
    @token ||= begin
      auth_conn = Faraday.new(url: ghcr? ? "https://ghcr.io" : "https://auth.docker.io") do |f|
        f.options.timeout = 10
        f.options.open_timeout = 5
      end
      path = if ghcr?
        "/token?scope=repository:#{image}:pull"
      else
        "/token?service=registry.docker.io&scope=repository:#{image}:pull"
      end
      token_response = auth_conn.get(path)
      JSON.parse(token_response.body)["token"] if token_response.success?
    end
  end

  sig { returns(T::Boolean) }
  def ghcr?
    registry == "ghcr.io"
  end

  sig { returns(Faraday::Connection) }
  def registry_connection
    Faraday.new(url: ghcr? ? "https://ghcr.io" : "https://registry-1.docker.io") do |f|
      f.options.timeout = 10
      f.options.open_timeout = 5
    end
  end
end
