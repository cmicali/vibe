#!/usr/bin/env bash
#
# Launch Vibe, building it first (via scripts/build/build.sh) only if it isn't built yet.
#
# Usage: scripts/build/run.sh [Debug|Release] [args...]   (default: Release)
#
# Everything after the configuration is handed to Vibe as its process arguments.
set -euo pipefail

cd "$(dirname "$0")/../.."

CONFIGURATION="Release"
if [[ $# -gt 0 ]]; then
    case "$1" in
        Debug|Release) CONFIGURATION="$1"; shift ;;
        debug|release|DEBUG|RELEASE)
            echo "error: configuration must be Debug or Release (got '$1')" >&2; exit 1 ;;
    esac
fi

# Only a Debug build is slotted (scripts/vibe-env.sh).
. scripts/vibe-env.sh
APP="$VIBE_APP"
[[ "$CONFIGURATION" == Debug ]] || APP="$VIBE_DERIVED_DATA/Build/Products/$CONFIGURATION/Vibe.app"

if [[ ! -e "$APP" ]]; then
    scripts/build/build.sh "$CONFIGURATION"
fi

# Its ids, from its Info.plist.
export VIBE_APP="$APP"
. scripts/vibe-env.sh

# One instance per bundle id: without the quit, `open` reactivates the old copy.
vibe_quit_own || {
    echo "error: the running $VIBE_PRODUCT did not quit; 'open' would only reactivate it" >&2
    exit 1
}

echo "🔊 running $APP${*+ $*}"
ARGS=()
[[ $# -gt 0 ]] && ARGS=(--args "$@")
# TRAP: right after a quit, Launch Services can still hand the open to the
# exiting process, and it fails with -600. One retry covers it.
open "$APP" ${ARGS[@]+"${ARGS[@]}"} || { sleep 1; open "$APP" ${ARGS[@]+"${ARGS[@]}"}; }
