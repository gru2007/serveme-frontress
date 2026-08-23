# typed: false
# frozen_string_literal: true

require "spec_helper"

RSpec.describe CloudServer do
  describe "local Docker public addressing" do
    before do
      allow(CloudProvider::Docker).to receive(:public_host).and_return("159.198.70.152")
    end

    it "does not expose the provisioning 0.0.0.0 sentinel" do
      server = create(:cloud_server, cloud_provider: "docker", ip: "0.0.0.0")

      expect(server.host_hostname).to eq("159.198.70.152")
      expect(server.public_ip).to eq("159.198.70.152")
    end

    it "keeps the database ip untouched while provisioning" do
      server = create(:cloud_server, cloud_provider: "docker", ip: "0.0.0.0")

      server.public_ip
      expect(server.ip).to eq("0.0.0.0")
    end
  end
end
