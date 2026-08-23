# typed: false
# frozen_string_literal: true

require "spec_helper"

RSpec.describe ServerVersionChecker do
  describe ".fetch_latest_version" do
    context "in a non-test environment" do
      before { allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production")) }

      it "is the configured build" do
        stub_const("Frontress::SERVER_VERSION", 120_125)
        expect(described_class.fetch_latest_version).to eq(120_125)
      end

      # Nothing tells this fork what the current build is -- there is no Steam
      # UpToDateCheck for our AppID -- so an unconfigured version has to mean
      # "do not check". The alternative reading, "everything is outdated",
      # restarts the whole fleet.
      it "is nil when no build is configured" do
        stub_const("Frontress::SERVER_VERSION", nil)
        expect(described_class.fetch_latest_version).to be_nil
      end
    end

    it "short-circuits to a sentinel high version in the test environment" do
      expect(described_class.fetch_latest_version).to eq(100_000_000)
    end
  end

  describe ".latest_version" do
    before { Rails.cache.delete("latest_server_version") }

    it "returns the fetched version" do
      allow(described_class).to receive(:fetch_latest_version).and_return(12_345)
      expect(described_class.latest_version).to eq(12_345)
    end
  end

  describe "#current" do
    it "parses the network patch version from the rcon version response" do
      server = build_stubbed(:server)
      allow(server).to receive(:rcon_exec).with("version").and_return("Network PatchVersion: 5257083\nfoo bar")
      expect(described_class.new(server).current).to eq(5_257_083)
    end

    it "is nil when the version cannot be parsed" do
      server = build_stubbed(:server)
      allow(server).to receive(:rcon_exec).with("version").and_return("")
      expect(described_class.new(server).current).to be_nil
    end
  end

  describe "#outdated?" do
    let(:server) { build_stubbed(:server) }

    it "is false when no expected build is configured" do
      allow(described_class).to receive(:latest_version).and_return(nil)
      expect(described_class.new(server)).not_to be_outdated
    end

    it "is true when the server version is behind the latest" do
      allow(server).to receive(:rcon_exec).with("version").and_return("Network PatchVersion: 5257083")
      allow(described_class).to receive(:latest_version).and_return(100_000_000)
      expect(described_class.new(server)).to be_outdated
    end

    it "is false when the server is on the latest version" do
      allow(server).to receive(:rcon_exec).with("version").and_return("Network PatchVersion: 100000000")
      allow(described_class).to receive(:latest_version).and_return(100_000_000)
      expect(described_class.new(server)).not_to be_outdated
    end
  end
end
