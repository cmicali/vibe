#!/bin/bash
# Relaunch the debug build (quitting any running Vibe) with optional audio
# files, then wait until the app answers on the debug command channel and
# print its `state` JSON. Replaces the open-then-guess-a-sleep dance.
#
# Usage: launch.sh [audio-file ...]
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
# Audio is OFF-HARDWARE by default (launches with --no-audio-hw --silent), so
# no output device is opened and macOS's automatic AirPods switching can't
# trigger; set VIBE_AUDIBLE=1 to use real hardware and hear playback, or
# VIBE_AUDIBLE=silent for real hardware with the mixer muted (--silent only).
# --no-audio-hw also suppresses the system Now Playing publish, because
# registering as the active media app takes the AirPods on its own. Testing
# the Now Playing integration therefore needs VIBE_AUDIBLE=1 or =silent.
# Set VIBE_LANGUAGE=de (a catalog code) to launch
# the app in that language via -AppleLanguages — per-launch only, no prefs
# reset needed.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "no app at $APP — build first, or set VIBE_APP" >&2; exit 1; }

# Ending whatever is already running. A signal is the wrong tool when Xcode is
# debugging the app: the debugger traps SIGTERM and stops the process instead
# of ending it, so the pkill this used to be left it in the process table,
# answering nothing, and every later --debug-cmd burned its full timeout. Ask
# through the channel first — no signal, so a debugged instance quits cleanly
# and Xcode ends the session — and never signal one that is being debugged.
vibe_pids() { pgrep -x Vibe 2>/dev/null || true; }

# ps prints p_flag in hex; P_TRACED is 0x800 (sys/proc.h).
vibe_traced() {
    local flags
    flags="$(ps -o flags= -p "$1" 2>/dev/null | tr -d ' ')"
    [ -n "$flags" ] && [ "$(( 0x$flags & 0x800 ))" -ne 0 ]
}

# A debugger holding the process at a stop. It cannot service the channel, so
# no amount of waiting will get it to quit.
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
            # SIGTERM here would only stop it under the debugger, which is the
            # hang this whole dance exists to avoid.
            vibe_traced "$PID" && vibe_xcode_bail "$PID" "and it did not answer the quit command."
        done
        pkill -x Vibe 2>/dev/null || true
        if ! vibe_wait_gone 3; then
            pkill -9 -x Vibe 2>/dev/null || true
            vibe_wait_gone 3 || { echo "vibe: Vibe survived SIGKILL: $(vibe_pids | tr '\n' ' ')" >&2; exit 1; }
        fi
    fi
fi

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
        case "${VIBE_AUDIBLE:-}" in
            "")     ARGS+=(--no-audio-hw --silent) ;;
            silent) ARGS+=(--silent) ;;
        esac
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
