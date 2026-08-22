#!/bin/bash
# Drive touches on the iOS app in the booted simulator — the iOS counterpart
# of the mac channel's key/click injection, via the resident VibeiOSDriver
# XCUITest (the only sanctioned touch-synthesis path on iOS; see
# Tests/iOSDriver). Coordinates are app-window POINTS, top-left origin —
# simctl screenshot pixels divided by the screen scale (dump_screenshot
# reports it; 3 on modern iPhones).
#
# Usage:
#   drive-ios.sh start          # install the built app, launch the driver,
#                               #   wait until ready
#   drive-ios.sh stop           # end the session
#   drive-ios.sh status         # {"ready": …, "appStale": …} — appStale true
#                               #   means the simulator is running an OLDER
#                               #   build than the one on disk; relaunch
#   drive-ios.sh tap 201 640
#   drive-ios.sh double_tap 201 640
#   drive-ios.sh press 201 640 1.5
#   drive-ios.sh drag 300 640 100 640 1.0    # x1 y1 x2 y2 [seconds]; give
#                               # seconds for 1:1 scrubs, omit for a flick
#   drive-ios.sh pinch 2.0 1.0  # scale velocity, on the WAVEFORM (the only
#                               #   pinchable element). scale > 1 zooms in;
#                               #   velocity is scale-factors/sec and must be
#                               #   negative to zoom out. Expand the card first.
#                               #   Read the result with debug-ios.sh dump_state:
#                               #   ui.waveformZoomRequested / ...Effective
#   drive-ios.sh type "key"     # into whatever holds focus. Use this for the
#                               #   keyboard: it is in a window of its own, so a
#                               #   tap aimed at a key hits the app BEHIND it
#   drive-ios.sh rotate left    # device orientation: portrait|left|right
#   drive-ios.sh home
#
# Verify every gesture's effect with debug-ios.sh dump_state or a screenshot —
# the reply only means the gesture was performed, not that it landed where
# intended. Exit codes: 0 ok, 1 no response, 2 command error, 64 usage.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: drive-ios.sh start|stop|status|<gesture> [args ...]" >&2; exit 64; }

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
READY_NAME="vibe-driver-ready"

# This checkout's dedicated device (sim-udid.sh): start creates and boots it,
# every other verb requires it to already exist.
if [ "$1" = "start" ]; then
    UDID="$("$DIR/sim-udid.sh" --create)"
    xcrun simctl bootstatus "$UDID" -b >/dev/null
else
    UDID="$("$DIR/sim-udid.sh" 2>/dev/null)" \
        || { echo '{"error": "no simulator for this checkout — drive-ios.sh start first"}'; exit 1; }
fi

# A stable HOST directory, not the app container: the runner is unsandboxed on
# the simulator and reads host paths directly, and every `simctl install`
# rotates the app's data-container UUID — a driver holding the old path would
# silently stop seeing commands the moment launch-ios.sh reinstalls the app.
# Per-device, so concurrent sessions on other simulators have their own.
TMP="$ROOT/build/ios-driver/$UDID"
LOG="$TMP/driver.log"

. "$ROOT/scripts/build-lock.sh"

# Ready means the marker AND BOTH halves of the session. xcodebuild owns the
# automation session; the runner it launched performs the gestures. The marker
# alone lies after either dies without cleanup — a crash, a kill, a
# `simctl erase` — and a runner outliving its xcodebuild answers nothing, so a
# gesture sent to it burned the full 90s timeout instead of failing in
# milliseconds. Both patterns are scoped to this device, so a session driving
# another simulator is never mistaken for this one.
driver_alive() {
    pgrep -f "VibeiOSDriver -destination id=$UDID" >/dev/null 2>&1 \
        && pgrep -f "Devices/$UDID/.*VibeiOSDriver-Runner" >/dev/null 2>&1
}

# stop is the quit verb by another name; macOS bash has no ;;& fallthrough.
[ "$1" = "stop" ] && set -- quit

