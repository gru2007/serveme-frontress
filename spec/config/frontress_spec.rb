# typed: false
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Frontress do
  describe ".ssh_private_key" do
    before do
      allow(described_class).to receive(:ssh_private_key_from_file).and_return(nil)
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:cloud_servers, :ssh_private_key).and_return(nil)
      SiteSetting.where(key: described_class::SSH_KEY_SETTING).delete_all
      Rails.cache.delete("site_setting:#{described_class::SSH_KEY_SETTING}")
    end

    # Upstream keeps this in Rails credentials. Without it, provisioning used to
    # die inside a sorbet signature -- "Expected type String, got NilClass" --
    # which says nothing about the fact that the site has no way into its own
    # game servers.
    it "generates one when nothing else provides it" do
      key = described_class.ssh_private_key

      expect(key).to be_present
      expect { Net::SSH::KeyFactory.load_data_private_key(key) }.not_to raise_error
    end

    it "keeps the generated key, so containers stay reachable across restarts" do
      first = described_class.ssh_private_key
      Rails.cache.delete("site_setting:#{described_class::SSH_KEY_SETTING}")

      expect(described_class.ssh_private_key).to eq(first)
    end

    it "prefers the environment over generating one" do
      pem = OpenSSL::PKey::RSA.new(2048).to_pem
      stub_const("ENV", ENV.to_h.merge("FRONTRESS_SSH_PRIVATE_KEY" => pem))

      expect(described_class.ssh_private_key).to eq(pem)
    end

    it "derives a public key a container can put in authorized_keys" do
      expect(described_class.ssh_public_key).to match(/\Assh-rsa [A-Za-z0-9+\/=]+\z/)
    end
  end

  describe ".storage_service" do
    it "is the local disk when no object storage is configured" do
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:cloudflare, :access_key_id).and_return(nil)
      stub_const("ENV", ENV.to_h.merge("ACTIVE_STORAGE_SERVICE" => nil))

      expect(described_class.storage_service).to eq(:local)
    end

    it "is whatever ACTIVE_STORAGE_SERVICE names" do
      stub_const("ENV", ENV.to_h.merge("ACTIVE_STORAGE_SERVICE" => "minio"))

      expect(described_class.storage_service).to eq(:minio)
    end
  end

  describe ".map_list" do
    it "is the configured maps when FRONTRESS_MAPS is set" do
      stub_const("ENV", ENV.to_h.merge("FRONTRESS_MAPS" => "koth_product_final, cp_process_final"))

      expect(described_class.map_list).to eq(%w[koth_product_final cp_process_final])
    end

    it "falls back to the map groups, which is what the picker shows" do
      stub_const("ENV", ENV.to_h.merge("FRONTRESS_MAPS" => ""))

      expect(described_class.map_list).to eq(LeagueMaps.all_league_maps)
    end
  end
end
