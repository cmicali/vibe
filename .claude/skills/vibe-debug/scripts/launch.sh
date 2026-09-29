#!/bin/bash
# Relaunch the debug build (quitting any running Vibe) with optional audio
# files, wait until the debug channel answers, and print its dump_state JSON.
#
# Usage: launch.sh [audio-file ...]
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
# Audio: --no-audio-hw --silent by default, so no output device opens and
# AirPods auto-switching cannot trigger. VIBE_AUDIBLE=1 plays on real hardware;
# VIBE_AUDIBLE=silent drives real hardware with the output zeroed (--silent).
# Now Playing: suppressed (--no-now-playing) unless VIBE_NOW_PLAYING=1, since
# registering as the active media app takes the AirPods; --no-audio-hw also
# suppresses it, so testing it needs VIBE_AUDIBLE=1 or =silent too.
# VIBE_LANGUAGE=de (a catalog code) launches in that language for this run only.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "no app at $APP — build first, or set VIBE_APP" >&2; exit 1; }

# Quit through the channel first, and never signal an instance under a
# debugger: the debugger traps SIGTERM and STOPS the process, which then keeps
# its pid, answers nothing, and makes every later --debug-cmd burn its timeout.
# TRAP: the iOS Simulator's app is also named Vibe and may be another session's.
# The quit never reaches it, so matching it here would kill it; skip CoreSimulator.
vibe_pids() {
    local p
    for p in $(pgrep -x Vibe 2>/dev/null); do
        case "$(ps -o command= -p "$p" 2>/dev/null)" in *CoreSimulator*) ;; *) echo "$p" ;; esac
    done
}

# ps prints p_flag in hex; P_TRACED is 0x800 (sys/proc.h).
vibe_traced() {
    local flags
    flags="$(ps -o flags= -p "$1" 2>/dev/null | tr -d ' ')"
    [ -n "$flags" ] && [ "$(( 0x$flags & 0x800 ))" -ne 0 ]
}

# Stopped: it cannot service the channel, so waiting will never quit it.
vibe_stopped() {
    case "$(ps -o stat= -p "$1" 2>/dev/null)" in T*) return 0 ;; *) return 1 ;; esac
}

vibe_wait_gone() {
    local i=0
    while [ "$i" -lt "$(( $1 * 10 ))" ]; do
        [ -z "$(vibe_pids)" ] && return 0
        sleep 0.1
        i=$(( i + 1 ))
    done
    [ -z "$(vibe_pids)" ]
}

vibe_xcode_bail() {
    echo "vibe: pid $1 is running under a debugger — $2" >&2
    echo "      Stop the run in Xcode (⌘.), then re-run this script." >&2
    exit 1
}

if [ -n "$(vibe_pids)" ]; then
    for PID in $(vibe_pids); do
        if vibe_stopped "$PID"; then
            vibe_traced "$PID" && vibe_xcode_bail "$PID" "suspended, so it cannot answer the debug channel."
            # Suspended by something other than a debugger: continue it, since
            # neither the channel nor a SIGTERM reaches a stopped process.
            kill -CONT "$PID" 2>/dev/null || true
        fi
    done
    "$V" --debug-cmd quit >/dev/null 2>&1 || true
    if ! vibe_wait_gone 5; then
        for PID in $(vibe_pids); do
            # SIGTERM would only stop it under the debugger.
            vibe_traced "$PID" && vibe_xcode_bail "$PID" "and it did not answer the quit command."
        done
        kill $(vibe_pids) 2>/dev/null || true
        if ! vibe_wait_gone 3; then
            kill -9 $(vibe_pids) 2>/dev/null || true
            vibe_wait_gone 3 || { echo "vibe: Vibe survived SIGKILL: $(vibe_pids | tr '\n' ' ')" >&2; exit 1; }
        fi
    fi
fi

# A command posted before the channel installs is swept, so retry (each call
# waits up to 5s). Re-open when no process is up: right after a rebuild the
# first open can silently do nothing while Launch Services re-registers.
for _ in 1 2 3 4 5 6; do
    if [ -z "$(vibe_pids)" ]; then
        # --args last: everything after it is argv. -AppleLanguages takes one
        # element shaped like a plist array, (de). bash 3.2 with set -u dies on
        # an empty "${ARGS[@]}", hence the ${ARGS[@]+...} idiom.
        ARGS=()
        [ "${VIBE_NOW_PLAYING:-0}" != "1" ] && ARGS+=(--no-now-playing)
        [ -n "${VIBE_LANGUAGE:-}" ] && ARGS+=(-AppleLanguages "(${VIBE_LANGUAGE})")
        case "${VIBE_AUDIBLE:-}" in
            "")     ARGS+=(--no-audio-hw --silent) ;;
            silent) ARGS+=(--silent) ;;
        esac
        # TRAP: under set -e a failing open would end the script, so a
        # transient Launch Services refusal right after a quit leaves no app.
        # Keep the error and let the loop retry.
        if [ "${#ARGS[@]}" -gt 0 ]; then
            OPEN_ERR="$(open -a "$APP" "$@" --args ${ARGS[@]+"${ARGS[@]}"} 2>&1)" || OPEN_ERR="open -a failed ($?): $OPEN_ERR"
        else
            OPEN_ERR="$(open -a "$APP" "$@" 2>&1)" || OPEN_ERR="open -a failed ($?): $OPEN_ERR"
        fi
        sleep 2
    fi
    if "$V" --debug-cmd dump_state 2>/dev/null; then
        # Launch Services may have routed open -a to an Xcode-run instance of
        # another build.
        RUNNING="$(ps -o command= -p "$(vibe_pids | head -1)" 2>/dev/null || true)"
        case "$RUNNING" in
            "$V"*) ;;
            *) echo "warning: running binary is: $RUNNING" >&2 ;;
        esac
        # The launch lands behind the frontmost app, and an occluded, paused
        # app is deferred by the OS until the channel times out (raise_window's
        # TRAP). A sleeping display or locked screen occludes every window.
        RAISED="$("$V" --debug-cmd raise_window 2>/dev/null || true)"
        if ! printf '%s' "$RAISED" | jq -e '.visible' >/dev/null 2>&1; then
            if printf '%s' "$RAISED" | jq -e '.displayAsleep' >/dev/null 2>&1; then
                echo "warning: the display is asleep or the screen locked, so the window stays occluded and a paused Vibe will be deferred; wake and unlock the Mac" >&2
            else
                echo "warning: the window is still occluded after raise_window" >&2
            fi
        fi
        exit 0
    fi
done
if [ -n "$(vibe_pids)" ]; then
    echo "vibe: app never answered on the debug channel" >&2
else
    echo "vibe: no app process ever started; last open: ${OPEN_ERR:-no error}" >&2
fi
exit 1
