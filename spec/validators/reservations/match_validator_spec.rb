# typed: false
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Reservations::MatchValidator do
  let(:user) { create(:user) }

  def reservation_for(user, attrs)
    build(:reservation, attrs.merge(user: user))
  end

  it "accepts a reservation with no match at all" do
    expect(reservation_for(user, {})).to be_valid
  end

  it "accepts a casual match from an ordinary user" do
    expect(reservation_for(user, match_id: "9f2c", match_mode: "casual")).to be_valid
  end

  it "refuses a mode it does not know" do
    reservation = reservation_for(user, match_id: "9f2c", match_mode: "scrim")
    expect(reservation).not_to be_valid
    expect(reservation.errors[:match_mode].join).to include("casual")
  end

  it "refuses a mode without a match id" do
    reservation = reservation_for(user, match_mode: "casual")
    expect(reservation).not_to be_valid
    expect(reservation.errors[:match_id]).to be_present
  end

  # A ranked reservation made by hand is a server running the ranked ruleset
  # with no roster behind it, and any result reported against it is a result
  # for a match the coordinator never formed.
  it "refuses a ranked match from an ordinary user" do
    reservation = reservation_for(user, match_id: "9f2c", match_mode: "ranked")
    expect(reservation).not_to be_valid
    expect(reservation.errors[:match_mode].join).to include("coordinator")
  end

  it "allows a ranked match from the coordinator's trusted API user" do
    user.groups << Group.trusted_api_group
    expect(reservation_for(user, match_id: "9f2c", match_mode: "ranked")).to be_valid
  end

  it "allows a ranked match from an admin" do
    user.groups << Group.admin_group
    expect(reservation_for(user, match_id: "9f2c", match_mode: "ranked")).to be_valid
  end

  describe "the ruleset a match runs" do
    it "follows the mode when the reservation does not name one" do
      expect(reservation_for(user, match_id: "9f2c", match_mode: "casual").match_ruleset).to eq("frontress_casual")
    end

    it "is whatever the coordinator asked for when it named one" do
      reservation = reservation_for(user, match_id: "9f2c", match_mode: "casual", match_config: "frontress_frontline_night")
      expect(reservation.match_ruleset).to eq("frontress_frontline_night")
    end

    it "is nothing at all for a reservation that is not a match" do
      expect(reservation_for(user, {}).match_ruleset).to be_nil
    end
  end
end
