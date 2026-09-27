#!/bin/bash
# Print the key analyzer's verdict for one audio file as JSON:
#   {"ok":true,"key":"Am","camelot":"8A","index":21,...}
#   (empty strings and index -1 = no confident key)
# Runs in the debug client's own process, the file via stdin, as scan-bpm.sh.
#
# Usage: scan-key.sh <audio-file>     (app path: $VIBE_APP overrides)
set -euo pipefail
FILE="${1:?usage: scan-key.sh <audio-file>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${VIBE_APP:-$(cd "$DIR/../../../.." && pwd)/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
if [ ! -x "$V" ]; then
    echo "no debug build at $APP — run: make build CONFIG=Debug" >&2
    exit 1
fi
"$V" --debug-cmd scan_key - < "$FILE"
