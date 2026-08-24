#!/bin/bash
set -e

# Bring up one Team Frontress dedicated server for one reservation.
#
# The order matters and is the same every time:
#
#   1. make SteamCMD's client libraries visible where Source expects them
#   2. SSH, so serveme can push configs and collect logs and demos
#   3. check the game payload is the build the site expects
#   4. write server.cfg, which execs reservation.cfg
#   5. tell serveme we are reachable; wait for it to push reservation.cfg
#   6. make sure the first map exists locally
#   7. start the server, and the coordinator agent if this is a match
#   8. wait until it is actually on a map, then tell serveme it is ready
#
# Everything the server needs per match -- password, ruleset, match tag -- is
# in reservation.cfg. Nothing in this script decides any of it.

GAME_DIR="${GAME_DIR:-tc2}"
ROOT="$HOME/hlserver"
CFG_DIR="$ROOT/$GAME_DIR/cfg"

# Source dedicated servers still look for Steam's client library under
# ~/.steam/sdk64 even when SteamCMD installed it elsewhere. Ubuntu's steamcmd
# package currently puts it under ~/.local/share/Steam/steamcmd; tarball-based
# installs commonly use ~/.steam/steamcmd. Repair the SDK links on every boot
# so a SteamCMD update cannot silently leave the container unable to initialise
# SteamGameServer.
ensure_steamclient_links() {
    local steamcmd_root=""
    local candidate

    for candidate in \
        "$HOME/.local/share/Steam/steamcmd" \
        "$HOME/.steam/steamcmd"
    do
        if [ -f "$candidate/linux64/steamclient.so" ]; then
            steamcmd_root="$candidate"
            break
        fi
    done

    if [ -z "$steamcmd_root" ]; then
        echo "ERROR: SteamCMD steamclient.so not found; checked ~/.local/share/Steam/steamcmd and ~/.steam/steamcmd" >&2
        return 1
    fi

    mkdir -p "$HOME/.steam/sdk64"
    ln -sfn "$steamcmd_root/linux64/steamclient.so" "$HOME/.steam/sdk64/steamclient.so"

    if [ -f "$steamcmd_root/linux32/steamclient.so" ]; then
        mkdir -p "$HOME/.steam/sdk32"
        ln -sfn "$steamcmd_root/linux32/steamclient.so" "$HOME/.steam/sdk32/steamclient.so"
    fi

    if [ ! -e "$HOME/.steam/sdk64/steamclient.so" ]; then
        echo "ERROR: failed to provision ~/.steam/sdk64/steamclient.so" >&2
        return 1
    fi
}

ensure_steamclient_links

# 1. SSH for remote file management
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if [ -n "$SSH_AUTHORIZED_KEYS" ]; then
    echo "$SSH_AUTHORIZED_KEYS" > ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi
SSH_PORT="${SSH_PORT:-22}"
sudo /usr/sbin/sshd -p "$SSH_PORT"

# Supervise sshd: without it, a dead sshd means logs and demos are stranded.
(
    while true; do
        sleep 30
        if ! ss -tln | grep -q ":${SSH_PORT}[[:space:]]"; then
            echo "sshd on port $SSH_PORT is down, restarting..."
            sudo /usr/sbin/sshd -p "$SSH_PORT"
        fi
    done
) &

# 2. Is this the build the site expects?
#
# Our game is not on an anonymous Steam depot, so there is no steamcmd update
# to run here: the payload comes from a release artifact. If the site says it
# expects a different build and we were given somewhere to get it, fetch it;
# otherwise say so loudly and carry on, because a server running a slightly old
# build is better than no server at all.
INSTALLED_VERSION="$(cat "$ROOT/VERSION" 2>/dev/null | tr -d '\r\n ')"
if [ -n "$EXPECTED_SERVER_VERSION" ] && [ "$INSTALLED_VERSION" != "$EXPECTED_SERVER_VERSION" ]; then
    if [ -n "$SERVER_UPDATE_URL" ]; then
        echo "Build ${INSTALLED_VERSION:-unknown} is not the expected ${EXPECTED_SERVER_VERSION}, updating from $SERVER_UPDATE_URL"
        if curl -fsSL "$SERVER_UPDATE_URL" -o /tmp/frontress.tar.gz; then
            tar -xzf /tmp/frontress.tar.gz -C "$ROOT" && rm -f /tmp/frontress.tar.gz
            INSTALLED_VERSION="$(cat "$ROOT/VERSION" 2>/dev/null | tr -d '\r\n ')"
            echo "Now on build ${INSTALLED_VERSION:-unknown}"
        else
            echo "WARNING: could not download the update; starting on ${INSTALLED_VERSION:-unknown}"
        fi
    else
        echo "WARNING: build ${INSTALLED_VERSION:-unknown} is not the expected ${EXPECTED_SERVER_VERSION}, and no SERVER_UPDATE_URL was given"
    fi
