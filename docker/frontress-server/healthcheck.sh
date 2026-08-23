#!/bin/bash
# Is the game server answering? RCON is the only check that proves the server
# is actually serving rather than merely running.
PORT="${PORT:-27015}"
RCON_PASSWORD="${RCON_PASSWORD:-changeme}"

output=$(timeout 5 "$HOME/hlserver/rcon" -H 127.0.0.1 -p "$PORT" -P "$RCON_PASSWORD" status 2>&1)
if [ $? -ne 0 ]; then
    echo "RCON status failed"
    exit 1
fi

if echo "$output" | grep -q "hostname"; then
    exit 0
else
    echo "RCON status returned unexpected output"
    exit 1
fi
