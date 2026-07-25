#!/bin/bash
# Run a vibe-debug command script and materialize its screenshots.
#
# Usage: run-script.sh <shots-dir> [script-file]      (script from file or stdin)
#
# Wraps `Vibe --debug-cmd script -`. Script replies are one JSON object per
# line; dump_screenshot replies carry the PNG base64-encoded (the sandboxed
# CLI client owns the app container, so only IT can read the snapshot file —
# the inherited stdout fd is the sanctioned sandbox crossing). This wrapper
# decodes each one to <shots-dir>/shot-NN[-label].png in command order and
# prints {"ok":true,"screenshot":"<path>"} in its place; every other reply
# line passes through untouched. Exit code is the script's (0 = every command
# succeeded).
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "no app at $APP — build first, or set VIBE_APP" >&2; exit 1; }

SHOTS="${1:-}"
[ -n "$SHOTS" ] || { echo "usage: run-script.sh <shots-dir> [script-file]" >&2; exit 64; }
mkdir -p "$SHOTS"

"$V" --debug-cmd script - < "${2:-/dev/stdin}" | {
    n=0
    while IFS= read -r line; do
        case "$line" in
            *'"pngBase64"'*)
                n=$((n + 1))
                label=$(printf '%s' "$line" | jq -r '.label // empty' | tr -cd 'A-Za-z0-9._-')
                out=$(printf '%s/shot-%02d%s.png' "$SHOTS" "$n" "${label:+-$label}")
                printf '%s' "$line" | jq -r .pngBase64 | base64 -d > "$out"
                printf '{"ok":true,"screenshot":"%s"}\n' "$out"
                ;;
            *)
                printf '%s\n' "$line"
                ;;
        esac
    done
}
exit "${PIPESTATUS[0]}"
