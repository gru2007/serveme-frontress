# typed: strict
# frozen_string_literal: true

class LeagueBan
  extend T::Sig

  sig { params(steam_uid: T.any(String, Integer)).returns(T.nilable(T.any(Etf2lProfile, RglProfile))) }
  def self.fetch(steam_uid)
    profile = klass&.fetch(steam_uid)
    profile if profile&.banned?
  rescue Faraday::TimeoutError
    nil
  end

  # Which league's ban list to check. Upstream picks one per site: ETF2L in
  # Europe, RGL in North America. Team Frontress is not in a Team Fortress
  # league, so nobody is checked -- and `fetch` already answers nil for that.
  #
  # Set FRONTRESS_LEAGUE to "etf2l" or "rgl" if a community wants to inherit
  # one of those ban lists anyway.
  sig { returns(T.nilable(T.any(T.class_of(Etf2lProfile), T.class_of(RglProfile)))) }
  def self.klass
    case ENV["FRONTRESS_LEAGUE"].to_s.downcase
    when "etf2l" then Etf2lProfile
    when "rgl" then RglProfile
    end
  end
end
