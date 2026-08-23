# typed: true
# frozen_string_literal: true

module Admin
  class CloudImageBuildsController < ApplicationController
    before_action :require_admin
    before_action :require_eu_region

    def index
      @builds = CloudImageBuild.recent.includes(:triggered_by_user).limit(20)
      @in_progress = CloudImageBuild.in_progress.first
      @local_digest = SiteSetting.get(DockerImagePollWorker::DIGEST_SETTING_KEY)
      @registry_digest = Rails.cache.fetch("cloud_image_registry_digest", expires_in: 30.seconds) do
        DockerImageRegistryClient.new.fetch_digest
      end
    end

    def show
      @build = CloudImageBuild.find(params[:id])
    end

    def create
      version = Server.latest_version
      return redirect_to(admin_cloud_image_builds_path, alert: "Could not fetch latest TF2 version from Steam.") unless version

      build = CloudImageBuild.create!(
        version: version.to_s,
        force_pull: ActiveModel::Type::Boolean.new.cast(params[:force_pull]) || false,
        no_cache: ActiveModel::Type::Boolean.new.cast(params[:no_cache]) || false,
        triggered_by_user: current_user,
        status: "queued"
      )
      CloudImageBuildWorker.perform_async(build.id)
      CloudImageBuild.broadcast_history
      redirect_to admin_cloud_image_build_path(build)
    end

    def pull_now
      DockerHostImagePullWorker.perform_async
      redirect_to admin_cloud_image_builds_path, notice: "Pull queued on all active hosts."
    end

    private

    # Only the deployment that owns the game server image builds it; everywhere
    # else it comes from the registry.
    def require_eu_region
      return if ENV["FRONTRESS_BUILD_IMAGE"].present?
      redirect_to root_path, alert: "Server image builds are only available on the deployment that publishes the image."
    end
  end
end
