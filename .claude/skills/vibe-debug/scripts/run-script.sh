#!/bin/bash
# Run a vibe-debug command script, save its replies/screenshots, and check JSON.
#
# Usage: run-script.sh [--assert '<jq predicate>'] <output-dir> [script-file]
#
# Wraps `Vibe --debug-cmd script -`. Script replies are one JSON object per
# line; dump_screenshot replies carry the PNG base64-encoded (the sandboxed
# CLI client owns the app container, so only IT can read the snapshot file —
# the inherited stdout fd is the sanctioned sandbox crossing). This wrapper
# decodes each one to <output-dir>/shot-NN[-label].png in command order and
# prints {"ok":true,"screenshot":"<path>"} in its place; every other reply
# passes through. replies.jsonl saves that same stream, including on failure.
# --assert runs AFTER all commands succeed, with the replies slurped as an
# array. Every result must be true, and at least one result is required.
# Exit: native script status; 1 for artifact errors; 2 for assertion failures;
# 64 for usage. Use a fresh directory per run to keep its artifacts together.
set -uo pipefail

ASSERTION=
if [ "${1:-}" = --assert ]; then
    [ "$#" -ge 3 ] && [ -n "$2" ] || { echo "--assert requires a jq predicate and output directory" >&2; exit 64; }
    ASSERTION="$2"
    shift 2
fi
[ "$#" -ge 1 ] && [ "$#" -le 2 ] && [ -n "$1" ] || {
    echo "usage: run-script.sh [--assert '<jq predicate>'] <output-dir> [script-file]" >&2
    exit 64
}
command -v jq >/dev/null || { echo "run-script.sh requires jq" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
[ -x "$V" ] || { echo "no app at $APP — build first, or set VIBE_APP" >&2; exit 1; }

mkdir -p "$1" || exit 1
OUTPUT="$(cd "$1" && pwd)" || exit 1

"$V" --debug-cmd script - < "${2:-/dev/stdin}" | {
    set -e
    n=0
    while IFS= read -r line; do
        line=$(printf '%s\n' "$line" | jq -ce 'if type == "object" then . else error("expected reply object") end')
        if printf '%s' "$line" | jq -e 'has("pngBase64")' >/dev/null; then
            n=$((n + 1))
            label=$(printf '%s' "$line" | jq -r '.label // empty' | tr -cd 'A-Za-z0-9._-')
            out=$(printf '%s/shot-%02d%s.png' "$OUTPUT" "$n" "${label:+-$label}")
            printf '%s' "$line" | jq -er .pngBase64 | base64 -d > "$out"
            jq -nc --arg path "$out" '{ok: true, screenshot: $path}'
        else
            printf '%s\n' "$line"
        fi
    done
} | tee "$OUTPUT/replies.jsonl"
statuses=("${PIPESTATUS[@]}")
[ "${statuses[0]}" -eq 0 ] || exit "${statuses[0]}"
[ "${statuses[1]}" -eq 0 ] && [ "${statuses[2]}" -eq 0 ] || exit 1

if [ -n "$ASSERTION" ]; then
    jq -cs "$ASSERTION" "$OUTPUT/replies.jsonl" | jq -se 'length > 0 and all(. == true)' >/dev/null || {
        echo "vibe: assertion failed: $ASSERTION (replies: $OUTPUT/replies.jsonl)" >&2
        exit 2
    }
    echo "vibe: assertion passed (replies: $OUTPUT/replies.jsonl)" >&2
fi
