#!/bin/bash
# Relaunch the debug build (killing any running Vibe) with optional audio
# files, then wait until the app answers on the debug command channel and
# print its `state` JSON. Replaces the open-then-guess-a-sleep dance.
#
# Usage: launch.sh [audio-file ...]
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
# Audio is OFF-HARDWARE by default (launches with --no-audio-hw --silent), so
# no output device is opened and macOS's automatic AirPods switching can't
# trigger; set VIBE_AUDIBLE=1 to use real hardware and hear playback.
# Set VIBE_LANGUAGE=de (a catalog code) to launch
# the app in that language via -AppleLanguages — per-launch only, no prefs
# reset needed.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "no app at $APP — build first, or set VIBE_APP" >&2; exit 1; }

pkill -x Vibe 2>/dev/null && sleep 1 || true

# Each client call itself waits up to 5s; a command posted before the app's
# hook installs is lost (the notification carries nothing), so retry. The
# open is re-issued if the process isn't up — right after a rebuild the first
# open can silently produce nothing (LaunchServices re-registering the bundle).
for _ in 1 2 3 4 5 6; do
    if ! pgrep -x Vibe >/dev/null; then
        # --args must come last; everything after it becomes the app's argv.
        # The -AppleLanguages value must be one argv element shaped like a
        # plist array: (de). bash 3.2 + set -u dies on "${ARGS[@]}" when the
        # array is empty, hence the ${ARGS[@]+...} idiom.
        ARGS=()
        [ -n "${VIBE_LANGUAGE:-}" ] && ARGS+=(-AppleLanguages "(${VIBE_LANGUAGE})")
        [ -z "${VIBE_AUDIBLE:-}" ] && ARGS+=(--no-audio-hw --silent)
        if [ "${#ARGS[@]}" -gt 0 ]; then
            open -a "$APP" "$@" --args ${ARGS[@]+"${ARGS[@]}"}
        else
            open -a "$APP" "$@"
        fi
        sleep 2
    fi
    if "$V" --debug-cmd dump_state 2>/dev/null; then
        # Guard against LaunchServices having routed open -a to an
        # Xcode-run instance of a different build.
        RUNNING="$(ps -o command= -p "$(pgrep -x Vibe | head -1)" 2>/dev/null || true)"
        case "$RUNNING" in
            "$V"*) ;;
            *) echo "warning: running binary is: $RUNNING" >&2 ;;
        esac
        exit 0
    fi
done
echo "vibe: app never answered on the debug channel" >&2
exit 1
