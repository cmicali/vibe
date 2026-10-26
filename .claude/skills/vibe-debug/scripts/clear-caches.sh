#!/bin/bash
# Clear Vibe's metadata and waveform caches. A running debug build clears them
# itself (`clear_caches`, which replies once done). With no app running,
# `clear_disk_caches` deletes every PINDiskCache directory, superseded versions
# included, from inside the CLI client: it owns the container, and a shell
# touching ~/Library/Containers/ raises macOS's app-data prompt.
#
# Usage: clear-caches.sh
# App: this shell's slot (scripts/vibe-env.sh), or $VIBE_APP if set.
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/../../../../scripts/vibe-env.sh"
[ -x "$VIBE_BIN" ] || { echo "vibe: no debug binary at $VIBE_BIN (build first, or set VIBE_APP)" >&2; exit 1; }

if [ -n "$(vibe_own_pids)" ]; then
    if OUT="$("$VIBE_BIN" --debug-cmd clear_caches 2>/dev/null)"; then
        echo "$OUT"
        exit 0
    fi
    # No answer (a release build of this bundle id): deleting under it would
    # race its open caches.
    echo "vibe: an instance is running but the debug channel didn't answer —" >&2
    echo "quit it (or rebuild debug) and rerun" >&2
    exit 1
fi

"$VIBE_BIN" --debug-cmd clear_disk_caches
