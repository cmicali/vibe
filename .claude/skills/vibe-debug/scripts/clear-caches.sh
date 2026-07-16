#!/bin/bash
# Clear Vibe's metadata + waveform caches.
#
# If a debug build is running, goes through `--debug-cmd clear_caches` (the app
# keeps running with empty caches — the reply confirms completion). Otherwise
# deletes every PINDiskCache directory in the app container directly, which
# also sweeps superseded cache versions.
#
# Usage: clear-caches.sh
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
CACHES="$HOME/Library/Containers/com.commonwealthrecordings.Vibe/Data/Library/Caches"

if pgrep -x Vibe >/dev/null && [ -x "$V" ]; then
    if OUT="$("$V" --debug-cmd clear_caches 2>/dev/null)"; then
        echo "$OUT"
        exit 0
    fi
    # A Vibe is running but didn't answer (release build, or a different
    # build's instance). Deleting under it would race its open caches.
    echo "vibe: an instance is running but the debug channel didn't answer —" >&2
    echo "quit it (or rebuild debug) and rerun" >&2
    exit 1
fi

shopt -s nullglob
DIRS=("$CACHES"/com.pinterest.PINDiskCache.*)
if [ ${#DIRS[@]} -eq 0 ]; then
    echo '{"ok": true, "cleared": []}'
    exit 0
fi
for d in "${DIRS[@]}"; do
    rm -rf "$d"
done
printf '{"ok": true, "cleared": [%s]}\n' \
    "$(printf '"%s",' "${DIRS[@]##*/}" | sed 's/,$//')"
