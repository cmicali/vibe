#!/bin/bash
# Relaunch the iOS debug build in the simulator (booting one if needed),
# seeding optional audio files into the app container first, then print the
# booted device and app pid. The iOS counterpart of launch.sh.
#
# Usage: launch-ios.sh [audio-file ...]
# App path: $VIBE_IOS_APP if set, else
#   <repo>/build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app
# Audio is SILENT by default (launches with --no-audio-hw --silent — the
# shared engine honors the same debug argv flags as macOS), so a test run
# never plays through the mac's speakers; set VIBE_AUDIBLE=1 to hear it.
# Set VIBE_LANGUAGE=de (a catalog code) to launch in that language.
#
# Seeded files land in Documents/Music inside the app container — the same
# folder the in-app picker reaches via Browse > On My iPhone > Vibe > Music.
# When files are passed, the FIRST one is also opened via openurl (the
# open-in-place path), which makes a ONE-track playlist; pick the Music
# folder in-app to get the whole seeded folder as the playlist.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_IOS_APP:-$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app}"
BUNDLE_ID="com.commonwealthrecordings.Vibe"
[ -d "$APP" ] || { echo "no app at $APP — build the VibeiOS scheme first, or set VIBE_IOS_APP" >&2; exit 1; }

# Boot the first available iPhone if nothing is booted. bootstatus -b boots
# and blocks until ready, so there is no guessed sleep.
if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
    UDID="$(xcrun simctl list devices available | grep -m1 "iPhone" \
            | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    [ -n "$UDID" ] || { echo "no available iPhone simulator" >&2; exit 1; }
    xcrun simctl bootstatus "$UDID" -b >/dev/null
fi
open -a Simulator   # surface the window; input/screenshot tooling needs it visible

xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install booted "$APP"

if [ "$#" -gt 0 ]; then
    DATA="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)"
    mkdir -p "$DATA/Documents/Music"
    cp "$@" "$DATA/Documents/Music/"
fi

ARGS=()
[ -n "${VIBE_LANGUAGE:-}" ] && ARGS+=(-AppleLanguages "(${VIBE_LANGUAGE})")
[ -z "${VIBE_AUDIBLE:-}" ] && ARGS+=(--no-audio-hw --silent)
xcrun simctl launch booted "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"}

# Poll the debug channel until the app answers, as launch.sh does — no guessed
# sleeps. Short per-attempt timeouts because a command written during startup
# is swept as stale by the channel install; a fresh one lands. Falls back to a
# flat 2s for a channel that never answers (a non-debug build).
READY=""
for _ in $(seq 1 15); do
    if VIBE_DEBUG_TIMEOUT=1 "$DIR/debug-ios.sh" dump_state 2>/dev/null; then
        READY=1
        break
    fi
done
[ -n "$READY" ] || sleep 2

if [ "$#" -gt 0 ]; then
    FIRST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    DATA="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data)"
    xcrun simctl openurl booted "file://$DATA/Documents/Music/$(basename "$FIRST")"
fi
