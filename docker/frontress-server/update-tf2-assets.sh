#!/bin/bash
set -euo pipefail

# Populate the host-scoped TF2 asset volume. Reservation containers mount the
# same volume read-only at /home/frontress/hlserver/tf2; only this one-shot
# maintenance container ever writes to it.

TARGET="${1:-/assets}"
READY_FILE="$TARGET/.frontress-ready"
LOCK_FILE="$TARGET/.frontress-update.lock"
FORCE_UPDATE="${FRONTRESS_TF2_ASSETS_UPDATE:-0}"

assets_valid() {
    [ -f "$TARGET/tf/gameinfo.txt" ] &&
        compgen -G "$TARGET/tf/tf2_misc*_dir.vpk" >/dev/null
}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: TF2 asset updater must run as root so it can initialise the volume" >&2
    exit 1
fi

install -d -o frontress -g frontress "$TARGET"
touch "$LOCK_FILE"
chown frontress:frontress "$LOCK_FILE"

# A deploy and an administrator command may arrive together. Only one SteamCMD
# process may mutate the depot; the second caller re-checks the marker after it
# obtains the lock and normally exits immediately.
exec 9>"$LOCK_FILE"
flock 9

if [ "$FORCE_UPDATE" != 1 ] && [ -f "$READY_FILE" ] && assets_valid; then
    echo "TF2 assets already ready in $TARGET"
    exit 0
fi

rm -f "$READY_FILE"
echo "Installing TF2 dedicated assets (AppID 232250) into $TARGET"

steamcmd=(
    /usr/games/steamcmd
    +force_install_dir "$TARGET"
    +login anonymous
    +app_update 232250 validate
    +quit
)

if ! sudo -H -u frontress env HOME=/home/frontress "${steamcmd[@]}"; then
    echo "SteamCMD failed once; retrying AppID 232250" >&2
    sudo -H -u frontress env HOME=/home/frontress "${steamcmd[@]}"
fi

if ! assets_valid; then
    echo "ERROR: SteamCMD finished but TF2 assets are incomplete in $TARGET" >&2
    exit 1
fi

manifest="$TARGET/steamapps/appmanifest_232250.acf"
build_id="$(awk -F '"' '/"buildid"/ { print $4; exit }' "$manifest" 2>/dev/null || true)"
{
    echo "app_id=232250"
    echo "build_id=${build_id:-unknown}"
    date -u '+updated_at=%Y-%m-%dT%H:%M:%SZ'
} > "${READY_FILE}.tmp"
chown frontress:frontress "${READY_FILE}.tmp"
mv "${READY_FILE}.tmp" "$READY_FILE"

echo "TF2 assets ready (build ${build_id:-unknown})"
