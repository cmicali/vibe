#!/bin/bash
# Relaunch the iOS debug build on this session's simulator (sim-udid.sh;
# created and booted on first use), installing the built app when it differs
# and seeding optional audio files first. The iOS counterpart of launch.sh.
#
# Usage: launch-ios.sh [audio-file ...]
# Device: VIBE_SIM_UDID pins one; VIBE_SIM_NAME renames the derived one.
# App path: $VIBE_IOS_APP if set, else
#   <repo>/build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app
# Audio: --no-audio-hw --silent by default, so nothing reaches the mac's
# speakers; VIBE_AUDIBLE=1 to hear it, VIBE_AUDIBLE=silent for the real
# RemoteIO output unit with its buffers zeroed.
# VIBE_LANGUAGE=de (a catalog code) launches in that language.
#
# Files land in the container's Documents/Music (in-app: Browse > On My iPhone
# > Vibe > Music). The FIRST is also opened via openurl, which makes a
# one-track playlist; pick the Music folder in-app for all of them.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_IOS_APP:-$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app}"
BUNDLE_ID="com.commonwealthrecordings.Vibe"
[ -d "$APP" ] || { echo "no app at $APP — build the VibeiOS scheme first, or set VIBE_IOS_APP" >&2; exit 1; }

# bootstatus -b boots and blocks until ready; a no-op when already booted.
UDID="$("$DIR/sim-udid.sh" --create)"
xcrun simctl bootstatus "$UDID" -b >/dev/null
# TRAP: Xcode 27 has no Simulator.app (devices live in Device Hub), so
# `open -a Simulator` fails and, under set -e, aborts the launch. The window is
# only for a human watching — everything here is headless — so never fail.
open -a "Device Hub" 2>/dev/null || true

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
# Unconditional, a live drive-ios.sh session included: install-ios.sh installs
# only when the content differs, and skipping it leaves gestures silently
# running against the previous build.
VIBE_IOS_APP="$APP" "$DIR/install-ios.sh" "$UDID"

if [ "$#" -gt 0 ]; then
    DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
    mkdir -p "$DATA/Documents/Music"
    cp "$@" "$DATA/Documents/Music/"
fi

ARGS=()
[ -n "${VIBE_LANGUAGE:-}" ] && ARGS+=(-AppleLanguages "(${VIBE_LANGUAGE})")
case "${VIBE_AUDIBLE:-}" in
    "")     ARGS+=(--no-audio-hw --silent) ;;
    silent) ARGS+=(--silent) ;;
esac
xcrun simctl launch "$UDID" "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"}

# Short per-attempt timeouts: a command written before the channel installs is
# swept as stale, and a fresh one lands. A channel that never answers (a
# non-debug build) gets a warning after 30 s.
# TRAP: ask THIS device's app. An inherited VIBE_APP_TMP names another
# simulator's container (dropbox-streaming.sh exports its own before booting
# workers), so that app answered for one still starting, and the caller's
# first command was swept.
TMP="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/tmp"
READY=""
DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if VIBE_APP_TMP="$TMP" VIBE_DEBUG_TIMEOUT=1 "$DIR/debug-ios.sh" dump_state 2>/dev/null; then
        READY=1
        break
    fi
    sleep 0.2
done
[ -n "$READY" ] || echo "launch-ios.sh: the debug channel on $UDID did not answer in 30 s" >&2

# A live touch driver holds the process just killed: without a re-attach its
# next gesture waits a minute and then relaunches the app itself (the TRAP in
# Tests/iOSDriver/VibeiOSDriverTests.m). No driver: nothing to do.
if [ -f "$ROOT/build/ios-driver/$UDID/vibe-driver-ready" ]; then
    VIBE_SIM_UDID="$UDID" VIBE_DEBUG_TIMEOUT=30 "$DIR/drive-ios.sh" attach >/dev/null 2>&1 || true
fi

if [ "$#" -gt 0 ]; then
    FIRST="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
    xcrun simctl openurl "$UDID" "file://$DATA/Documents/Music/$(basename "$FIRST")"
fi
