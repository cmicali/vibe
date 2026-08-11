#!/bin/bash
# Prints the key analyzer's verdict for one audio file as JSON:
#   {"ok":true,"key":"Am","camelot":"8A","index":21}
# (empty strings and index -1 = no confident key)
# Runs `Vibe --debug-cmd scan_key` — the debug CLI executes this verb in its
# own process (no channel round-trip): no app window, always a fresh analysis
# (no caches involved), works with no app running, and a running Vibe
# instance is untouched. The file is streamed via stdin for the same sandbox
# reasons as scan-bpm.sh.
set -euo pipefail
FILE="${1:?usage: scan-key.sh <audio-file>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${VIBE_APP:-$(cd "$DIR/../../../.." && pwd)/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
"$V" --debug-cmd scan_key - < "$FILE"
