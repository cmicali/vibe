#!/bin/bash
# Run one debug command against the iOS app in the booted simulator and print
# its JSON reply. The iOS counterpart of `Vibe --debug-cmd`: there is no CLI
# client — the simulator app's container tmp is a plain host directory, so
# this writes the command file and reads the reply directly. The app watches
# its tmp with a vnode source (DebugChannel.m), so no notification is needed.
#
# Usage: debug-ios.sh <verb> [args ...]         (e.g. debug-ios.sh dump_state)
# Timeout: 10s default; VIBE_DEBUG_TIMEOUT=<seconds> overrides (clear_caches
# can take up to 15s on a full cache).
# Exit codes match the mac client: 0 ok, 1 no response (no debug build
# running), 2 command error.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: debug-ios.sh <verb> [args ...]" >&2; exit 64; }

BUNDLE_ID="com.commonwealthrecordings.Vibe"
DATA="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)" \
    || { echo '{"error": "no booted simulator with the app installed"}'; exit 1; }
TMP="$DATA/tmp"
[ -d "$TMP" ] || { echo '{"error": "app container has no tmp directory"}'; exit 1; }

ID="$(uuidgen)"
CMD="$TMP/vibe-command-$ID.json"
RESPONSE="$TMP/vibe-response-$ID.txt"

# Rename the finished file into place: the app's directory watcher fires on
# every tmp mutation, and a command file read mid-write is deleted unexecuted.
# The .part name matches neither the command prefix nor suffix, so the drain
# ignores it.
jq -cn --arg id "$ID" '{id: $id, args: $ARGS.positional}' --args -- "$@" > "$CMD.part"
mv "$CMD.part" "$CMD"

TIMEOUT="${VIBE_DEBUG_TIMEOUT:-10}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ ! -f "$RESPONSE" ]; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        # Mirror the mac client: take the unexecuted command back so a later
        # drain cannot run it out of nowhere.
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
