# typed: false
# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

describe CloudImageBuildWorker do
  let(:worker) { described_class.new }
  let(:version) { "9876543" }
  let(:build) { CloudImageBuild.create!(version: version) }
  let(:redis) { instance_double(Redis) }
  let(:success_status) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:failure_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

  around do |example|
    VCR.turned_off do
      WebMock.allow_net_connect!
      example.run
      WebMock.disable_net_connect!
    end
  end

  before do
    # Only the deployment that owns the image builds it.
    stub_const("ENV", ENV.to_h.merge("FRONTRESS_BUILD_IMAGE" => "1"))
    # A fork with more than one site lists the others here; the worker used to
    # have four serveme.tf hostnames compiled into it.
    stub_const("IpLookupSyncWorker::REGIONS", {
      na: "https://na.example.org", sea: "https://sea.example.org", au: "https://au.example.org"
    })
    allow(Sidekiq).to receive(:redis).and_yield(redis)
    allow(redis).to receive(:set).and_return(true)
    allow(redis).to receive(:del)
    allow(Rails.application.credentials).to receive(:dig).with(:serveme, anything).and_return(nil)
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow(DockerHostImagePullWorker).to receive(:perform_async)
    stub_streamed_command([ "docker", "build", "--target", "frontress-base", "-t", "frontress-base:latest", CloudImageBuildWorker::DOCKER_DIR ], success_status, "base stage line\n")
    stub_streamed_command([ "docker", "build", "--build-arg", "FRONTRESS_VERSION=#{version}", "--build-arg", "CACHEBUST=#{build.id}", "-t", "#{CloudImageBuildWorker::IMAGE}:latest", "-t", "#{CloudImageBuildWorker::IMAGE}:#{version}", CloudImageBuildWorker::DOCKER_DIR ], success_status, "build line\n")
    stub_streamed_command([ "docker", "push", "#{CloudImageBuildWorker::IMAGE}:latest" ], success_status, "push line\n")
    stub_streamed_command([ "docker", "push", "#{CloudImageBuildWorker::IMAGE}:#{version}" ], success_status, "push version line\n")
    allow(Open3).to receive(:capture2e).with("docker", "inspect", anything, anything).and_return([ "#{CloudImageBuildWorker::IMAGE}@sha256:newdigest\n", success_status ])
  end

  describe "#perform" do
    it "marks the build succeeded and records the digest" do
      worker.perform(build.id)

      build.reload
      expect(build.status).to eq("succeeded")
      expect(build.started_at).to be_present
      expect(build.finished_at).to be_present
      expect(build.digest).to eq("sha256:newdigest")
      expect(build.current_phase).to be_nil
    end

    it "appends streamed output to the build" do
      worker.perform(build.id)
      expect(build.reload.output).to include("build line").and include("push line")
    end

    it "passes --pull when force_pull is true" do
      build.update!(force_pull: true)
      stub_streamed_command([ "docker", "build", "--pull", "--target", "frontress-base", "-t", "frontress-base:latest", CloudImageBuildWorker::DOCKER_DIR ], success_status, "")
      stub_streamed_command([ "docker", "build", "--pull", "--build-arg", "FRONTRESS_VERSION=#{version}", "--build-arg", "CACHEBUST=#{build.id}", "-t", "#{CloudImageBuildWorker::IMAGE}:latest", "-t", "#{CloudImageBuildWorker::IMAGE}:#{version}", CloudImageBuildWorker::DOCKER_DIR ], success_status, "")

      worker.perform(build.id)
      expect(build.reload.status).to eq("succeeded")
    end

    it "is idempotent: skips already-finished builds" do
      build.update!(status: "succeeded", finished_at: Time.current)
      expect(Open3).not_to receive(:popen2e)

      worker.perform(build.id)
    end

    it "marks build as skipped_locked when the redis lock is held" do
      allow(redis).to receive(:set).and_return(false)
      expect(redis).not_to receive(:del)
      expect(Open3).not_to receive(:popen2e)

      worker.perform(build.id)

      build.reload
      expect(build.status).to eq("skipped_locked")
      expect(build.finished_at).to be_present
      expect(build.output).to include("Another build was already running")
    end

    it "marks build as failed and records exception output when docker build fails" do
      stub_streamed_command([ "docker", "build", "--build-arg", "FRONTRESS_VERSION=#{version}", "--build-arg", "CACHEBUST=#{build.id}", "-t", "#{CloudImageBuildWorker::IMAGE}:latest", "-t", "#{CloudImageBuildWorker::IMAGE}:#{version}", CloudImageBuildWorker::DOCKER_DIR ], failure_status, "Error! App state\n")

      expect { worker.perform(build.id) }.not_to raise_error

      build.reload
      expect(build.status).to eq("failed")
      expect(build.output).to include("Error! App state")
      expect(build.output).to include("[ERROR]")
    end

    it "releases the redis lock after completion" do
      expect(redis).to receive(:del).with("cloud_image_build")
      worker.perform(build.id)
    end

    it "queues DockerHostImagePullWorker on success" do
      expect(DockerHostImagePullWorker).to receive(:perform_async)
      worker.perform(build.id)
    end

    it "writes new digest to SiteSetting on success" do
      worker.perform(build.id)
      expect(SiteSetting.get(DockerImagePollWorker::DIGEST_SETTING_KEY)).to eq("sha256:newdigest")
    end

    it "tags the image with the build version alongside latest" do
      worker.perform(build.id)
      expect(Open3).to have_received(:popen2e).with(
        "docker", "build", "--build-arg", "FRONTRESS_VERSION=#{version}", "--build-arg", "CACHEBUST=#{build.id}",
        "-t", "#{CloudImageBuildWorker::IMAGE}:latest",
        "-t", "#{CloudImageBuildWorker::IMAGE}:#{version}",
        CloudImageBuildWorker::DOCKER_DIR
      )
    end

    it "builds and tags the base stage so its cache survives the post-build prune" do
      worker.perform(build.id)

      expect(Open3).to have_received(:popen2e).with(
        "docker", "build", "--target", "frontress-base",
        "-t", "frontress-base:latest", CloudImageBuildWorker::DOCKER_DIR
      )
    end

    it "pushes both the latest and version-specific tags" do
      worker.perform(build.id)
      expect(Open3).to have_received(:popen2e).with("docker", "push", "#{CloudImageBuildWorker::IMAGE}:latest")
      expect(Open3).to have_received(:popen2e).with("docker", "push", "#{CloudImageBuildWorker::IMAGE}:#{version}")
    end

    it "records the built version in SiteSetting on success" do
      worker.perform(build.id)
      expect(SiteSetting.get(DockerImageReadiness::VERSION_SETTING_KEY)).to eq(version)
    end

    it "includes the built version in the cross-region notification payload" do
      allow(Rails.application.credentials).to receive(:dig).with(:serveme, anything).and_return("test-api-key")
      %w[na sea au].each do |region|
        stub_request(:post, "https://#{region}.example.org/api/docker_image_updates").to_return(status: 200)
      end

      worker.perform(build.id)

      expect(WebMock).to have_requested(:post, "https://na.example.org/api/docker_image_updates")
        .with { |req| JSON.parse(req.body)["version"] == version }
    end

    it "notifies other regions after successful push" do
      allow(Rails.application.credentials).to receive(:dig).with(:serveme, anything).and_return("test-api-key")
      %w[na sea au].each do |region|
        stub_request(:post, "https://#{region}.example.org/api/docker_image_updates").to_return(status: 200)
      end

      worker.perform(build.id)

      expect(WebMock).to have_requested(:post, "https://na.example.org/api/docker_image_updates")
      expect(WebMock).to have_requested(:post, "https://sea.example.org/api/docker_image_updates")
      expect(WebMock).to have_requested(:post, "https://au.example.org/api/docker_image_updates")
    end

    it "continues notifying other regions when one fails" do
      allow(Rails.application.credentials).to receive(:dig).with(:serveme, anything).and_return("test-api-key")
      stub_request(:post, "https://na.example.org/api/docker_image_updates").to_raise(Faraday::ConnectionFailed.new("nope"))
      stub_request(:post, "https://sea.example.org/api/docker_image_updates").to_return(status: 200)
      stub_request(:post, "https://au.example.org/api/docker_image_updates").to_return(status: 200)

      worker.perform(build.id)

      expect(WebMock).to have_requested(:post, "https://sea.example.org/api/docker_image_updates")
      expect(WebMock).to have_requested(:post, "https://au.example.org/api/docker_image_updates")
    end

    it "marks build as failed when broadcast_status raises before lock acquisition" do
      call_count = 0
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do
        call_count += 1
        raise(RuntimeError, "broadcast down") if call_count == 1
        nil
      end
      expect(redis).not_to receive(:del)

      expect { worker.perform(build.id) }.not_to raise_error

      build.reload
      expect(build.status).to eq("failed")
      expect(build.output).to include("broadcast down")
    end

    it "marks build as failed when acquire_lock raises" do
      allow(redis).to receive(:set).and_raise(Redis::CannotConnectError, "redis down")
      expect(redis).not_to receive(:del)

      expect { worker.perform(build.id) }.not_to raise_error

      build.reload
      expect(build.status).to eq("failed")
      expect(build.output).to include("redis down")
    end

    context "with an implausible TF2 version" do
      let(:version) { "0" }

      it "refuses to build, never acquiring the lock or shelling out" do
        expect(redis).not_to receive(:set)
        expect(Open3).not_to receive(:popen2e)

        worker.perform(build.id)

        build.reload
        expect(build.status).to eq("failed")
        expect(build.output).to include("Implausible TF2 version")
      end
    end

    it "retries a failed docker push and succeeds" do
      allow(worker).to receive(:sleep)
      push = [ "docker", "push", "#{CloudImageBuildWorker::IMAGE}:latest" ]
      call = 0
      allow(Open3).to receive(:popen2e).with(*push) do |*_args, &blk|
        call += 1
        blk.call(StringIO.new, StringIO.new("push attempt #{call}\n"), instance_double(Thread, value: call == 1 ? failure_status : success_status))
      end

      worker.perform(build.id)

      expect(build.reload.status).to eq("succeeded")
      expect(call).to eq(2)
      expect(build.output).to include("retrying in")
    end

    it "gives up after the push retry budget is exhausted" do
      allow(worker).to receive(:sleep)
      stub_streamed_command([ "docker", "push", "#{CloudImageBuildWorker::IMAGE}:latest" ], failure_status, "push down\n")

      expect { worker.perform(build.id) }.not_to raise_error

      build.reload
      expect(build.status).to eq("failed")
      expect(build.output).to include("[ERROR]")
    end
  end

  # Helper: stubs Open3.popen2e to yield scripted lines and a wait_thread with the given status.
  define_method(:stub_streamed_command) do |command, status, output|
    fake_stdout = StringIO.new(output)
    fake_thread = instance_double(Thread, value: status)
    allow(Open3).to receive(:popen2e).with(*command).and_yield(StringIO.new, fake_stdout, fake_thread)
  end
end
