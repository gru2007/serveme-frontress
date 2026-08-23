# typed: true
# frozen_string_literal: true

class CloudImageBuildWorker
  include Sidekiq::Worker
  sidekiq_options retry: false, queue: "low"

  LOCK_KEY = "cloud_image_build"
  LOCK_TTL = 2.hours
  DOCKER_DIR = Rails.root.join("docker", "frontress-server").to_s
  IMAGE = T.let(Frontress.server_image_repo, String)
  BASE_IMAGE = "frontress-base"
  # A build version is steam.inf's PatchVersion. Anything tiny means the
  # version lookup failed upstream, and building would tag a junk image (":0").
  MIN_PLAUSIBLE_VERSION = 1_000
  PUSH_ATTEMPTS = 3
  PUSH_BACKOFF = 15.seconds

  def perform(cloud_image_build_id)
    @build = CloudImageBuild.find(cloud_image_build_id)
    return if @build.finished?
    # Only the deployment that owns the image builds it. Everywhere else the
    # image comes from the registry, built by CI.
    return unless ENV["FRONTRESS_BUILD_IMAGE"].present?

    @streamer = CloudImageBuildOutputStreamer.new(@build)
    @lock_held = false

    begin
      @build.update!(status: "running", started_at: Time.current)
      broadcast_status

      return mark_invalid_version unless plausible_version?

      return mark_skipped_locked unless acquire_lock(@build.version)
      @lock_held = true

      run_phase("building") do
        # Build & tag the expensive intermediate stages first so the post-build
        # `docker image prune -f` (DockerHostImagePullWorker) cannot delete them.
        # Otherwise the dangling stage images are pruned and the next build
        # re-downloads the ~14.5GB TF2 base. See stage_build_commands.
        stage_build_commands.each { |cmd| run_streamed!(*cmd) }
        run_streamed!(*build_command)
      end
      run_phase("pushing") do
        push!(tag)
        push!(versioned_tag)
      end

      run_phase("notifying") do
        digest = pushed_digest
        if digest
          SiteSetting.set(DockerImagePollWorker::DIGEST_SETTING_KEY, digest)
          Rails.cache.delete("cloud_image_registry_digest")
        end
        SiteSetting.set(DockerImageReadiness::VERSION_SETTING_KEY, @build.version)
        @streamer.append("Notifying other regions...\n")
        notify_other_regions(digest)
        @build.update!(digest: digest) if digest
      end

      run_phase("triggering_pulls") do
        @streamer.append("Queuing pull on all hosts...\n")
        DockerHostImagePullWorker.perform_async
      end

      @streamer.flush!
      @build.update!(status: "succeeded", current_phase: nil, finished_at: Time.current)
      broadcast_status
    rescue StandardError => e
      @streamer.append("\n[ERROR] #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}\n")
      @streamer.flush!
      @build.update!(status: "failed", current_phase: nil, finished_at: Time.current)
      broadcast_status
    ensure
      release_lock if @lock_held
    end
  end

  private

  def tag
    "#{IMAGE}:latest"
  end

  def versioned_tag
    "#{IMAGE}:#{@build.version}"
  end

  def build_command
    args = [ "docker", "build" ]
    args << "--pull" if @build.force_pull
    args.push("--build-arg", "FRONTRESS_VERSION=#{@build.version}", "--build-arg", "CACHEBUST=#{@build.id}")
    args.push("-t", tag, "-t", versioned_tag, DOCKER_DIR)
    args
  end

  # A cache-preserving build of the expensive base stage. Tagging it keeps its
  # layers out of the dangling-image sweep done by `docker image prune -f`
  # (DockerHostImagePullWorker), so later builds reuse the SDK Base runtime
  # instead of downloading it again. The game payload itself is deliberately
  # rebuilt every time (CACHEBUST), so it is not tagged.
  def stage_build_commands
    base = [ "docker", "build" ]
    base << "--pull" if @build.force_pull
    base.push("--target", "frontress-base", "-t", "#{BASE_IMAGE}:latest", DOCKER_DIR)

    [ base ]
  end

  def run_phase(phase)
    @build.update!(current_phase: phase)
    broadcast_status
    yield
    @streamer.flush!
  end

  def run_streamed!(*command)
    @streamer.append("$ #{command.join(' ')}\n")
    T.unsafe(Open3).popen2e(*command) do |_stdin, stdout_and_stderr, wait_thread|
      stdout_and_stderr.each_line { |line| @streamer.append(line) }
      status = wait_thread.value
      raise "#{command.first(2).join(' ')} failed (exit #{status.exitstatus})" unless status.success?
    end
  end

  # Docker Hub intermittently answers a push with a 502/503, which would
  # otherwise throw away a build that has already done all of its work.
  def push!(image)
    attempt = 1
    begin
      run_streamed!("docker", "push", image)
    rescue StandardError => e
      raise if attempt >= PUSH_ATTEMPTS

      @streamer.append("[warn] #{e.message}, retrying in #{PUSH_BACKOFF.to_i}s (attempt #{attempt + 1}/#{PUSH_ATTEMPTS})\n")
      @streamer.flush!
      sleep PUSH_BACKOFF
      attempt += 1
      retry
    end
  end

  def plausible_version?
    @build.version.to_i >= MIN_PLAUSIBLE_VERSION
  end

  def mark_invalid_version
    @build.update!(status: "failed", current_phase: nil, finished_at: Time.current,
                   output: "[failed] Implausible build version #{@build.version.inspect} - refusing to build")
    broadcast_status
  end

  def mark_skipped_locked
    @build.update!(status: "skipped_locked", finished_at: Time.current,
                   output: "[skipped] Another build was already running")
    broadcast_status
  end

  def acquire_lock(version)
    Sidekiq.redis { |conn| conn.set(LOCK_KEY, version, nx: true, ex: LOCK_TTL.to_i) }
  end

  def release_lock
    Sidekiq.redis { |conn| conn.del(LOCK_KEY) }
  end

  def pushed_digest
    output, = Open3.capture2e("docker", "inspect", "--format={{index .RepoDigests 0}}", tag)
    digest = output.strip.split("@").last
    digest if digest.present? && digest.start_with?("sha256:")
  rescue StandardError => e
    Rails.logger.warn "CloudImageBuildWorker: Failed to get pushed digest: #{e.message}"
    nil
  end

  def notify_other_regions(digest)
    current_region = case SITE_HOST
    when "serveme.tf" then :eu
    when "na.serveme.tf" then :na
    when "sea.serveme.tf" then :sea
    when "au.serveme.tf" then :au
    end

    IpLookupSyncWorker::REGIONS.each do |region_key, base_url|
      next if region_key == current_region

      api_key = Rails.application.credentials.dig(:serveme, region_key)
      next unless api_key

      begin
        conn = Faraday.new(url: base_url) do |f|
          f.request :json
          f.options.timeout = 10
          f.options.open_timeout = 5
        end
        conn.post("/api/docker_image_updates") do |req|
          req.headers["Authorization"] = "Bearer #{api_key}"
          req.body = { digest: digest, version: @build.version }.compact.to_json
        end
        @streamer.append("  -> notified #{region_key}\n")
      rescue Faraday::Error => e
        @streamer.append("  -> WARN: #{region_key} notify failed: #{e.message}\n")
      end
    end
  end

  def broadcast_status
    BetaBroadcast.replace(
      @build,
      target: "build-header-#{@build.id}",
      partial: "admin/cloud_image_builds/header",
      locals: { build: @build }
    )
    BetaBroadcast.replace(
      "cloud_image_builds_index",
      target: "trigger-card",
      partial: "admin/cloud_image_builds/trigger_card",
      locals: { in_progress: CloudImageBuild.in_progress.first }
    )
    CloudImageBuild.broadcast_history
  end
end
