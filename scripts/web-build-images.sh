#!/usr/bin/env bash
#
# Re-derive Assets/Web/img/ from the screenshots already in the repo.
#
# These used to be made by hand, and nothing re-made them when the captures
# changed: the 1.12 screenshot rework regenerated every Assets/screenshot-*.png
# and the website went on serving August's copies for a month, including on a
# release deploy. --check fails when a derivative is stale, so the next time
# only the captures move it is caught rather than noticed.
#
# The window captures carry their own rounded corners and a transparent margin,
# which the page shadows with filter: drop-shadow — so alpha is preserved and
# nothing is flattened onto a background.
#
# Usage: scripts/web-build-images.sh [--check]
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# <source capture>:<web basename>
PAIRS=(
    "Assets/screenshot-basic.png:player"
    "Assets/screenshot-playlist.png:playlist"
    "Assets/screenshot-ios-iphone-player.png:ios"
)

STALE=0
for pair in "${PAIRS[@]}"; do
    SRC="${pair%%:*}"; NAME="${pair##*:}"
    [[ -f "$SRC" ]] || { echo "error: missing source $SRC" >&2; exit 1; }
    OUT="Assets/Web/img/$NAME"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

    # ios is the odd one: a simulator capture is a plain rectangle, so it is
    # given the rounded corners and margin the window shots already have.
    if [[ "$NAME" == ios ]]; then EXTRA=phone; else EXTRA=plain; fi

    python3 - "$SRC" "$TMP/$NAME" "$EXTRA" <<'PY'
import sys
from PIL import Image, ImageDraw
src, out, kind = sys.argv[1], sys.argv[2], sys.argv[3]
im = Image.open(src).convert("RGBA")
if kind == "phone":
    CONTENT_W, MARGIN, RADIUS = 560, 7, 160
    w, h = im.size
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=RADIUS, fill=255)
    im.putalpha(mask)
    ch = round(h * CONTENT_W / w)
    im = im.resize((CONTENT_W, ch), Image.LANCZOS)
    canvas = Image.new("RGBA", (CONTENT_W + 2 * MARGIN, ch + 2 * MARGIN), (0, 0, 0, 0))
    canvas.paste(im, (MARGIN, MARGIN), im)
    im = canvas
im.save(out + ".png", optimize=True)
im.save(out + ".webp", quality=88, method=6)
PY

    for ext in png webp; do
        if [[ $CHECK == 1 ]]; then
            if ! cmp -s "$TMP/$NAME.$ext" "$OUT.$ext"; then
                echo "stale: $OUT.$ext does not match $SRC"; STALE=1
            fi
        else
            mv "$TMP/$NAME.$ext" "$OUT.$ext"
            echo "wrote $OUT.$ext"
        fi
    done
    rm -rf "$TMP"; trap - EXIT
done

if [[ $CHECK == 1 ]]; then
    [[ $STALE == 0 ]] && echo "web images: up to date" || {
        echo "run scripts/web-build-images.sh to re-derive them" >&2; exit 1; }
fi
