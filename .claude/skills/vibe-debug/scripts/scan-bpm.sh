#!/bin/bash
# Prints the BPM analyzer's verdict for one audio file as JSON:
#   {"ok":true,"bpm":120.01}      (bpm 0 = no confident tempo)
# Runs `Vibe --debug-cmd scan_bpm` — the debug CLI executes this verb in its
# own process (no channel round-trip): no app window, always a fresh analysis
# (no caches involved), works with no app running, and a running Vibe
# instance is untouched. The file is streamed via stdin because the
# direct-exec'd binary still runs sandboxed and can't read arbitrary argv
# paths (same reason argv opens fail — see SKILL.md); the client stages the
# bytes in its own container tmp, so no shell process ever touches
# ~/Library/Containers/ (which would trip macOS's "access data from other
# apps" prompt). CoreAudio identifies the format by content — no extension
# needed on the staged file.
set -euo pipefail
FILE="${1:?usage: scan-bpm.sh <audio-file>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${VIBE_APP:-$(cd "$DIR/../../../.." && pwd)/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
"$V" --debug-cmd scan_bpm - < "$FILE"