else
    echo "Frontress build ${INSTALLED_VERSION:-unknown}"
fi

# 2b. Steam networking off, in the launcher itself.
#
# The launcher that ships inside the game payload passes -enablefakeip
# unconditionally (game/tc2.sh in the game repository). With it the engine asks
# Steam for a FakeIP, and once that allocation lands the server advertises and
# answers on the FakeIP instead of the address this site hands players -- which
# looks exactly like the server going dead the moment Steam is reachable.
#
# A launch parameter cannot be undone by a convar, so the only place to turn
# this off is the launcher script, and it has to happen after the update above:
# an update unpacks a fresh tc2.sh straight over this one.
strip_fakeip_launch_option() {
    local script
    for script in "$ROOT/tc2.sh" "$ROOT/start_dedicated_tc2.sh"; do
        [ -f "$script" ] || continue
        grep -q -- "-enablefakeip" "$script" || continue
        sed -i 's/[[:space:]]\{1,\}-enablefakeip\b//g' "$script"
        echo "Removed -enablefakeip from $(basename "$script")"
    done
}
strip_fakeip_launch_option

# 3. server.cfg. Everything reservation-specific is in reservation.cfg, which
# serveme writes; this is only what has to be true before that arrives.
#
# Anything that can live here rather than on the launcher command line does.
# The dedicated launcher joins its whole argv into a 512 byte buffer and dies
# with "command line too long, 512 max" the moment it does not fit -- and the
# part of that budget we do not control (the game dir, the runtime, whatever
# start_dedicated_tc2.sh prepends) is a good third of it.
PORT="${PORT:-27015}"
TV_PORT="${TV_PORT:-$((PORT + 5))}"
CLIENT_PORT="${CLIENT_PORT:-40001}"
STEAM_PORT="${STEAM_PORT:-30001}"
RCON_PASSWORD="${RCON_PASSWORD:-changeme}"

mkdir -p "$CFG_DIR"
{
    echo 'hostname "Team Frontress"'
    [ -n "$FASTDL_URL" ] && echo "sv_downloadurl \"${FASTDL_URL}\""
    echo "rcon_password \"${RCON_PASSWORD:-changeme}\""
    echo 'log on'
    echo 'sv_logecho 1'
    # SourceTV starts when a level loads, which is also when this file is
    # exec'd, so the command line buys nothing here.
    echo "tv_port ${TV_PORT}"
    echo 'tv_maxclients 32'
    echo 'tv_enable 1'
    echo 'tv_autorecord 1'
    echo 'sv_rcon_minfailuretime 1'
    echo 'sv_rcon_minfailures 20'
    echo 'sv_rcon_maxfailures 20'
    echo 'sv_rcon_banpenalty 1'
    # A matchmade server must not act on a map change only once somebody
    # connects: the first player to arrive would land on the previous map.
    echo 'sv_hibernate_when_empty 0'
    # Also on the command line, where it takes effect before the first level
    # loads. Repeated here because default.cfg -- which lives inside the pak1
    # VPK, not in this repository -- may still set it back to 1, and this file
    # is exec'd on every level init.
    echo 'sv_use_steam_networking 0'
    echo 'exec reservation.cfg'
} > "$CFG_DIR/server.cfg"

# 4. Phone home: SSH is up, serveme can push config files.
if [ -n "$CALLBACK_URL" ]; then
    echo "SSH ready, phoning home..."
    for attempt in 1 2 3; do
        if curl -sf --connect-timeout 5 --max-time 10 -X POST "$CALLBACK_URL" \
            -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"ssh_ready\"}"; then
            echo "SSH ready callback successful"
            break
        else
            echo "SSH ready callback attempt $attempt failed, retrying in 5s..."
            sleep 5
        fi
    done
fi

RESERVATION_CFG="$CFG_DIR/reservation.cfg"
echo "Waiting for reservation.cfg..."
for i in $(seq 1 300); do
    [ -f "$RESERVATION_CFG" ] && break
    sleep 1
done
if [ -f "$RESERVATION_CFG" ]; then
    echo "reservation.cfg found"
else
    echo "Warning: reservation.cfg not found after 5 minutes, starting anyway"
fi

