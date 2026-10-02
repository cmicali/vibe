#!/bin/bash
# Proves the live layout under the now-playing card holds still across a
# gesture: samples the selected tab's anchors (navigation bar, title, first
# row, tab bar, strip) on a display link, runs the gesture through
# drive-ios.sh, and fails if any anchor took more than one value. What scales
# under the card is a snapshot; a moving anchor is the layout jump this exists
# to catch (Vibe/iOS/AGENTS.md, RootViewController's backdrop TRAP).
#
# Usage: check-layout-stability.sh [--seconds N] [--hz N] <drive-ios.sh gesture ...>
#   check-layout-stability.sh tap 150 760                 # expand the card by the strip
#   check-layout-stability.sh --seconds 3 drag 200 300 200 800 0.4   # dismiss by drag
# Prints the samples' count and each anchor's distinct values; exit 1 on a
# move, 2 when sampling failed. The samples are left in $TMPDIR for a diff.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SECONDS_TO_SAMPLE=4
HZ=30
while [ "$#" -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_SAMPLE="$2"; shift 2 ;;
        --hz) HZ="$2"; shift 2 ;;
        *) break ;;
    esac
done
[ "$#" -ge 1 ] || { echo "usage: check-layout-stability.sh [--seconds N] [--hz N] <gesture ...>" >&2; exit 64; }

OUT="${TMPDIR:-/tmp}/vibe-layout-samples.json"
"$DIR/debug-ios.sh" sample_layout_anchors "$SECONDS_TO_SAMPLE" "$HZ" >/dev/null
"$DIR/drive-ios.sh" "$@" >/dev/null
sleep "$SECONDS_TO_SAMPLE"
"$DIR/debug-ios.sh" dump_layout_samples > "$OUT"

COUNT=$(jq '.samples | length' "$OUT")
[ "$COUNT" -gt 1 ] || { echo "no samples (is the app up, and the gesture reaching it?)" >&2; exit 2; }
echo "samples: $COUNT, backdrop scale $(jq -c '[.samples[].backdropScale] | [min, max]' "$OUT"), card offset $(jq -c '[.samples[].cardOffset] | [min, max]' "$OUT")"

STATUS=0
for anchor in navigationBar title firstRow tabBar strip contentOffsetY; do
    values=$(jq -c --arg a "$anchor" '[.samples[] | .[$a] | select(. != null)] | unique' "$OUT")
    n=$(printf '%s' "$values" | jq 'length')
    if [ "$n" -gt 1 ]; then
        echo "MOVED  $anchor: $values"
        STATUS=1
    elif [ "$n" -eq 1 ]; then
        echo "still  $anchor: $(printf '%s' "$values" | jq -c '.[0]')"
    fi
done
exit $STATUS
