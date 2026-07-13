#!/bin/bash
# Relaunch the debug build (killing any running Vibe) with optional audio
# files, then wait until the app answers on the debug command channel and
# print its `state` JSON. Replaces the open-then-guess-a-sleep dance.
#
# Usage: launch.sh [audio-file ...]
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
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
        open -a "$APP" "$@"
        sleep 2
    fi
    if "$V" --debug-cmd state 2>/dev/null; then
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
