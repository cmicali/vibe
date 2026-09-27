#!/bin/bash
# Clear Vibe's metadata and waveform caches. A running debug build clears them
# itself (`clear_caches`, which replies once done). With no app running,
# `clear_disk_caches` deletes every PINDiskCache directory, superseded versions
# included, from inside the CLI client: it owns the container, and a shell
# touching ~/Library/Containers/ raises macOS's app-data prompt.
#
# Usage: clear-caches.sh
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "vibe: no debug binary at $V (build first, or set VIBE_APP)" >&2; exit 1; }

# The iOS Simulator's app is named Vibe too; it is never this script's instance.
mac_vibe_pids() {
    for p in $(pgrep -x Vibe 2>/dev/null); do
        case "$(ps -o command= -p "$p" 2>/dev/null)" in *CoreSimulator*) ;; *) echo "$p" ;; esac
    done
}

if [ -n "$(mac_vibe_pids)" ]; then
    if OUT="$("$V" --debug-cmd clear_caches 2>/dev/null)"; then
        echo "$OUT"
        exit 0
    fi
    # No answer (a release build, or another build's instance): deleting under
    # it would race its open caches.
    echo "vibe: an instance is running but the debug channel didn't answer —" >&2
    echo "quit it (or rebuild debug) and rerun" >&2
    exit 1
fi

"$V" --debug-cmd clear_disk_caches
