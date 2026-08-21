#!/bin/bash
# Relaunch the iOS debug build in this checkout's dedicated simulator
# (sim-udid.sh — created and booted on first use, so concurrent sessions in
# different worktrees never share a device), seeding optional audio files
# into the app container first. The iOS counterpart of launch.sh.
#
# Usage: launch-ios.sh [audio-file ...]
# Device: VIBE_SIM_UDID pins one; VIBE_SIM_NAME renames the derived one.
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

# This checkout's dedicated device, created on first use. bootstatus -b boots
# and blocks until ready (a no-op when already booted), so no guessed sleep.
UDID="$("$DIR/sim-udid.sh" --create)"
xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator   # surface the window; input/screenshot tooling needs it visible

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
# install-ios.sh installs only when the built binary is newer, which is what
# makes it safe to call unconditionally — a drive-ios.sh session included.
# This script used to SKIP the install outright while a driver was live and
# merely warn, on the reasoning that a competing install can bounce the running
# app mid-test. That traded a loud, wanted bounce for a silent stale binary:
# gestures ran against the previous build and every conclusion drawn from them
# was wrong. An unnecessary install is still avoided — by not being necessary.
VIBE_IOS_APP="$APP" "$DIR/install-ios.sh" "$UDID"

if [ "$#" -gt 0 ]; then
    DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
    mkdir -p "$DATA/Documents/Music"
    cp "$@" "$DATA/Documents/Music/"
fi

ARGS=()
[ -n "${VIBE_LANGUAGE:-}" ] && ARGS+=(-AppleLanguages "(${VIBE_LANGUAGE})")
[ -z "${VIBE_AUDIBLE:-}" ] && ARGS+=(--no-audio-hw --silent)
xcrun simctl launch "$UDID" "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"}

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
    DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
    xcrun simctl openurl "$UDID" "file://$DATA/Documents/Music/$(basename "$FIRST")"
fi