# 5. The map list, and the first map itself.
MAPLIST_PATH="$CFG_DIR/maplist_full.txt"
if [ -n "$MAPLIST_URL" ]; then
    if curl -sf --connect-timeout 5 --max-time 15 "$MAPLIST_URL" -o "${MAPLIST_PATH}.tmp" && [ -s "${MAPLIST_PATH}.tmp" ]; then
        mv "${MAPLIST_PATH}.tmp" "$MAPLIST_PATH"
        echo "Map list updated: $(wc -l < "$MAPLIST_PATH") maps"
    else
        rm -f "${MAPLIST_PATH}.tmp"
        echo "Could not refresh the map list, keeping the baked-in version"
    fi
fi

DEFAULT_MAP="${DEFAULT_MAP:-koth_product_final}"
FIRST_MAP_FILE="$CFG_DIR/first_map.txt"
if [ -f "$FIRST_MAP_FILE" ]; then
    FIRST_MAP="$(tr -d '\r\n ' < "$FIRST_MAP_FILE")"
fi
FIRST_MAP="${FIRST_MAP:-$DEFAULT_MAP}"

MAP_PATH="$ROOT/$GAME_DIR/maps/${FIRST_MAP}.bsp"
if [ ! -f "$MAP_PATH" ] && [ -n "$FASTDL_URL" ]; then
    echo "Downloading map: $FIRST_MAP"
    mkdir -p "$ROOT/$GAME_DIR/maps"
    curl -fsSL "${FASTDL_URL%/}/maps/${FIRST_MAP}.bsp" -o "$MAP_PATH" || {
        echo "Warning: could not download $FIRST_MAP"
        rm -f "$MAP_PATH"
    }
fi

# How many maps this build can actually serve, from both search paths gameinfo
# mounts: ours and Team Fortress'. A missing first map is the one boot failure
# with no useful message of its own -- the engine says "not found or invalid"
# and stops -- so a count of zero on either side is worth seeing in the log.
# Maps can also come out of a VPK, so this is a hint, not a verdict, and
# nothing branches on it: the watchdog in step 8 is what recovers.
count_bsp() {
    ls "$1"/*.bsp 2>/dev/null | wc -l | tr -d ' '
}
echo "First map: $FIRST_MAP (default $DEFAULT_MAP)"
echo "Maps installed: $(count_bsp "$ROOT/$GAME_DIR/maps") in $GAME_DIR, $(count_bsp "$ROOT/tf2/tf/maps") from Team Fortress"

# 6. Start the server.
set +e

cd "$ROOT"
export SLR_SNIPER_PATH="${SLR_SNIPER_PATH:-$ROOT/SteamLinuxRuntime_sniper/run}"

graceful_shutdown() {
    echo "Received shutdown signal, stopping STV recording..."
    if [ -x "$ROOT/rcon" ]; then
        timeout 5 "$ROOT/rcon" -H 127.0.0.1 -p "$PORT" -P "${RCON_PASSWORD:-changeme}" tv_stoprecord 2>/dev/null || true
        timeout 5 "$ROOT/rcon" -H 127.0.0.1 -p "$PORT" -P "${RCON_PASSWORD:-changeme}" sv_logflush 1 2>/dev/null || true
        sleep 2
    fi
    echo "Shutdown complete, exiting."
    exit 0
}
trap graceful_shutdown TERM INT

# The launcher runs the game inside the Steam Linux Runtime and swaps in the
# server gameinfo. +ip and +sv_pure are ours to set here: the launcher only
# applies its own defaults when the caller passes none.
#
# Only what genuinely cannot wait for the first level load belongs here -- the
# sockets to bind, the map to boot into, the Steam login, and rcon_password.
# That last one is not vanity: server.cfg is exec'd by the game DLL when a
# level loads, so a server that fails to load its first map has *no* rcon
# password at all, and the map watchdog below could neither see that nor fix
# it. Everything else (the rcon failure limits, the SourceTV settings) is in
# server.cfg, because the command line is a hard 512 bytes for the whole argv
# and going over it does not degrade anything -- the launcher refuses to start.
SRCDS_ARGS=(
    +ip 0.0.0.0 -port "$PORT"
    +clientport "$CLIENT_PORT" -steamport "$STEAM_PORT"
    +rcon_password "$RCON_PASSWORD"
    +sv_use_steam_networking 0
    +map "$FIRST_MAP"
)
[ -n "$GSLT" ] && SRCDS_ARGS+=(+sv_setsteamaccount "$GSLT")
SRCDS_ARGS+=("$@")

# What is left of the 512 after the launcher has prepended its own arguments
# is not ours to know, so leave room for them and say so before the launcher
# does: its own message names no argument and points at -debug, which is a
# long way round to "the rcon password is too long". The password and the
# Steam token are redacted -- this log is collected off the box.
SRCDS_CMDLINE="${SRCDS_ARGS[*]}"
echo "Server arguments, ${#SRCDS_CMDLINE} of the launcher's 512 bytes: $(
    printf '%s' "$SRCDS_CMDLINE" |
        sed -e 's/\(+rcon_password\) [^ ]*/\1 ***/' \
            -e 's/\(+sv_setsteamaccount\) [^ ]*/\1 ***/'
)"
if [ "${#SRCDS_CMDLINE}" -gt 320 ]; then
    echo "WARNING: that is close to the launcher's 512 byte limit, which it" \
         "enforces by refusing to start ('command line too long, 512 max')." \
         "A shorter rcon password is usually what is wanted."
