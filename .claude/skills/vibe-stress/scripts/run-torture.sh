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
    echo "  e.g. $(basename "$0") build/DerivedData/Build/Products/Debug/Vibe.app ~/Music/big --rounds 40" >&2
    exit 64
}
[ $# -ge 2 ] || usage
[ -d "$1" ] || { echo "no app bundle at $1" >&2; exit 64; }
[ -d "$2" ] || { echo "no playlist folder at $2" >&2; exit 64; }

# Absolute: the app resolves an open against its own cwd (/).
APP="$(cd "$1" && pwd)"; PLAYLIST="$(cd "$2" && pwd)"; shift 2
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "no executable at $V" >&2; exit 64; }

# The iOS Simulator's Vibe also matches pgrep -x.
mac_instances() {
    for p in $(pgrep -x Vibe); do
        exe=$(ps -o comm= -p "$p" 2>/dev/null) || continue
        case "$exe" in *CoreSimulator*) continue;; esac
        ps -o command= -p "$p" 2>/dev/null | grep -q -- --debug-cmd || echo "$p"
    done
}

# One instance, strictly: a second one answers the channel too.
#
# TRAP: this quits any running Vibe, Xcode's included; ask first on a machine
# someone is using. `quit` through the channel lets a debugger let go; the
# SIGTERM fallback only stops a debugged process, and the run then aborts.
if [ -n "$(mac_instances)" ]; then
    "$V" --debug-cmd quit >/dev/null 2>&1
    sleep 2
fi
for _ in 1 2 3; do
    [ -z "$(mac_instances)" ] && break
    kill $(mac_instances) 2>/dev/null
    sleep 2
done
[ -z "$(mac_instances)" ] || { echo "ABORT: could not clear existing Vibe processes: $(mac_instances | tr '\n' ' ')" >&2; exit 2; }

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
# bash 3.2 + set -u dies on an empty array expansion (audible with Now Playing).
"$V" ${AUDIO_FLAGS[@]+"${AUDIO_FLAGS[@]}"} &
ready=""
for _ in $(seq 1 25); do
    sleep 1
    "$V" --debug-cmd dump_health >/dev/null 2>&1 && { ready=1; break; }
done
# Otherwise a dead channel surfaces later as "playlist never populated".
[ -n "$ready" ] || { echo "ABORT: launched, but the debug channel never answered" >&2; exit 2; }

pids=$(mac_instances)
n=$(echo "$pids" | grep -c .)
[ "$n" -eq 1 ] || { echo "ABORT: expected exactly 1 GUI instance, found $n" >&2; exit 2; }
exe=$(ps -o comm= -p "$pids")
echo "launched pid $pids"
echo "  exe: $exe"
[ "$exe" = "$V" ] || { echo "ABORT: wrong binary running ($exe)" >&2; exit 2; }
echo "  verified: intended binary"

# As in launch.sh: an occluded, paused app is deferred by the OS until the
# channel times out (raise_window's TRAP in DebugCommandTable.m).
raised=$("$V" --debug-cmd raise_window 2>/dev/null)
if printf '%s' "$raised" | jq -e '.visible' >/dev/null 2>&1; then
    echo "  window: raised, visible"
elif printf '%s' "$raised" | jq -e '.displayAsleep' >/dev/null 2>&1; then
    echo "  WARNING: the display is asleep or the screen locked; the window stays occluded and a paused Vibe will be deferred" >&2
else
    echo "  WARNING: the window is still occluded after raise_window" >&2
fi

# Load-bearing: the delivery races this hunts need a scan still in flight as
# playback starts, which a warm cache never has.
"$V" --debug-cmd clear_caches >/dev/null 2>&1
echo "  caches cleared (cold metadata scan for every track)"

exec python3 "$(dirname "$0")/torture.py" --app "$APP" --playlist "$PLAYLIST" "$@"
