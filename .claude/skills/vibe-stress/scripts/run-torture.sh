#!/bin/bash
# Launch one verified instance of a chosen build, cold its caches, and hand it
# to torture.py. Use this rather than launch.sh whenever WHICH build runs must
# be certain, as in a fix-vs-pre-fix comparison.
#
# TRAP: `open -a <path>` resolves by BUNDLE ID, not path, so with two builds it
# launches whichever LaunchServices registered and a comparison tests one
# binary twice. Hence the direct exec and the verification after it.
#
# Direct exec cannot read argv paths under the sandbox: grant the playlist
# folder first by launching it once through vibe-debug's launch.sh.
set -u

usage() {
    echo "usage: $(basename "$0") <Vibe.app> <playlist-folder> [torture.py args...]" >&2
    echo "  e.g. $(basename "$0") \"\$(scripts/vibe-env.sh --print VIBE_APP)\" ~/Music/big --rounds 40" >&2
    exit 64
}
[ $# -ge 2 ] || usage
[ -d "$1" ] || { echo "no app bundle at $1" >&2; exit 64; }
[ -d "$2" ] || { echo "no playlist folder at $2" >&2; exit 64; }

# Absolute: the app resolves an open against its own cwd (/). Its own ids, from
# its Info.plist (scripts/vibe-env.sh).
export VIBE_APP="$(cd "$1" && pwd)"; PLAYLIST="$(cd "$2" && pwd)"; shift 2
. "$(dirname "$0")/../../../../scripts/vibe-env.sh" || exit 64
[ -x "$VIBE_BIN" ] || { echo "no executable at $VIBE_BIN" >&2; exit 64; }

# One instance in this bundle id's container, strictly: a second one answers
# the channel too. One of this build is quit through the channel, which lets a
# debugger let go, and vibe_kill_own never signals a debugged one. One from
# another path is not ours, so the run aborts and nothing is killed.
for p in $(vibe_own_pids); do
    [ "$(ps -o comm= -p "$p" 2>/dev/null)" = "$VIBE_BIN" ] && continue
    echo "ABORT: another build of $VIBE_BUNDLE_ID is running; quit it first: $(ps -o command= -p "$p")" >&2
    exit 2
done
if [ -n "$(vibe_own_pids)" ]; then
    "$VIBE_BIN" --debug-cmd quit >/dev/null 2>&1
    vibe_kill_own 2 || { echo "ABORT: could not clear existing $VIBE_PRODUCT processes" >&2; exit 2; }
fi

# VIBE_AUDIBLE and VIBE_NOW_PLAYING as in vibe-debug's launch.sh, repeated
# because this must direct-exec. Unset: no output device. `silent`: the real
# device with zeroed output, the only way to reach the HAL device layer. `1`:
# audible.
case "${VIBE_AUDIBLE:-}" in
    "")     AUDIO_FLAGS=(--no-audio-hw --silent) ;;
    silent) AUDIO_FLAGS=(--silent) ;;
    *)      AUDIO_FLAGS=() ;;
esac
[ "${VIBE_NOW_PLAYING:-0}" != "1" ] && AUDIO_FLAGS+=(--no-now-playing)
echo "  audio: ${AUDIO_FLAGS[*]:-real hardware, audible}"
# TRAP: the app outlives this script and torture.py, so it must hold none of
# the caller's stdin, stdout or stderr, or `make torture | tail` never returns.
# Its output, a sanitizer report included, goes to APP_LOG.
APP_LOG="$(cd "$(dirname "$0")/../../../.." && pwd)/build/stress/torture-app.log"
mkdir -p "$(dirname "$APP_LOG")"
echo "  app output: $APP_LOG"
# bash 3.2 + set -u dies on an empty array expansion (audible with Now Playing).
"$VIBE_BIN" ${AUDIO_FLAGS[@]+"${AUDIO_FLAGS[@]}"} > "$APP_LOG" 2>&1 < /dev/null &
ready=""
for _ in $(seq 1 25); do
    sleep 1
    "$VIBE_BIN" --debug-cmd dump_health >/dev/null 2>&1 && { ready=1; break; }
done
# Otherwise a dead channel surfaces later as "playlist never populated".
[ -n "$ready" ] || { echo "ABORT: launched, but the debug channel never answered" >&2; exit 2; }

pids=$(vibe_own_pids)
n=$(echo "$pids" | grep -c .)
[ "$n" -eq 1 ] || { echo "ABORT: expected exactly 1 GUI instance, found $n" >&2; exit 2; }
exe=$(ps -o comm= -p "$pids")
echo "launched pid $pids"
echo "  exe: $exe"
[ "$exe" = "$VIBE_BIN" ] || { echo "ABORT: wrong binary running ($exe)" >&2; exit 2; }
echo "  verified: intended binary"

# As in launch.sh: an occluded window shows nothing to a real capture and keeps
# the equalizer bars off (raise_window's TRAP in DebugWindowVerbs.m).
raised=$("$VIBE_BIN" --debug-cmd raise_window 2>/dev/null)
if printf '%s' "$raised" | jq -e '.visible' >/dev/null 2>&1; then
    echo "  window: raised, visible"
elif printf '%s' "$raised" | jq -e '.displayAsleep' >/dev/null 2>&1; then
    echo "  WARNING: the display is asleep or the screen locked; the window stays occluded and the equalizer bars stay off" >&2
else
    echo "  WARNING: the window is still occluded after raise_window" >&2
fi

# Load-bearing: the delivery races this hunts need a scan still in flight as
# playback starts, which a warm cache never has.
"$VIBE_BIN" --debug-cmd clear_caches >/dev/null 2>&1
echo "  caches cleared (cold metadata scan for every track)"

exec python3 "$(dirname "$0")/torture.py" --app "$VIBE_APP" --playlist "$PLAYLIST" "$@"
