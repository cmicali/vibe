#!/bin/bash
# Run a debug command script (`Vibe --debug-cmd script -`; stdin when no file),
# saving its replies and screenshots.
#
# Usage: run-script.sh [--assert '<jq predicate>'] <output-dir> [script-file]
#
# Inside a script, dump_screenshot replies carry the PNG as base64: only the
# sandboxed client can read the container, and stdout is the sanctioned
# crossing. Each is decoded to <output-dir>/shot-NN[-label].png and replaced by
# {"ok":true,"screenshot":"<path>"}; other replies pass through. The stream is
# saved to replies.jsonl, also on failure. --assert runs only after every
# command succeeds, over the replies slurped as an array; it needs at least one
# result, all true.
# Exit: the script's status; 1 artifact error; 2 assertion failed; 64 usage.
# Use a fresh directory per run.
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
