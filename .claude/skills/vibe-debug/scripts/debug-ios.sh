#!/bin/bash
# Run one debug command against the iOS app on this session's simulator
# (sim-udid.sh, never `booted`) and print its JSON reply. There is no CLI
# client: the app's container tmp is a host directory, so this writes the
# command file and reads the reply; the app's vnode watcher (DebugChannel.m)
# picks it up.
#
# Usage: debug-ios.sh <verb> [args ...]
# Timeout: VIBE_DEBUG_TIMEOUT seconds, default 10 — raise it for clear_caches,
# which can take 15s on a full cache.
# Exit: 0 ok, 1 no response, 2 command error (as the mac client).
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: debug-ios.sh <verb> [args ...]" >&2; exit 64; }

DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="com.commonwealthrecordings.Vibe"
UDID="$("$DIR/sim-udid.sh" 2>/dev/null)" \
    || { echo '{"error": "no simulator for this checkout — run launch-ios.sh first (or set VIBE_SIM_UDID)"}'; exit 1; }
DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)" \
    || { echo '{"error": "app not installed on this checkout'"'"'s simulator — run launch-ios.sh"}'; exit 1; }
TMP="$DATA/tmp"
[ -d "$TMP" ] || { echo '{"error": "app container has no tmp directory"}'; exit 1; }

ID="$(uuidgen)"
CMD="$TMP/vibe-command-$ID.json"
RESPONSE="$TMP/vibe-response-$ID.txt"

# Rename into place: the watcher fires on every tmp mutation and a command
# read mid-write is deleted unexecuted. The drain ignores the .part name.
jq -cn --arg id "$ID" '{id: $id, args: $ARGS.positional}' --args -- "$@" > "$CMD.part"
mv "$CMD.part" "$CMD"

TIMEOUT="${VIBE_DEBUG_TIMEOUT:-10}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ ! -f "$RESPONSE" ]; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        # Take the command back so a later drain cannot run it out of nowhere.
        rm -f "$CMD"
        echo '{"error": "no response — is a Debug build of VibeiOS running?"}'
        exit 1
    fi
    sleep 0.05
done

OUT="$(cat "$RESPONSE")"
rm -f "$RESPONSE"
printf '%s\n' "$OUT"
printf '%s' "$OUT" | jq -e 'has("error") | not' >/dev/null 2>&1 || exit 2