fi

./start_dedicated_tc2.sh "${SRCDS_ARGS[@]}" &
SRCDS_PID=$!

# The coordinator agent, if this container is running a match. It reads the
# match id from sv_tags, keeps the match alive with heartbeats and reports the
# result when the game ends -- none of which the coordinator can see by itself.
if [ -n "$GC_URL" ] && [ -n "$GC_SECRET" ]; then
    echo "Starting greyline-agent for the coordinator at $GC_URL"
    "$ROOT/greyline-agent" \
        -coordinator "$GC_URL" \
        -secret "$GC_SECRET" \
        -rcon "127.0.0.1:${PORT}" \
        -rcon-password "${RCON_PASSWORD:-changeme}" \
        -connect "${SERVER_CONNECT:-}" \
        -log-listen "127.0.0.1:$((PORT + 100))" &
fi

# 7. Wait for the game port, make sure a level actually loaded, then tell
# serveme the server is up.

# The map srcds is on, from its own status output. Empty means it is running
# but has no level -- which is what a missing or corrupt first map leaves
# behind, and it is indistinguishable from "still booting" from the outside.
current_map() {
    [ -x "$ROOT/rcon" ] || return 0
    timeout 5 "$ROOT/rcon" -H 127.0.0.1 -p "$PORT" -P "$RCON_PASSWORD" status 2>/dev/null |
        sed -n 's/^map *: *\([^ ]*\).*/\1/p' | head -1
}

echo "Waiting for the server to listen on port $PORT..."
PORT_UP=0
for i in $(seq 1 180); do
    if ss -tuln | grep -q ":${PORT}[[:space:]]"; then
        PORT_UP=1
        break
    fi
    sleep 1
done

# A first map the payload does not have leaves the server with no level at all:
# the game DLL execs server.cfg -- and so reservation.cfg -- on level init, so
# nothing about the reservation is applied, no player can connect, and the site
# waits for a readiness that never comes. The default map ships with every
# build, so fall back to it rather than sitting there.
MAP_OK=0
if [ "$PORT_UP" = 1 ] && [ -x "$ROOT/rcon" ]; then
    for attempt in $(seq 1 20); do
        MAP_NOW="$(current_map)"
        if [ -n "$MAP_NOW" ]; then
            echo "Server is on map $MAP_NOW"
            MAP_OK=1
            break
        fi
        sleep 2
    done

    if [ "$MAP_OK" != 1 ] && [ "$FIRST_MAP" != "$DEFAULT_MAP" ]; then
        echo "WARNING: the server never loaded $FIRST_MAP, falling back to $DEFAULT_MAP"
        timeout 5 "$ROOT/rcon" -H 127.0.0.1 -p "$PORT" -P "$RCON_PASSWORD" \
            changelevel "$DEFAULT_MAP" >/dev/null 2>&1
        for attempt in $(seq 1 20); do
            MAP_NOW="$(current_map)"
            if [ -n "$MAP_NOW" ]; then
                echo "Server is on map $MAP_NOW"
                MAP_OK=1
                break
            fi
            sleep 2
        done
    fi

    [ "$MAP_OK" = 1 ] || echo "WARNING: the server is listening but has no map loaded"
fi

if [ -n "$CALLBACK_URL" ] && [ "$PORT_UP" = 1 ]; then
    for attempt in 1 2 3; do
        if curl -sf --connect-timeout 5 --max-time 10 -X POST "$CALLBACK_URL" \
            -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"tf2_ready\",\"port\":\"$PORT\"}"; then
            echo "Server ready callback successful"
            break
        else
            echo "Server ready callback attempt $attempt failed, retrying in 5s..."
            sleep 5
        fi
    done
fi

wait $SRCDS_PID
