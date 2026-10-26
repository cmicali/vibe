#!/bin/bash
# Screen-capture the on-screen Vibe window: composited pixels, including the
# materials, vibrancy and glass dump_screenshot cannot render. Needs Screen
# Recording permission for the terminal.
#
# Usage: capture-window.sh <output.png> [pid]
#   Without a pid, this shell's slot's instance (scripts/vibe-env.sh). Every
#   slot's window is owned by "Vibe", so a window is found by its pid.
set -euo pipefail

OUT="${1:-}"
PID="${2:-}"
[ -n "$OUT" ] || { echo "usage: $0 <output.png> [pid]" >&2; exit 64; }

DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../../../../scripts/vibe-env.sh"

if [ -z "$PID" ]; then
    PID="$(vibe_own_pids | head -1)"
    [ -n "$PID" ] || { echo "no $VIBE_PRODUCT running; launch it, or pass a pid" >&2; exit 1; }
    if [ "$(vibe_own_pids | wc -l)" -gt 1 ]; then
        echo "warning: several $VIBE_PRODUCT instances running; pass a pid to disambiguate:" >&2
        ps -o pid=,command= -p "$(vibe_own_pids | paste -sd , -)" >&2
    fi
fi

LINE="$(swift "$DIR/find-window.swift" "$PID" | head -1)" || {
    echo "no on-screen window for pid $PID" >&2; exit 1;
}
WID="$(echo "$LINE" | awk '{print $1}')"
screencapture -x -l"$WID" "$OUT"
echo "captured window $WID -> $OUT"
