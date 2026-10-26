#!/bin/bash
# Relaunch this slot's debug build with optional audio files, wait until the
# debug channel answers, and print its dump_state JSON.
#
# Usage: launch.sh [audio-file ...]
# App: this shell's slot (scripts/vibe-env.sh), or $VIBE_APP if set.
# It quits only its own instances, through the channel. Another slot's
# instance and a stock one get a note on stderr and are never touched. An
# impostor is our executable from another path. It shares our container and
# channel, so the launch fails and nothing is killed.
# Audio: --no-audio-hw --silent by default, so no output device opens and
# AirPods auto-switching cannot trigger. VIBE_AUDIBLE=1 plays on real hardware;
# VIBE_AUDIBLE=silent drives real hardware with the output zeroed (--silent).
# Now Playing: suppressed (--no-now-playing) unless VIBE_NOW_PLAYING=1, since
# registering as the active media app takes the AirPods; --no-audio-hw also
# suppresses it, so testing it needs VIBE_AUDIBLE=1 or =silent too.
# VIBE_LANGUAGE=de (a catalog code) launches in that language for this run only.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../../../../scripts/vibe-env.sh"
[ -x "$VIBE_BIN" ] || { echo "no app at $VIBE_APP — build first, or set VIBE_APP" >&2; exit 1; }

impostor_pids() {
    local p
    for p in $(vibe_own_pids); do
        [ "$(ps -o comm= -p "$p" 2>/dev/null)" = "$VIBE_BIN" ] || echo "$p"
    done
}

impostor_report() {
    ps -o pid=,command= -p "$(impostor_pids | paste -sd , -)" >&2 || true
    echo "      Launch Services resolves open -a by bundle id, so it may launch another" >&2
    echo "      checkout's build of this slot. Quit that one, then re-register ours:" >&2
    echo "      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $VIBE_APP" >&2
}

if [ -n "$(impostor_pids)" ]; then
    echo "vibe: an instance in our container runs from another path. Nothing was killed." >&2
    impostor_report
    exit 1
fi

OWN=" $(vibe_own_pids | tr '\n' ' ') "
for PID in $(pgrep -x 'Vibe(-[A-Za-z0-9]+)?' 2>/dev/null); do
    case "$OWN" in *" $PID "*) continue ;; esac
    CMD="$(ps -o command= -p "$PID" 2>/dev/null)" || continue
    case "$CMD" in *CoreSimulator*|*--debug-cmd*) continue ;; esac
    echo "note: leaving another slot's or a stock instance alone: $PID $CMD" >&2
done

# The channel quit runs applicationWillTerminate:. vibe_kill_own backs it, and
# never signals an instance under a debugger.
if [ -n "$(vibe_own_pids)" ]; then
    "$VIBE_BIN" --debug-cmd quit >/dev/null 2>&1 || true
    vibe_kill_own 5 || exit 1
fi

# A command written once the process exists is answered when the channel
# installs. One written before is swept, so retry (each call waits up to 5s).
# Re-open when no process is up: right after a rebuild the first open can
# silently do nothing while Launch Services re-registers.
for _ in 1 2 3 4 5 6; do
    if [ -z "$(vibe_own_pids)" ]; then
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
            OPEN_ERR="$(open -a "$VIBE_APP" "$@" --args ${ARGS[@]+"${ARGS[@]}"} 2>&1)" || OPEN_ERR="open -a failed ($?): $OPEN_ERR"
        else
            OPEN_ERR="$(open -a "$VIBE_APP" "$@" 2>&1)" || OPEN_ERR="open -a failed ($?): $OPEN_ERR"
        fi
        sleep 2
    fi
    if STATE="$("$VIBE_BIN" --debug-cmd dump_state 2>/dev/null)"; then
        # Launch Services may have routed open -a to an Xcode-run instance or
        # another checkout's build. A slot's channel is its own, so there it
        # is an error.
        if [ -n "$(impostor_pids)" ]; then
            if [ -n "$VIBE_SLOT" ]; then
                echo "vibe: open -a launched this slot's executable from another path. Nothing was killed." >&2
                impostor_report
                exit 1
            fi
            echo "warning: running binary is: $(ps -o command= -p "$(impostor_pids | head -1)" 2>/dev/null || true)" >&2
        fi
        printf '%s\n' "$STATE"
        # The launch lands behind the frontmost app. An occluded window shows
        # nothing to a real capture and keeps the equalizer bars off
        # (raise_window's TRAP). A sleeping display or locked screen occludes
        # every window.
        RAISED="$("$VIBE_BIN" --debug-cmd raise_window 2>/dev/null || true)"
        if ! printf '%s' "$RAISED" | jq -e '.visible' >/dev/null 2>&1; then
            if printf '%s' "$RAISED" | jq -e '.displayAsleep' >/dev/null 2>&1; then
                echo "warning: the display is asleep or the screen locked, so the window stays occluded; wake and unlock the Mac for a real capture or the equalizer bars" >&2
            else
                echo "warning: the window is still occluded after raise_window" >&2
            fi
        fi
        exit 0
    fi
done
if [ -n "$(vibe_own_pids)" ]; then
    echo "vibe: app never answered on the debug channel" >&2
else
    echo "vibe: no app process ever started; last open: ${OPEN_ERR:-no error}" >&2
fi
exit 1
