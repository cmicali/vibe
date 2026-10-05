#!/bin/bash
# Run one debug command against the iOS app on this session's simulator
# (sim-udid.sh, never `booted`) and print its JSON reply. There is no CLI
# client: the app's container tmp is a host directory, so this writes the
# command file and reads the reply; the app's vnode watcher (DebugChannel.m)
# picks it up.
#
# Usage: debug-ios.sh <verb> [args ...]
#        debug-ios.sh --all <verb> [<verb> ...]
#   --all sends argument-less verbs together, one drain answering them all,
#   and prints their replies as one JSON array in order: a poll of six dumps
#   costs one round trip, not six.
# Timeout: VIBE_DEBUG_TIMEOUT seconds when set; otherwise the verb's own
# clientTimeout from the shared table (DebugCommonVerbs.m: clear_caches 20,
# block_main and block_main_deep 30, file_cache 60), else 10.
# VIBE_APP_TMP: the app container's tmp, resolved once by a caller that sends
# many commands (`simctl get_app_container` is most of a round trip). Valid
# only until the next install, which moves the container.
# Exit: 0 ok, 1 no response, 2 command error (as the mac client; under --all,
# any reply's error).
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: debug-ios.sh <verb> [args ...] | --all <verb> ..." >&2; exit 64; }

DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="com.commonwealthrecordings.Vibe"
TMP="${VIBE_APP_TMP:-}"
if [ -z "$TMP" ]; then
    UDID="$("$DIR/sim-udid.sh" 2>/dev/null)" \
        || { echo '{"error": "no simulator for this session — run launch-ios.sh first (or set VIBE_SIM_UDID)"}'; exit 1; }
    DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)" \
        || { echo '{"error": "app not installed on this session'"'"'s simulator — run launch-ios.sh"}'; exit 1; }
    TMP="$DATA/tmp"
fi
[ -d "$TMP" ] || { echo '{"error": "app container has no tmp directory"}'; exit 1; }

# Rename into place: the watcher fires on every tmp mutation and a command
# read mid-write is deleted unexecuted. The drain ignores the .part name.
send() {   # <id> <args ...>
    local id="$1"; shift
    jq -cn --arg id "$id" '{id: $id, args: $ARGS.positional}' --args -- "$@" > "$TMP/vibe-command-$id.json.part"
    mv "$TMP/vibe-command-$id.json.part" "$TMP/vibe-command-$id.json"
}

ALL=""
if [ "$1" = "--all" ]; then
    ALL=1
    shift
    [ "$#" -ge 1 ] || { echo "usage: debug-ios.sh --all <verb> ..." >&2; exit 64; }
    VERBS=("$@")
else
    VERBS=("$1")
fi

# Mirrors the table's clientTimeout: there is no client here to read it.
VERB_TIMEOUT=10
for verb in "${VERBS[@]}"; do
    case "$verb" in
        clear_caches) t=20 ;;
        block_main|block_main_deep) t=30 ;;
        file_cache) t=60 ;;
        *) t=10 ;;
    esac
    [ "$t" -le "$VERB_TIMEOUT" ] || VERB_TIMEOUT="$t"
done
TIMEOUT="${VIBE_DEBUG_TIMEOUT:-$VERB_TIMEOUT}"

IDS=()
cleanup() {
    for id in ${IDS[@]+"${IDS[@]}"}; do
        rm -f "$TMP/vibe-command-$id.json" "$TMP/vibe-command-$id.json.part" "$TMP/vibe-response-$id.txt"
    done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$ALL" ]; then
    for verb in "${VERBS[@]}"; do ID="$(uuidgen)"; IDS+=("$ID"); send "$ID" "$verb"; done
else
    ID="$(uuidgen)"; IDS+=("$ID"); send "$ID" "$@"
fi

DEADLINE=$(( $(date +%s) + TIMEOUT ))
REPLIES=()
STATUS=0
for ID in "${IDS[@]}"; do
    RESPONSE="$TMP/vibe-response-$ID.txt"
    while [ ! -f "$RESPONSE" ] && [ "$(date +%s)" -lt "$DEADLINE" ]; do
        sleep 0.02
    done
    if [ -f "$RESPONSE" ]; then
        REPLIES+=("$(cat "$RESPONSE")")
        printf '%s' "${REPLIES[${#REPLIES[@]}-1]}" | jq -e 'has("error") | not' >/dev/null 2>&1 || STATUS=2
    else
        # EXIT takes commands back so a later drain cannot run them.
        REPLIES+=('{"error": "no response — is a Debug build of VibeiOS running?"}')
        STATUS=1
    fi
done

if [ -n "$ALL" ]; then
    printf '%s\n' "${REPLIES[@]}" | jq -cs .
else
    printf '%s\n' "${REPLIES[0]}"
fi
exit "$STATUS"
