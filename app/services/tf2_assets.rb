# typed: strict
# frozen_string_literal: true

require "shellwords"

# Host-level storage for Valve's TF2 dedicated depot. The game image contains
# the updater but not the depot itself; each Docker host downloads one copy and
# shares it read-only between reservation containers.
class Tf2Assets
  extend T::Sig

  GAME_MOUNT_PATH = "/home/frontress/hlserver/tf2"
  MAINTENANCE_MOUNT_PATH = "/assets"
  UPDATER_PATH = "/home/frontress/hlserver/update-tf2-assets.sh"
  READY_TOKEN = "FRONTRESS_TF2_ASSETS_READY"

  sig { params(readonly: T::Boolean).returns(String) }
  def self.mount_spec(readonly: true)
    parts = [
      "type=volume",
      "source=#{Frontress::TF2_ASSETS_VOLUME}",
      "target=#{readonly ? GAME_MOUNT_PATH : MAINTENANCE_MOUNT_PATH}"
    ]
    parts << "readonly" if readonly
    parts.join(",")
  end

  # Idempotent: the updater returns immediately when a valid ready marker is
  # present. Set FRONTRESS_TF2_ASSETS_UPDATE=1 only for explicit maintenance.
  sig { params(image: String, force_update: T::Boolean).returns(String) }
  def self.bootstrap_command(image:, force_update: false)
    docker_run = [
      "docker", "run", "--rm", "--user", "root",
      *(force_update ? [ "-e", "FRONTRESS_TF2_ASSETS_UPDATE=1" ] : []),
      "--mount", mount_spec(readonly: false),
      "--entrypoint", UPDATER_PATH,
      image,
      MAINTENANCE_MOUNT_PATH
    ].map { |part| Shellwords.shellescape(part) }.join(" ")

    volume = Shellwords.shellescape(Frontress::TF2_ASSETS_VOLUME)
    "docker volume create #{volume} >/dev/null && #{docker_run} && echo #{READY_TOKEN}"
  end
end
