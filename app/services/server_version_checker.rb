# typed: strict
# frozen_string_literal: true

# Resolves the build the fleet should be on, and tells whether a given server
# is behind it.
#
# Upstream asks Steam what the current TF2 build is. There is no such answer
# for Team Frontress: the playtest AppID does not serve UpToDateCheck, and the
# build a community runs is the one its operator deployed. So the expected
# version is FRONTRESS_SERVER_VERSION (steam.inf's PatchVersion, which
# game_clean/copy_server.sh also writes to VERSION in the payload), and an
# unset one means "do not check".
#
# That default matters: a nil version used to mean "every server is outdated",
# and the thing at the other end of "outdated" is a fleet-wide restart.
class ServerVersionChecker
  extend T::Sig

  CACHE_KEY = "latest_server_version"

  class << self
    extend T::Sig

    sig { returns(T.nilable(Integer)) }
    def latest_version
      # skip_nil so a configured-but-unreachable source is retried rather than
      # cached as "unknown" for five minutes.
      Rails.cache.fetch(CACHE_KEY, expires_in: 5.minutes, skip_nil: true) do
        fetch_latest_version
      end
    end

    sig { returns(T.nilable(Integer)) }
    def fetch_latest_version
      return 100_000_000 if Rails.env == "test"

      Frontress::SERVER_VERSION
    end
  end

  sig { params(server: Server).void }
  def initialize(server)
    @server = server
    @current = T.let(nil, T.nilable(Integer))
  end

  sig { returns(T.nilable(Integer)) }
  def current
    @current ||= /Network\ PatchVersion:\s+(\d+)/ =~ @server.rcon_exec("version").to_s && Regexp.last_match(1).to_i
  end

  sig { returns(T::Boolean) }
  def outdated?
    expected = self.class.latest_version
    return false if expected.nil?

    current != expected
  end
end
