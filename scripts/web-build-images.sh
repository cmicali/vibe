#!/usr/bin/env bash
#
# Re-derive Assets/Web/img/'s screenshots from the captures in Assets/. --check
# fails when a derivative no longer matches its source; nothing else notices.
#
# The window captures carry their own rounded corners and transparent margin,
# which the page shadows with drop-shadow, so alpha is kept, never flattened.
#
# Usage: scripts/web-build-images.sh [--check]
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# <source capture>:<web basename>
PAIRS=(
    "Assets/screenshot-basic.png:player"
    "Assets/screenshot-ios-iphone-player.png:ios"
    "Assets/screenshot-ios-iphone-playlist.png:ios-playlist"
    "Assets/screenshot-ios-iphone-seek.png:ios-seek"
    "Assets/app-store/screenshots/en/macos/02-playlist.png:store-playlist"
    "Assets/app-store/screenshots/en/macos/03-themes.png:store-themes"
    "Assets/app-store/screenshots/en/macos/04-pitch.png:store-pitch"
)

STALE=0
for pair in "${PAIRS[@]}"; do
    SRC="${pair%%:*}"; NAME="${pair##*:}"
    [[ -f "$SRC" ]] || { echo "error: missing source $SRC" >&2; exit 1; }
    OUT="Assets/Web/img/$NAME"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

    # A simulator capture is a plain rectangle, so it gets the rounded corners
    # and margin the window captures already carry.
    # The store screenshots are opaque and already framed, and only the
    # carousel shows them, which every browser draws from WebP.
    case "$NAME" in
        ios*) EXTRA=phone; EXTS="png webp" ;;
        store-*) EXTRA=store; EXTS="webp" ;;
        *) EXTRA=plain; EXTS="png webp" ;;
    esac

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
if kind == "store":
    im = im.convert("RGB").resize((1600, round(im.height * 1600 / im.width)), Image.LANCZOS)
    im.save(out + ".webp", quality=82, method=6)
    sys.exit(0)
im.save(out + ".png", optimize=True)
im.save(out + ".webp", quality=88, method=6)
PY

    for ext in $EXTS; do
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
