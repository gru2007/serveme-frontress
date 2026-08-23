#!/bin/bash
set -e

# Bring up one Team Frontress dedicated server for one reservation.
#
# The order matters and is the same every time:
#
#   1. SSH, so serveme can push configs and collect logs and demos
#   2. check the game payload is the build the site expects
#   3. write server.cfg, which execs reservation.cfg
#   4. tell serveme we are reachable; wait for it to push reservation.cfg
#   5. make sure the first map exists locally
#   6. start the server, and the coordinator agent if this is a match
#
# Everything the server needs per match -- password, ruleset, match tag -- is
# in reservation.cfg. Nothing in this script decides any of it.

GAME_DIR="${GAME_DIR:-tc2}"
ROOT="$HOME/hlserver"
CFG_DIR="$ROOT/$GAME_DIR/cfg"

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

# 3. server.cfg. Everything reservation-specific is in reservation.cfg, which
# serveme writes; this is only what has to be true before that arrives.
mkdir -p "$CFG_DIR"
{
    echo 'hostname "Team Frontress"'
    [ -n "$FASTDL_URL" ] && echo "sv_downloadurl \"${FASTDL_URL}\""
    echo "rcon_password \"${RCON_PASSWORD:-changeme}\""
    echo 'log on'
    echo 'sv_logecho 1'
    echo 'tv_autorecord 1'
    echo 'sv_rcon_minfailuretime 1'
    echo 'sv_rcon_minfailures 20'
    echo 'sv_rcon_maxfailures 20'
    echo 'sv_rcon_banpenalty 1'
    # A matchmade server must not act on a map change only once somebody
    # connects: the first player to arrive would land on the previous map.
    echo 'sv_hibernate_when_empty 0'
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

FIRST_MAP_FILE="$CFG_DIR/first_map.txt"
if [ -f "$FIRST_MAP_FILE" ]; then
    FIRST_MAP="$(tr -d '\r\n ' < "$FIRST_MAP_FILE")"
fi
FIRST_MAP="${FIRST_MAP:-${DEFAULT_MAP:-koth_product_final}}"

MAP_PATH="$ROOT/$GAME_DIR/maps/${FIRST_MAP}.bsp"
if [ ! -f "$MAP_PATH" ] && [ -n "$FASTDL_URL" ]; then
    echo "Downloading map: $FIRST_MAP"
    mkdir -p "$ROOT/$GAME_DIR/maps"
    curl -fsSL "${FASTDL_URL%/}/maps/${FIRST_MAP}.bsp" -o "$MAP_PATH" || {
        echo "Warning: could not download $FIRST_MAP"
        rm -f "$MAP_PATH"
    }
fi

# 6. Start the server.
set +e
PORT="${PORT:-27015}"
TV_PORT="${TV_PORT:-$((PORT + 5))}"
CLIENT_PORT="${CLIENT_PORT:-40001}"
STEAM_PORT="${STEAM_PORT:-30001}"
FAKEIP_FLAG="${ENABLE_FAKEIP:+-enablefakeip}"

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
./start_dedicated_tc2.sh \
    +ip 0.0.0.0 -port "$PORT" $FAKEIP_FLAG \
    +clientport "$CLIENT_PORT" -steamport "$STEAM_PORT" \
    +map "$FIRST_MAP" +tv_port "$TV_PORT" +tv_maxclients 32 +tv_enable 1 \
    ${GSLT:+ +sv_setsteamaccount "$GSLT"} \
    "$@" &
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

# 7. Wait for the game port, then tell serveme the server is up.
if [ -n "$CALLBACK_URL" ]; then
    echo "Waiting for the server to listen on port $PORT..."
    for i in $(seq 1 180); do
        if ss -tuln | grep -q ":${PORT}[[:space:]]"; then
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
            break
        fi
        sleep 1
    done
fi

wait $SRCDS_PID
