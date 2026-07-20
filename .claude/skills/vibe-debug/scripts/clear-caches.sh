#!/bin/bash
# Clear Vibe's metadata + waveform caches.
#
# If a debug build is running, goes through `--debug-cmd clear_caches` (the app
# keeps running with empty caches — the reply confirms completion). Otherwise
# `--debug-cmd clear_disk_caches` deletes every PINDiskCache directory in the
# app container (sweeping superseded cache versions too) — executed inside the
# Vibe CLI client, which owns the container, so no shell process touches
# ~/Library/Containers/ (that would trip macOS's "access data from other apps"
# prompt against the terminal's host app).
#
# Usage: clear-caches.sh
# App path: $VIBE_APP if set, else <repo>/build/DerivedData/Build/Products/Debug/Vibe.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "vibe: no debug binary at $V (build first, or set VIBE_APP)" >&2; exit 1; }

if pgrep -x Vibe >/dev/null; then
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

"$V" --debug-cmd clear_disk_caches