case "$1" in
start)
    # One driver per DEVICE: kill only this device's xcodebuild and runner, so
    # sessions driving other simulators are untouched.
    pkill -f "VibeiOSDriver -destination id=$UDID" 2>/dev/null || true
    pkill -f "Devices/$UDID/.*VibeiOSDriver-Runner" 2>/dev/null || true
    mkdir -p "$TMP"
    rm -f "$TMP/$READY_NAME" "$TMP"/vibe-touch-*
    # The device is this session's; the build tree is the whole checkout's.
    # Held across the generate, the build and the install that follows, then
    # dropped as soon as the runner is up — the rest of the session (gestures,
    # screenshots, the debug channel) stays concurrent with other sessions,
    # which is the point of the per-session device. Without it, xcodegen
    # rewrote Vibe.xcodeproj under another session's live xcodebuild and the two
    # builds clobbered one products directory.
    vibe_build_lock_acquire
    ( cd "$ROOT" && xcodegen generate >/dev/null )
    ( cd "$ROOT" && TEST_RUNNER_VIBE_DRIVER_DIR="$TMP" \
        nohup xcodebuild test -project Vibe.xcodeproj -scheme VibeiOSDriver \
            -destination "id=$UDID" -derivedDataPath build/DerivedData \
            CODE_SIGNING_ALLOWED=NO > "$LOG" 2>&1 & echo $! > "$TMP/xcodebuild.pid" )
    BUILD_PID="$(cat "$TMP/xcodebuild.pid")"
    # Build + runner spin-up; the marker is the readiness signal.
    for _ in $(seq 1 240); do
        if [ -f "$TMP/$READY_NAME" ]; then
            # AFTER the build finishes, never before. TRAP: `xcodebuild test`
            # leaves the app-under-test it built on disk WITHOUT installing it.
            # Left to xcodebuild, the driver attaches to whatever the device
            # already held and every gesture from then on exercises code that
            # is not checked out, silently, because a stale app launches and
            # answers exactly like a fresh one. This is the install that makes
            # the driver drive the checkout; it is a no-op when the bundles
            # already match, and the next gesture pays the driver's own
            # relaunch to re-attach.
            "$DIR/install-ios.sh" "$UDID"
            echo '{"ok": true, "ready": true}'
            exit 0
        fi
        # A build that fails — a compile error, a destination xcodebuild cannot
        # resolve — exits in seconds and never writes the marker. Without this
        # the caller waits out the whole four minutes for a verdict already in
        # the log.
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
    # The marker alone lies after a driver dies without cleanup (crash, kill,
    # simctl erase): ready means marker AND runner process. A stale marker is
    # cleaned so launch-ios.sh's install-skip stops believing it too.
    if [ -f "$TMP/$READY_NAME" ] && driver_alive; then
        # appStale is the belt to install-ios.sh's braces: a driver can outlive
        # a rebuild, and a gesture against the old binary looks exactly like a
        # gesture against the new one. Reported here rather than checked per
        # gesture, which would pay a container lookup on every tap.
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
        rm -f "$TMP/$READY_NAME"   # same stale-marker cleanup as status
        echo '{"error": "driver not running — drive-ios.sh start first"}'
        exit 1
    fi
    ID="$(uuidgen)"
    CMD="$TMP/vibe-touch-$ID.json"
    RESPONSE="$TMP/vibe-touch-response-$ID.txt"
    # Atomic rename, as in debug-ios.sh: the driver polls the directory and a
    # command read mid-write is deleted unexecuted.
    jq -cn --arg id "$ID" '{id: $id, args: $ARGS.positional}' --args -- "$@" > "$CMD.part"
    mv "$CMD.part" "$CMD"
    # Gestures take real wall-clock time: a slow drag runs several seconds,
    # the first gesture after a start or app relaunch pays the accessibility
    # attach (up to ~60s), and a self-heal relaunch pays a full app launch.
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
