# typed: false
# frozen_string_literal: true

require 'spec_helper'

describe SiteSetting do
  describe '.free_server_limit_reached?' do
    let(:starts_at) { Time.current }
    let(:ends_at)   { 3.hours.from_now }

    before { SiteSetting.set('free_server_limit', '0') }

    it 'stops a free user when the limit is zero' do
      user = create :user

      expect(SiteSetting.free_server_limit_reached?(user, starts_at, ends_at)).to be true
    end

    it 'lets a donator past it' do
      user = create :user
      user.groups << Group.donator_group

      expect(SiteSetting.free_server_limit_reached?(user, starts_at, ends_at)).to be false
    end

    it 'lets a trusted API client past it, so a quota for people cannot stop matchmaking' do
      user = create :user
      user.groups << Group.trusted_api_group

      expect(SiteSetting.free_server_limit_reached?(user, starts_at, ends_at)).to be false
    end

    it 'is not reached at all when no limit is set' do
      SiteSetting.set('free_server_limit', nil)
      user = create :user

      expect(SiteSetting.free_server_limit_reached?(user, starts_at, ends_at)).to be false
    end
  end
end
