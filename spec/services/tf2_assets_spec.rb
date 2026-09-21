# typed: false
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tf2Assets do
  describe ".mount_spec" do
    it "mounts the host volume at the path expected by gameinfo, read-only" do
      expect(described_class.mount_spec).to eq(
        "type=volume,source=#{Frontress::TF2_ASSETS_VOLUME}," \
        "target=/home/frontress/hlserver/tf2,readonly"
      )
    end

    it "uses a writable maintenance mount for the updater" do
      expect(described_class.mount_spec(readonly: false)).to eq(
        "type=volume,source=#{Frontress::TF2_ASSETS_VOLUME},target=/assets"
      )
    end
  end

  describe ".bootstrap_command" do
    it "creates the volume and runs the image's idempotent updater" do
      command = described_class.bootstrap_command(image: "registry.example/frontress:latest")

      expect(command).to include("docker volume create #{Frontress::TF2_ASSETS_VOLUME}")
      expect(command).to include("--user root")
      expect(command).to include(Shellwords.shellescape(described_class.mount_spec(readonly: false)))
      expect(command).to include("--entrypoint /home/frontress/hlserver/update-tf2-assets.sh")
      expect(command).to include("registry.example/frontress:latest /assets")
      expect(command).to end_with("echo #{Tf2Assets::READY_TOKEN}")
      expect(command).not_to include("FRONTRESS_TF2_ASSETS_UPDATE=1")
    end

    it "can request an explicit SteamCMD update" do
      command = described_class.bootstrap_command(image: "frontress:latest", force_update: true)

      expect(command).to include("-e #{Shellwords.shellescape('FRONTRESS_TF2_ASSETS_UPDATE=1')}")
    end
  end
end
