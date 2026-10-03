#!/bin/bash
# Touch the iOS app on this session's simulator through the resident
# VibeiOSDriver XCUITest (Tests/iOSDriver), the only sanctioned touch synthesis
# on iOS. Coordinates are app-window POINTS, top-left origin: screenshot pixels
# divided by the scale dump_screenshot reports.
#
# Usage:
#   drive-ios.sh start          # build app and driver, start the driver,
#                               #   install the built app, wait until ready
#   drive-ios.sh stop           # end the session
#   drive-ios.sh status         # {"ready", "appStale"}; appStale true means the
#                               #   device runs a different build than the one
#                               #   on disk — rerun launch-ios.sh
#   drive-ios.sh tap 201 640
#   drive-ios.sh double_tap 201 640
#   drive-ios.sh press 201 640 1.5
#   drive-ios.sh drag 300 640 100 640 1.0    # x1 y1 x2 y2 [seconds]; seconds
#                               #   for a 1:1 scrub, omit for a flick
#   drive-ios.sh pinch 2.0 1.0  # scale velocity, on the waveform (expand the
#                               #   card first). scale > 1 zooms in; velocity
#                               #   must be negative to zoom out. Read
#                               #   dump_state ui.waveformZoomRequested/Effective
#   drive-ios.sh type "key"     # into the focused field; the keyboard is its own
#                               #   window, so a tap on a key hits the app behind
#   drive-ios.sh rotate left    # portrait|left|right
#   drive-ios.sh home
#   drive-ios.sh attach         # re-attach after the app was relaunched
#                               #   outside the driver; launch-ios.sh sends it
#   drive-ios.sh springboard tap 201 640  # Home-screen widgets and gallery
#   drive-ios.sh springboard tree         # accessibility hierarchy
#   drive-ios.sh springboard tap_label "Add Widget"
#
# A reply means the gesture was performed, not that it landed: verify with
# dump_state or a screenshot. Exit: 0 ok, 1 no response, 2 command error,
# 64 usage.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: drive-ios.sh start|stop|status|<gesture> [args ...]" >&2; exit 64; }

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
READY_NAME="vibe-driver-ready"

# start creates and boots this session's device; every other verb needs it.
if [ "$1" = "start" ]; then
    UDID="$("$DIR/sim-udid.sh" --create)"
    xcrun simctl bootstatus "$UDID" -b >/dev/null
else
    UDID="$("$DIR/sim-udid.sh" 2>/dev/null)" \
        || { echo '{"error": "no simulator for this session — drive-ios.sh start first"}'; exit 1; }
fi

# A host directory, not the app container: every `simctl install` rotates the
# data-container UUID, and a driver holding the old path would silently stop
# seeing commands. The unsandboxed runner reads host paths directly.
TMP="$ROOT/build/ios-driver/$UDID"
LOG="$TMP/driver.log"

. "$ROOT/scripts/build-lock.sh"

# Ready means the marker AND both processes: xcodebuild owns the automation
# session, the runner performs the gestures. The marker outlives a crash, kill
# or `simctl erase`, and a runner without its xcodebuild answers nothing, so a
# marker-only check burns the full 90s timeout per gesture. Both patterns are
# scoped to this device.
driver_alive() {
    pgrep -f "VibeiOSDriver -destination id=$UDID" >/dev/null 2>&1 \
        && pgrep -f "Devices/$UDID/.*VibeiOSDriver-Runner" >/dev/null 2>&1
}

# stop is the quit verb by another name; macOS bash has no ;;& fallthrough.
[ "$1" = "stop" ] && set -- quit

case "$1" in
start)
    # Only this device's driver: other sessions' simulators are untouched.
    pkill -f "VibeiOSDriver -destination id=$UDID" 2>/dev/null || true
    pkill -f "Devices/$UDID/.*VibeiOSDriver-Runner" 2>/dev/null || true
    mkdir -p "$TMP"
    rm -f "$TMP/$READY_NAME" "$TMP"/vibe-touch-*
    # TRAP: without -collect-test-diagnostics never, xcodebuild's teardown
    # after `stop` can run `simctl diagnose` for minutes, and this script,
    # which holds the caller's pipe until xcodebuild is gone, hangs with it.
    # The build tree is shared by the checkout's sessions: hold the lock across
    # the generate, the build and the install (released when this script
    # exits), or xcodegen rewrites Vibe.xcodeproj under another session's
    # xcodebuild and two builds clobber one products directory.
    vibe_build_lock_acquire
    ( cd "$ROOT" && xcodegen generate >/dev/null )
    SIGNING=(CODE_SIGNING_ALLOWED=NO)
    [ "${VIBE_SIGN_SIM:-}" != 1 ] || SIGNING=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- GENERATE_INFOPLIST_FILE=YES)
    ( cd "$ROOT" && TEST_RUNNER_VIBE_DRIVER_DIR="$TMP" \
        nohup xcodebuild test -project Vibe.xcodeproj -scheme VibeiOSDriver \
            -destination "id=$UDID" -derivedDataPath build/DerivedData \
            -collect-test-diagnostics never \
            "${SIGNING[@]}" > "$LOG" 2>&1 & echo $! > "$TMP/xcodebuild.pid" )
    BUILD_PID="$(cat "$TMP/xcodebuild.pid")"
    for _ in $(seq 1 240); do
        if [ -f "$TMP/$READY_NAME" ]; then
            # TRAP: `xcodebuild test` builds the app without installing it, so
            # the driver would silently drive whatever the device already held.
            # Install after the build, never before; a no-op when the bundles
            # match.
            "$DIR/install-ios.sh" "$UDID"
            echo '{"ok": true, "ready": true}'
            exit 0
        fi
        # A failed build exits in seconds without the marker; don't wait out
        # the four minutes.
        if ! kill -0 "$BUILD_PID" 2>/dev/null; then
            echo "{\"error\": \"xcodebuild exited before the driver was ready — see $LOG\"}"
            exit 1
        fi
        sleep 1
    done
    echo "{\"error\": \"driver never became ready — see $LOG\"}"
    exit 1
    ;;
status)
    if [ -f "$TMP/$READY_NAME" ] && driver_alive; then
        # A driver outlives rebuilds, and a gesture against the old binary
        # looks exactly like one against the new. Checked here, not per
        # gesture, to keep the bundle hash off every tap.
        if "$DIR/install-ios.sh" "$UDID" --check 2>/dev/null; then
            echo '{"ready": true, "appStale": false}'
        else
            echo '{"ready": true, "appStale": true}'
        fi
    else
        rm -f "$TMP/$READY_NAME"
        echo '{"ready": false}'
        exit 1
    fi
    ;;
*)
    if [ ! -f "$TMP/$READY_NAME" ] || ! driver_alive; then
        rm -f "$TMP/$READY_NAME"
        echo '{"error": "driver not running — drive-ios.sh start first"}'
        exit 1
    fi
    ID="$(uuidgen)"
    CMD="$TMP/vibe-touch-$ID.json"
    RESPONSE="$TMP/vibe-touch-response-$ID.txt"
    # Rename into place: a command read mid-write is deleted unexecuted.
    jq -cn --arg id "$ID" '{id: $id, args: $ARGS.positional}' --args -- "$@" > "$CMD.part"
    mv "$CMD.part" "$CMD"
    # A slow drag takes seconds, a self-heal a full launch, and a gesture
    # against an app relaunched without `attach` a minute (the driver's TRAP).
    TIMEOUT="${VIBE_DEBUG_TIMEOUT:-90}"
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
