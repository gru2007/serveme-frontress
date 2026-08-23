# typed: false

require "spec_helper"

RSpec.describe CloudProvider::ContainerEnv do
  let(:reservation) { create(:reservation, enable_plugins: true) }
  let(:cloud_server) { create(:cloud_server, cloud_reservation_id: reservation.id) }

  define_method(:env) do |mode: :multi|
    described_class.build(cloud_server, ssh_public_key: "ssh-ed25519 AAAA test@serveme", mode: mode)
  end

  describe "CALLBACK_URL" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      stub_const("SITE_URL", "https://site.example.org")
    end

    it "uses SITE_URL when CLOUD_CALLBACK_HOST is unset" do
      allow(ENV).to receive(:[]).with("CLOUD_CALLBACK_HOST").and_return(nil)

      expect(env["CALLBACK_URL"]).to eq("https://site.example.org/api/cloud_servers/#{cloud_server.id}/ready")
    end

    it "treats an empty CLOUD_CALLBACK_HOST as unset" do
      allow(ENV).to receive(:[]).with("CLOUD_CALLBACK_HOST").and_return("")

      expect(env["CALLBACK_URL"]).to eq("https://site.example.org/api/cloud_servers/#{cloud_server.id}/ready")
    end

    it "uses a bare callback host with the SITE_URL scheme" do
      allow(ENV).to receive(:[]).with("CLOUD_CALLBACK_HOST").and_return("callback.example.org")

      expect(env["CALLBACK_URL"]).to eq("https://callback.example.org/api/cloud_servers/#{cloud_server.id}/ready")
    end

    it "accepts a complete callback base URL" do
      allow(ENV).to receive(:[]).with("CLOUD_CALLBACK_HOST").and_return("http://10.0.0.5:3000/")

      expect(env["CALLBACK_URL"]).to eq("http://10.0.0.5:3000/api/cloud_servers/#{cloud_server.id}/ready")
    end
  end

  describe "ENABLE_PLUGINS" do
    it "is 1 when the reservation wants plugins" do
      expect(env["ENABLE_PLUGINS"]).to eq("1")
    end

    it "is 0 when the reservation has plugins disabled" do
      reservation.update_columns(enable_plugins: false, enable_demos_tf: false)

      expect(env["ENABLE_PLUGINS"]).to eq("0")
    end

    it "is 1 when demos.tf is on even though plugins are off" do
      reservation.update_columns(enable_plugins: false, enable_demos_tf: true)

      expect(env["ENABLE_PLUGINS"]).to eq("1")
    end

    it "is 1 when the site setting forces plugins on" do
      reservation.update_columns(enable_plugins: false, enable_demos_tf: false)
      allow(SiteSetting).to receive(:always_enable_plugins?).and_return(true)

      expect(env["ENABLE_PLUGINS"]).to eq("1")
    end

    it "is emitted in VM mode too" do
      reservation.update_columns(enable_plugins: false, enable_demos_tf: false)

      expect(env(mode: :vm)["ENABLE_PLUGINS"]).to eq("0")
    end

    it "is left out when the server has no reservation" do
      cloud_server.update_column(:cloud_reservation_id, nil)

      expect(env).not_to have_key("ENABLE_PLUGINS")
    end
  end

  describe "the game the container runs" do
    it "names the mod directory and the map list, which are the game" do
      expect(env["GAME_DIR"]).to eq(Frontress::GAME_DIR)
      expect(env["MAPLIST_URL"]).to eq(Frontress.maps_url)
    end

    it "leaves the expected build out when none is configured" do
      stub_const("Frontress::SERVER_VERSION", nil)
      expect(env).not_to have_key("EXPECTED_SERVER_VERSION")
    end

    it "passes the expected build when one is configured" do
      stub_const("Frontress::SERVER_VERSION", 120_125)
      expect(env["EXPECTED_SERVER_VERSION"]).to eq("120125")
    end
  end

  describe "a matchmaking reservation" do
    before do
      stub_const("Frontress::COORDINATOR_URL", "http://gc.example.org:27100")
      stub_const("Frontress::COORDINATOR_SECRET", "s3cret")
    end

    it "tells the agent where to report the match" do
      reservation.update_columns(match_id: "9f2c", match_mode: "ranked")

      expect(env["GC_URL"]).to eq("http://gc.example.org:27100")
      expect(env["GC_SECRET"]).to eq("s3cret")
      expect(env["MATCH_ID"]).to eq("9f2c")
      expect(env["MATCH_MODE"]).to eq("ranked")
    end

    it "says nothing about a coordinator on an ordinary reservation" do
      expect(env).not_to have_key("GC_URL")
      expect(env).not_to have_key("MATCH_ID")
    end

    # A container that is told a match id but not where to report it would
    # heartbeat into the void; the agent is simply not started in that case.
    it "says nothing when no coordinator is configured" do
      stub_const("Frontress::COORDINATOR_URL", "")
      reservation.update_columns(match_id: "9f2c", match_mode: "casual")

      expect(env).not_to have_key("GC_URL")
    end
  end
end
