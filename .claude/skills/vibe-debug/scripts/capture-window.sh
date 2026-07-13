#!/bin/bash
# Real screen capture of the on-screen Vibe window — composited pixels,
# including NSVisualEffectView materials/vibrancy that the in-process snapshot
# helper cannot render. Requires Screen Recording permission for the terminal.
#
# Usage: capture-window.sh <output.png> [pid]
# Pass the pid when more than one Vibe instance is running.
set -euo pipefail

OUT="${1:-}"
PID="${2:-}"
[ -n "$OUT" ] || { echo "usage: $0 <output.png> [pid]" >&2; exit 64; }

DIR="$(cd "$(dirname "$0")" && pwd)"

# More than one instance and no pid given: ambiguous — show what's running.
if [ -z "$PID" ] && [ "$(pgrep -x Vibe | wc -l)" -gt 1 ]; then
    echo "warning: multiple Vibe instances running; pass a pid to disambiguate:" >&2
    ps -o pid=,command= -p "$(pgrep -x Vibe | tr '\n' ',' | sed 's/,$//')" >&2
fi

LINE="$(swift "$DIR/find-window.swift" ${PID:+"$PID"} | head -1)" || {
    echo "no on-screen Vibe window found${PID:+ for pid $PID}" >&2; exit 1;
}
WID="$(echo "$LINE" | awk '{print $1}')"
screencapture -x -l"$WID" "$OUT"
echo "captured window $WID -> $OUT"
