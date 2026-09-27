#!/bin/bash
# Print the BPM analyzer's verdict for one audio file as JSON:
#   {"ok":true,"bpm":120.01,...}      (bpm 0 = no confident tempo)
# The debug client runs scan_bpm in its own process: a fresh analysis, no
# caches, no app needed, a running instance untouched. The file goes through
# stdin because the sandboxed client cannot read argv paths; it stages the
# bytes in its own container, so no shell touches ~/Library/Containers/.
#
# Usage: scan-bpm.sh <audio-file>     (app path: $VIBE_APP overrides)
set -euo pipefail
FILE="${1:?usage: scan-bpm.sh <audio-file>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${VIBE_APP:-$(cd "$DIR/../../../.." && pwd)/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
if [ ! -x "$V" ]; then
    echo "no debug build at $APP — run: make build CONFIG=Debug" >&2
    exit 1
fi
"$V" --debug-cmd scan_bpm - < "$FILE"
