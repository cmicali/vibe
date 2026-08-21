#!/bin/bash
# Launch one verified instance of a chosen build, cold its caches, and hand it
# to torture.py. Use this rather than launch.sh whenever WHICH build runs has
# to be certain — a fix-vs-pre-fix comparison, most of all.
#
# TRAP: `open -a <path>` resolves by BUNDLE ID, not path. Two builds of Vibe
# share com.commonwealthrecordings.Vibe, so open -a launches whichever copy
# LaunchServices has registered and silently ignores the path you gave it. A
# comparison run that way tests one binary twice. Hence the direct exec below,
# and the verification after it.
#
# Direct exec cannot read argv paths under the sandbox, so the playlist folder
# must already be granted — launch it once through vibe-debug's launch.sh with
# that folder first, which is what creates the grant.
set -u

usage() {
    echo "usage: $(basename "$0") <Vibe.app> <playlist-folder> [torture.py args...]" >&2
    echo "  e.g. $(basename "$0") build/DerivedData/Build/Products/Debug/Vibe.app ~/Music/big --rounds 40" >&2
    exit 64
}
[ $# -ge 2 ] || usage
[ -d "$1" ] || { echo "no app bundle at $1" >&2; exit 64; }
[ -d "$2" ] || { echo "no playlist folder at $2" >&2; exit 64; }

# Both absolutized: the app resolves an open against ITS cwd (/ for a GUI
# process), so a relative playlist path opened nothing and failed the run as
# "playlist never populated".
APP="$(cd "$1" && pwd)"; PLAYLIST="$(cd "$2" && pwd)"; shift 2
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "no executable at $V" >&2; exit 64; }

# The iOS Simulator's Vibe is also named Vibe and also matches pgrep -x, so
# every instance check has to exclude it or it reads as a second mac instance.
mac_instances() {
    for p in $(pgrep -x Vibe); do
        exe=$(ps -o comm= -p "$p" 2>/dev/null) || continue
        case "$exe" in *CoreSimulator*) continue;; esac
        ps -o command= -p "$p" 2>/dev/null | grep -q -- --debug-cmd || echo "$p"
    done
}

# One instance, strictly. A second one answers the channel too, and then every
# result belongs to a build and a grant set you did not choose.
#
# TRAP: this kills any Vibe you are running from Xcode. Ask before running it
# on a machine someone is working on. `quit` first — it is the normal terminate
# path, and it is what lets an attached debugger let go; SIGKILL is the last
# resort and leaves a stale command file in the container tmp.
if [ -n "$(mac_instances)" ]; then
    "$V" --debug-cmd quit >/dev/null 2>&1
    sleep 2
fi
for _ in 1 2 3; do
    [ -z "$(mac_instances)" ] && break
    pkill -x Vibe 2>/dev/null
    sleep 2
done
[ -z "$(mac_instances)" ] || { echo "ABORT: could not clear existing Vibe processes: $(mac_instances | tr '\n' ' ')" >&2; exit 2; }

# Off the hardware by default, and honouring VIBE_AUDIBLE the same way
# vibe-debug's launch.sh does — this script cannot use launch.sh (it must
# direct-exec to be sure WHICH build came up), so the flag rules have to be
# repeated here rather than inherited. Unset: manual rendering, no output
# device ever opened. `silent`: the real device with the mixer zeroed, which is
# the only way to reach the HAL device layer, engine config-change
# notifications and the Now Playing publish. `1`: audible.
case "${VIBE_AUDIBLE:-}" in
    "")     AUDIO_FLAGS=(--no-audio-hw --silent) ;;
    silent) AUDIO_FLAGS=(--silent) ;;
    *)      AUDIO_FLAGS=() ;;
esac
echo "  audio: ${AUDIO_FLAGS[*]:-real hardware, audible}"
# macOS ships bash 3.2, where `set -u` treats an EMPTY array expansion as an
# unbound variable — so the audible case (no flags at all) aborts the script
# unless the expansion is guarded.
"$V" ${AUDIO_FLAGS[@]+"${AUDIO_FLAGS[@]}"} &
ready=""
for _ in $(seq 1 25); do
    sleep 1
    "$V" --debug-cmd dump_health >/dev/null 2>&1 && { ready=1; break; }
done
# Falling through silently is what turns a dead channel into a baffling
# "playlist never populated" 25 lines later. Fail here instead.
[ -n "$ready" ] || { echo "ABORT: launched, but the debug channel never answered" >&2; exit 2; }

pids=$(mac_instances)
n=$(echo "$pids" | grep -c .)
[ "$n" -eq 1 ] || { echo "ABORT: expected exactly 1 GUI instance, found $n" >&2; exit 2; }
exe=$(ps -o comm= -p "$pids")
echo "launched pid $pids"
echo "  exe: $exe"
[ "$exe" = "$V" ] || { echo "ABORT: wrong binary running ($exe)" >&2; exit 2; }
echo "  verified: intended binary"

# Cold caches are load-bearing, not hygiene: the metadata-delivery races this
# suite hunts only open when a scan is still in flight as playback starts, and
# a warm cache closes that window before the first track ever plays.
"$V" --debug-cmd clear_caches >/dev/null 2>&1
echo "  caches cleared (cold metadata scan for every track)"

exec python3 "$(dirname "$0")/torture.py" --app "$APP" --playlist "$PLAYLIST" "$@"
