#!/bin/bash
# Print the UDID of this session's iPhone simulator, named from the checkout
# path plus CLAUDE_CODE_SESSION_ID, so concurrent sessions — even in one
# checkout — never share an app container, debug channel or touch driver.
# Outside Claude Code: one device per checkout.
#
# Usage: sim-udid.sh [--create]
#   --create   create the device if missing (the first available iPhone's
#              device type and runtime); does not boot it
# Overrides: VIBE_SIM_UDID is printed as-is (`booted` means any booted
# device); VIBE_SIM_NAME replaces the derived name.
# Exit 1 when the device does not exist and --create was not given.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"

if [ -n "${VIBE_SIM_UDID:-}" ]; then printf '%s\n' "$VIBE_SIM_UDID"; exit 0; fi

HASH="$(printf '%s' "$ROOT|${CLAUDE_CODE_SESSION_ID:-}" | /usr/bin/shasum | cut -c1-8)"
NAME="${VIBE_SIM_NAME:-Vibe-$(basename "$ROOT")-$HASH}"

JSON="$(xcrun simctl list devices available -j)"
UDID="$(printf '%s' "$JSON" | jq -r --arg n "$NAME" \
        '[.devices[][] | select(.name == $n)][0].udid // empty')"

# Ended sessions leave multi-GB devices behind: delete Vibe-* devices that are
# Shutdown, not this session's, and untouched for 12h. The age gate spares a
# concurrent session's device created but not yet booted.
# TRAP: -mmin, not -mtime: -mtime +1 truncates to whole days and spares
# anything under 48h.
printf '%s' "$JSON" | jq -r --arg n "$NAME" '.devices[][]
        | select((.name | startswith("Vibe-")) and .state == "Shutdown" and .name != $n)
        | [.udid, .dataPath] | @tsv' \
| while IFS=$'\t' read -r OLD DATAPATH; do
    [ -n "$(find "$DATAPATH" -maxdepth 0 -mmin +720 2>/dev/null)" ] || continue
    xcrun simctl delete "$OLD" >/dev/null 2>&1 || true
done

if [ -z "$UDID" ] && [ "${1:-}" = "--create" ]; then
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
