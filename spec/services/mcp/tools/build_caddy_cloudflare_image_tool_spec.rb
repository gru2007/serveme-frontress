# typed: false
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Mcp::Tools::BuildCaddyCloudflareImageTool do
  describe "class methods" do
    it "exposes the expected MCP metadata" do
      expect(described_class.tool_name).to eq("build_caddy_cloudflare_image")
      expect(described_class.description).to be_a(String).and(be_present)
      expect(described_class.required_role).to eq(:admin)
      expect(described_class.input_schema[:type]).to eq("object")
    end
  end

  describe "#execute" do
    let(:tool) { described_class.new(create(:user, :admin)) }

    it "queues the build worker where images are published" do
      stub_const("ENV", ENV.to_h.merge("FRONTRESS_BUILD_IMAGE" => "1"))
      expect(BuildCaddyCloudflareImageWorker).to receive(:perform_async)
      result = tool.execute({})
      expect(result[:status]).to eq("queued")
    end

    it "refuses to run where images are not published" do
      stub_const("ENV", ENV.to_h.merge("FRONTRESS_BUILD_IMAGE" => nil))
      expect(BuildCaddyCloudflareImageWorker).not_to receive(:perform_async)
      result = tool.execute({})
      expect(result[:error]).to include("builds images")
    end
  end
end
