#!/bin/bash
# Make the simulator's installed app match the built one. This is the single
# home of that rule, and it exists because getting it wrong is SILENT: the app
# launches, the debug channel answers, gestures land, screenshots render — all
# against the previous binary, so every conclusion drawn from them is wrong
# about the code that is actually checked out.
#
# Usage: install-ios.sh <udid> [--check]
#   (no flag)  install when the built binary is newer than the installed one,
#              or when nothing is installed; a no-op otherwise
#   --check    report only, install nothing; exit 1 when the app is stale
#
# INSTALLING ONLY WHEN THE BINARY IS GENUINELY NEWER is what makes this safe to
# call with a drive-ios.sh session live. An unnecessary install is the thing to
# avoid — installcoordinationd serializes it and can bounce the running app a
# minute later, mid-test — while a necessary one is a bounce the caller wanted
# anyway, since both callers relaunch the app immediately after.
#
# TRAP: the mtime comparison is only valid because `simctl install` PRESERVES
# the source binary's mtime. If that ever stops being true this silently
# becomes a no-op, which is the failure it was written to prevent — so
# --check is run by the callers rather than trusted blind.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: install-ios.sh <udid> [--check]" >&2; exit 64; }
UDID="$1"
MODE="${2:-install}"

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_IOS_APP:-$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app}"
BUNDLE_ID="com.commonwealthrecordings.Vibe"

[ -d "$APP" ] || { echo "no app at $APP — build the VibeiOS scheme first, or set VIBE_IOS_APP" >&2; exit 1; }

INSTALLED="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true)"

# Nothing installed, or the build is newer than what is on the device.
if [ -z "$INSTALLED" ] || [ ! -f "$INSTALLED/Vibe" ] || [ "$APP/Vibe" -nt "$INSTALLED/Vibe" ]; then
    if [ "$MODE" = "--check" ]; then
        echo "STALE: the simulator is running an older build than $APP" >&2
        exit 1
    fi
    xcrun simctl install "$UDID" "$APP"
    # Prove it landed rather than assume it: see the mtime trap above.
    INSTALLED="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true)"
    if [ -z "$INSTALLED" ] || [ "$APP/Vibe" -nt "$INSTALLED/Vibe" ]; then
        echo "install did not take: $APP is still newer than what is on $UDID" >&2
        exit 1
    fi
fi
