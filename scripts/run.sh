#!/usr/bin/env bash
#
# Launch Vibe, building it first (via scripts/build.sh) only if it isn't built yet.
#
# Usage: scripts/run.sh [Debug|Release] [args...]   (default: Release)
#
# Everything after the configuration is handed to Vibe as its process arguments.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="Release"
if [[ $# -gt 0 ]]; then
    case "$1" in
        Debug|Release) CONFIGURATION="$1"; shift ;;
        debug|release|DEBUG|RELEASE)
            echo "error: configuration must be Debug or Release (got '$1')" >&2; exit 1 ;;
    esac
fi

APP="build/DerivedData/Build/Products/$CONFIGURATION/Vibe.app"

# Build only if the app isn't already present; `make clean` (or deleting build/)
# forces a rebuild on the next run.
if [[ ! -e "$APP" ]]; then
    scripts/build.sh "$CONFIGURATION"
fi

# Quit a running instance first so `open` launches this on-disk build —
# Vibe is single-instance, so otherwise `open` just reactivates the old copy.
if pgrep -x Vibe >/dev/null; then
    osascript -e 'tell application "Vibe" to quit' >/dev/null 2>&1 || pkill -x Vibe 2>/dev/null || true
    for _ in $(seq 1 25); do pgrep -x Vibe >/dev/null || break; sleep 0.2; done
    if pgrep -x Vibe >/dev/null; then
        echo "error: the running Vibe instance did not quit; 'open' would only reactivate it" >&2
        exit 1
    fi
fi

echo "🔊 running $APP${*+ $*}"
if [[ $# -gt 0 ]]; then
    open "$APP" --args "$@"
else
    open "$APP"
fi
