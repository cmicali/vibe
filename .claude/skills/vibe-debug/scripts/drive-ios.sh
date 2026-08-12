#!/bin/bash
# Drive touches on the iOS app in the booted simulator — the iOS counterpart
# of the mac channel's key/click injection, via the resident VibeiOSDriver
# XCUITest (the only sanctioned touch-synthesis path on iOS; see
# Tests/iOSDriver). Coordinates are app-window POINTS, top-left origin —
# simctl screenshot pixels divided by the screen scale (dump_screenshot
# reports it; 3 on modern iPhones).
#
# Usage:
#   drive-ios.sh start          # build + launch the driver, wait until ready
#                               #   (reinstalls the app: run BEFORE launch-ios.sh)
#   drive-ios.sh stop           # end the session
#   drive-ios.sh status         # ready or not
#   drive-ios.sh tap 201 640
#   drive-ios.sh double_tap 201 640
#   drive-ios.sh press 201 640 1.5
#   drive-ios.sh drag 300 640 100 640 1.0    # x1 y1 x2 y2 [seconds]; give
#                               # seconds for 1:1 scrubs, omit for a flick
#   drive-ios.sh home
#
# Verify every gesture's effect with debug-ios.sh dump_state or a screenshot —
# the reply only means the gesture was performed, not that it landed where
# intended. Exit codes: 0 ok, 1 no response, 2 command error, 64 usage.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: drive-ios.sh start|stop|status|<gesture> [args ...]" >&2; exit 64; }

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
BUNDLE_ID="com.commonwealthrecordings.Vibe"
READY_NAME="vibe-driver-ready"
LOG="$ROOT/build/driver-ios.log"

container_tmp() {
    local data
    data="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)" || return 1
    echo "$data/tmp"
}

# stop is the quit verb by another name; macOS bash has no ;;& fallthrough.
[ "$1" = "stop" ] && set -- quit

case "$1" in
start)
    if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
        UDID="$(xcrun simctl list devices available | grep -m1 "iPhone" \
                | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
        [ -n "$UDID" ] || { echo "no available iPhone simulator" >&2; exit 1; }
        xcrun simctl bootstatus "$UDID" -b >/dev/null
    fi
    UDID="$(xcrun simctl list devices booted | grep -m1 "(Booted)" \
            | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    # xcodebuild test installs the app fresh, terminating any running
    # instance — hence start-then-launch. The app must be installed before the
    # container tmp exists, so build first, then resolve the directory.
    ( cd "$ROOT" && xcodegen generate >/dev/null )
    TMP="$(container_tmp || true)"
    if [ -z "$TMP" ]; then
        # First run on a fresh simulator: install the app so the container exists.
        APP="$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app"
        [ -d "$APP" ] && xcrun simctl install booted "$APP" 2>/dev/null || true
        TMP="$(container_tmp)" || { echo "app not installed — build VibeiOS and run launch-ios.sh once" >&2; exit 1; }
    fi
    rm -f "$TMP/$READY_NAME"
    ( cd "$ROOT" && TEST_RUNNER_VIBE_DRIVER_DIR="$TMP" \
        nohup xcodebuild test -project Vibe.xcodeproj -scheme VibeiOSDriver \
            -destination "id=$UDID" -derivedDataPath build/DerivedData \
            CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1 & )
    # Build + install + runner spin-up; the marker is the readiness signal.
    for _ in $(seq 1 240); do
        [ -f "$TMP/$READY_NAME" ] && { echo '{"ok": true, "ready": true}'; exit 0; }
        sleep 1
    done
    echo "{\"error\": \"driver never became ready — see $LOG\"}"
    exit 1
    ;;
status)
    TMP="$(container_tmp)" || { echo '{"ready": false}'; exit 1; }
    if [ -f "$TMP/$READY_NAME" ]; then echo '{"ready": true}'; else echo '{"ready": false}'; exit 1; fi
    ;;
*)
    TMP="$(container_tmp)" || { echo '{"error": "no booted simulator with the app installed"}'; exit 1; }
    [ -f "$TMP/$READY_NAME" ] || { echo '{"error": "driver not running — drive-ios.sh start first"}'; exit 1; }
    ID="$(uuidgen)"
    CMD="$TMP/vibe-touch-$ID.json"
    RESPONSE="$TMP/vibe-touch-response-$ID.txt"
    # Atomic rename, as in debug-ios.sh: the driver polls the directory and a
    # command read mid-write is deleted unexecuted.
    jq -cn --arg id "$ID" '{id: $id, args: $ARGS.positional}' --args -- "$@" > "$CMD.part"
    mv "$CMD.part" "$CMD"
    # Gestures take real wall-clock time (a slow drag can run several seconds,
    # activation on a first gesture longer still).
    TIMEOUT="${VIBE_DEBUG_TIMEOUT:-30}"
    DEADLINE=$(( $(date +%s) + TIMEOUT ))
    while [ ! -f "$RESPONSE" ]; do
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
            rm -f "$CMD"
            echo '{"error": "no response — is the driver running? (drive-ios.sh status)"}'
            exit 1
        fi
        sleep 0.05
    done
    OUT="$(cat "$RESPONSE")"
    rm -f "$RESPONSE"
    printf '%s\n' "$OUT"
    printf '%s' "$OUT" | jq -e 'has("error") | not' >/dev/null 2>&1 || exit 2
    ;;
esac
