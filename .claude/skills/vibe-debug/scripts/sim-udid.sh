#!/bin/bash
# Print the UDID of this session's dedicated iPhone simulator. The device is
# named from the checkout path PLUS the Claude session id when present, so
# concurrent agent sessions — even in the same checkout — each get their own
# simulator (separate app container, debug channel, and touch driver) instead
# of fighting over `booted`. Run outside Claude Code it falls back to one
# stable device per checkout.
#
# Usage: sim-udid.sh [--create]
#   --create   create the device if it does not exist (modeled on the first
#              available iPhone's device type and runtime); does NOT boot it
# Overrides: VIBE_SIM_UDID is printed as-is (the value `booted` restores the
# old any-booted-device behavior); VIBE_SIM_NAME replaces the derived name.
# Exits 1 with a message on stderr when the device does not exist and
# --create was not given.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"

if [ -n "${VIBE_SIM_UDID:-}" ]; then printf '%s\n' "$VIBE_SIM_UDID"; exit 0; fi

HASH="$(printf '%s' "$ROOT|${CLAUDE_CODE_SESSION_ID:-}" | /usr/bin/shasum | cut -c1-8)"
NAME="${VIBE_SIM_NAME:-Vibe-$(basename "$ROOT")-$HASH}"

JSON="$(xcrun simctl list devices available -j)"
UDID="$(printf '%s' "$JSON" | jq -r --arg n "$NAME" \
        '[.devices[][] | select(.name == $n)][0].udid // empty')"

if [ -z "$UDID" ] && [ "${1:-}" = "--create" ]; then
    # Session-scoped names mean ended sessions leave devices behind: delete
    # Vibe-* devices that are Shutdown and untouched for a day. Age-gating on
    # the data dir keeps a concurrent session's freshly created (not yet
    # booted) device safe.
    printf '%s' "$JSON" | jq -r '.devices[][]
            | select((.name | startswith("Vibe-")) and .state == "Shutdown")
            | [.udid, .dataPath] | @tsv' \
    | while IFS=$'\t' read -r OLD DATAPATH; do
        [ -n "$(find "$DATAPATH" -maxdepth 0 -mtime +1 2>/dev/null)" ] || continue
        xcrun simctl delete "$OLD" >/dev/null 2>&1 || true
    done

    MODEL="$(printf '%s' "$JSON" | jq -r 'first(.devices | to_entries[]
            | .key as $rt | .value[] | select(.name | startswith("iPhone"))
            | "\(.deviceTypeIdentifier)\t\($rt)") // empty')"
    [ -n "$MODEL" ] || { echo "no available iPhone simulator to model $NAME on" >&2; exit 1; }
    UDID="$(xcrun simctl create "$NAME" "${MODEL%%$'\t'*}" "${MODEL##*$'\t'}")"
fi

[ -n "$UDID" ] || {
    echo "no simulator named $NAME — launch-ios.sh or drive-ios.sh start creates it, or set VIBE_SIM_UDID" >&2
    exit 1
}
printf '%s\n' "$UDID"
