#!/bin/bash
# Print the key analyzer's verdict for one audio file as JSON:
#   {"ok":true,"key":"Am","camelot":"8A","index":21,...}
#   (empty strings and index -1 = no confident key)
# Runs in the debug client's own process, the file via stdin, as scan-bpm.sh.
#
# Usage: scan-key.sh <audio-file>     (this shell's slot; $VIBE_APP overrides)
set -euo pipefail
FILE="${1:?usage: scan-key.sh <audio-file>}"
. "$(cd "$(dirname "$0")" && pwd)/../../../../scripts/vibe-env.sh"
if [ ! -x "$VIBE_BIN" ]; then
    echo "no debug build at $VIBE_APP — run: make build CONFIG=Debug" >&2
    exit 1
fi
"$VIBE_BIN" --debug-cmd scan_key - < "$FILE"
