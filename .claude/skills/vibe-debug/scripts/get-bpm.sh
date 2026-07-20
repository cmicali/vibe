#!/bin/bash
# Prints the BPM analyzer's verdict for one audio file as JSON:
#   {"ok":true,"bpm":120.01}      (bpm 0 = no confident tempo)
# Runs `Vibe --debug-cmd scan_bpm` — the debug CLI executes this verb in its
# own process (no channel round-trip): no app window, always a fresh analysis
# (no caches involved), works with no app running, and a running Vibe
# instance is untouched. The file is copied into the app container's tmp
# first because the direct-exec'd binary still runs sandboxed and can't read
# arbitrary argv paths (same reason argv opens fail — see SKILL.md).
set -euo pipefail
FILE="${1:?usage: get-bpm.sh <audio-file>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${VIBE_APP:-$(cd "$DIR/../../../.." && pwd)/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
CONTAINER_TMP="$HOME/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp"
mkdir -p "$CONTAINER_TMP"
TMP="$CONTAINER_TMP/bpm-scan-$$-$(basename "$FILE")"
cp "$FILE" "$TMP"
trap 'rm -f "$TMP"' EXIT
"$V" --debug-cmd scan_bpm "$TMP"
