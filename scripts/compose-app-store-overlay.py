#!/usr/bin/env python3
"""Composite a window-only Vibe capture onto a designed App Store background.

    scripts/compose-app-store-overlay.py <shot.png> <out.png> [--headline ...]

Unlike appstore-capture-app-screenshots.sh, which photographs the window over a
staged desktop so the Liquid Glass shows a real backdrop, this is a pure
mock-up: it takes an already-captured window (the alpha-channel PNGs in
Assets/, produced by generate-readme-screenshots.sh) and lays it over a
generated background. That is only honest because those captures come out
effectively opaque -- the window's own material is dense enough that nothing
behind it would show through anyway -- so the background is decoration around
the window, never through it.

The background is built from the app's own identity rather than a wallpaper:
the vinyl-groove texture from the app icon, lit by a heavily blurred wash of
the playing track's own album artwork (cropped out of the shot itself), then
vignetted. Each shot therefore carries the colour of the music it is showing.
"""

import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 2880x1800 is the 16:10 size App Store Connect takes for macOS; 2560x1600 and
# 1440x900 are the others and work unchanged, since everything is placed by
# fraction of the canvas.
CANVAS_W, CANVAS_H = 2880, 1800

# How much of the canvas the window may take. Width usually binds; the height
# cap only comes into play for the tall playlist+pitch shot, and leaves room
# for the headline above. The README captures are 1360-1550px wide, so a width
# fraction this high means upscaling ~1.5-1.8x -- checked at 1:1, and the
# 2x-retina source takes it without visible softening.
WINDOW_W_FRAC = 0.84
WINDOW_H_FRAC = 0.72

# Vertical placement of the headline + window block within the free space.
BLOCK_Y_FRAC = 0.5

GROOVE = os.path.join(ROOT, "Assets", "record background.png")

# SF Pro, the system font, as a variable font -- named instances rather than
# separate faces. Matches the type inside the window. PIL does no font
# fallback, so CJK languages must name a real face: PingFang is unreachable
# (only the Reserved PingFangUI.ttc exists, and PIL cannot open it), so
# zh-Hans uses Hiragino Sans GB, the system's PIL-openable Simplified face.
# The ttc entries are static fonts -- set_variation_by_name would raise.
FONT = "/System/Library/Fonts/SFNS.ttf"
HEADLINE_WEIGHT, SUBHEAD_WEIGHT = "Semibold", "Regular"
CJK_FONTS = {  # (path, ttc index) per role
    "ja": {
        "headline": ("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", 0),
        "subhead": ("/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", 0),
    },
    "ko": {
        "headline": ("/System/Library/Fonts/AppleSDGothicNeo.ttc", 4),  # SemiBold
        "subhead": ("/System/Library/Fonts/AppleSDGothicNeo.ttc", 0),  # Regular
    },
    "zh-Hans": {
        "headline": ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2),  # W6
        "subhead": ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),  # W3
    },
    "zh-Hant": {  # Heiti TC — the only PIL-openable Traditional sans
        "headline": ("/System/Library/Fonts/STHeiti Medium.ttc", 0),
        "subhead": ("/System/Library/Fonts/STHeiti Light.ttc", 0),
    },
}
# Tracking as a fraction of the point size. SF tightens at display sizes;
# negative tracking is a Latin display convention, so CJK stays at 0.
HEADLINE_TRACKING, SUBHEAD_TRACKING = -0.014, 0.0

# Optional row of SF Symbols above the headline (--glyphs). Height and gap are
# fractions of the canvas width; the height is deliberately larger than the
# headline's point size, so the row reads as artwork rather than as a caption.
SYMBOL_RENDERER = os.path.join(ROOT, "scripts", "screenshots", "render-symbols.swift")
GLYPH_H_FRAC = 0.050
GLYPH_GAP_FRAC = 0.030
GLYPH_BLOCK_GAP_FRAC = 0.026
GLYPH_ALPHA = 235
GLYPH_WEIGHT = "regular"
# Point size handed to the rasterizer. Symbols are vector, so this only sets
# resolution -- keep it comfortably above the drawn height.
GLYPH_RENDER_PT = 220


# --- the window -------------------------------------------------------------


def load_window(path):
    """Crop a capture down to the window body, dropping the baked-in shadow.

    Returns the cropped RGBA image and the side of its square album-art tile
    (which is the header height, since the artwork fills the header)."""
    im = Image.open(path).convert("RGBA")
    alpha = np.array(im)[:, :, 3]
    ys, xs = np.where(alpha > 128)
    if not len(xs):
        sys.exit(f"{path}: no opaque pixels -- is this a window capture?")
    win = im.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))

    # The crop's corner notches still hold shadow the window itself does not
    # cover, so re-cut them against a clean rounded rect. The radius is however
    # far the top row runs transparent before the corner curve ends.
    a = np.array(win)[:, :, 3]
    radius = int((a[0] < 200).sum() / 2) or 1
    mask = Image.new("L", win.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, win.width - 1, win.height - 1), radius=radius, fill=255
    )
    win.putalpha(Image.fromarray(np.minimum(a, np.array(mask))))

    # The artwork is a square tile flush with the window's top-left corner, so
    # its side is the header height: the first row below the header whose left
    # edge stops matching the tile. Detect it as the tallest run for which the
    # tile stays square-ish -- in practice the header is the same height in
    # every shot, so fall back to that rather than guessing.
    return win, header_height(win)


def header_height(win):
    """Height of the player header, i.e. the side of the square artwork tile.

    Found by walking down the left edge: inside the artwork the pixels are
    photographic and vary row to row; the playlist below starts a long run of
    near-identical dark rows."""
    px = np.array(win.convert("RGB"))[:, :12].mean(axis=1)  # left edge, per row
    if win.height <= win.width // 3:
        return win.height  # no playlist -- the header is the whole window
    delta = np.abs(np.diff(px, axis=0)).sum(axis=1)
    # The playlist's first row is the biggest edge in the upper half.
    lo, hi = int(win.height * 0.2), int(win.height * 0.75)
    return int(lo + np.argmax(delta[lo:hi]))


def drop_shadow(canvas_size, alpha, pos, scale):
    """Two-layer shadow: a wide ambient pool plus a tighter, offset key.

    Each layer is laid out at full canvas size and blurred there, rather than
    blurred at the window's own size and then offset into place. A Gaussian
    clips at its image bounds, so the small-canvas version cannot fall off past
    the window rect -- it ends on a hard rectangular edge, which the offset then
    slides out from behind the rounded corners as a visible dark box."""
    layers = []
    for blur, dy, opacity in ((70, 8, 0.42), (26, 26, 0.55)):
        mask = Image.new("L", canvas_size, 0)
        mask.paste(alpha.point(lambda v, o=opacity: int(v * o)), (pos[0], pos[1] + int(dy * scale)))
        shadow = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
        shadow.putalpha(mask.filter(ImageFilter.GaussianBlur(blur * scale)))
        layers.append(shadow)
    return layers


# --- the background ---------------------------------------------------------


def aspect_fill(im, w, h):
    scale = max(w / im.width, h / im.height)
    im = im.resize((max(w, int(im.width * scale)), max(h, int(im.height * scale))), Image.LANCZOS)
    return im.crop(
        ((im.width - w) // 2, (im.height - h) // 2, (im.width - w) // 2 + w, (im.height - h) // 2 + h)
    )


def artwork_wash(art, w, h):
    """Blow the album art up into a soft, saturated colour field."""
    # Downsample first: at this blur radius the detail is gone regardless, and
    # a 32px source makes the gradient smooth instead of blotchy.
    wash = aspect_fill(art.convert("RGB").resize((32, 32), Image.LANCZOS), w, h)
    wash = wash.filter(ImageFilter.GaussianBlur(w * 0.09))
    wash = ImageEnhance.Color(wash).enhance(2.1)
    return ImageEnhance.Brightness(wash).enhance(0.5)


def vignette(w, h, strength=0.7):
    """Radial falloff, brightest a little above centre."""
    y, x = np.mgrid[0:h, 0:w]
    r = np.hypot((x - w / 2) / (w / 2), (y - h * 0.42) / (h / 2)) / 1.25
    return Image.fromarray((np.clip(1 - strength * r**1.7, 0, 1) * 255).astype(np.uint8), "L")


def build_background(art, w, h):
    groove = aspect_fill(Image.open(GROOVE).convert("RGB"), w, h)
    groove = ImageEnhance.Brightness(groove).enhance(2.6)  # the texture is near-black
    bg = Image.blend(groove, artwork_wash(art, w, h), 0.78)
    bg = Image.composite(bg, Image.new("RGB", (w, h), (0, 0, 0)), vignette(w, h))
    return ImageEnhance.Contrast(bg).enhance(1.06).convert("RGBA")


# --- SF Symbol row ----------------------------------------------------------


def render_glyphs(names, out_dir):
    """Rasterize SF Symbols through AppKit -- PIL cannot reach them."""
    subprocess.run(
        ["swift", SYMBOL_RENDERER, out_dir, str(GLYPH_RENDER_PT), GLYPH_WEIGHT, *names],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return [Image.open(os.path.join(out_dir, f"{n}.png")).convert("RGBA") for n in names]


def layout_glyphs(images, w):
    """Scale the row uniformly and lay it out centred. Uniform scaling matters:
    the symbols were rasterized at one point size, so their differing natural
    heights are SF Symbols' own optical sizing, and normalizing each to the same
    height would distort the set relative to how the app draws them."""
    target = w * GLYPH_H_FRAC
    scale = target / max(im.height for im in images)
    scaled = [
        im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
        for im in images
    ]
    gap = w * GLYPH_GAP_FRAC
    total = sum(im.width for im in scaled) + gap * (len(scaled) - 1)
    return scaled, total, max(im.height for im in scaled)


def draw_glyphs(canvas, y, images, w):
    """Draw the row centred on the canvas at top y. Returns the height used."""
    scaled, total, row_h = layout_glyphs(images, w)
    x = (w - total) / 2
    for im in scaled:
        if GLYPH_ALPHA < 255:
            im.putalpha(im.getchannel("A").point(lambda v: v * GLYPH_ALPHA // 255))
        # Centre each symbol on the row's midline rather than its top, so the
        # shorter ones (water.waves) sit level with the taller ones.
        canvas.alpha_composite(im, (round(x), round(y + (row_h - im.height) / 2)))
        x += im.width + w * GLYPH_GAP_FRAC
    return row_h


# --- text -------------------------------------------------------------------

# Point size and leading of each line, as fractions of the canvas width.
LINES = (("headline", 0.0330, 1.30, 255), ("subhead", 0.0180, 1.40, 195))
# Widest a text line may run, as a fraction of the canvas. When a translation
# exceeds it the point size shrinks (headline) or the line wraps then shrinks
# (subhead, max two lines); below MIN_SHRINK of nominal the copy is too long
# to read at store size, so fail and shorten the translation instead.
MAX_TEXT_W_FRAC = 0.92
MIN_SHRINK = 0.72
SHRINK_STEP = 0.96


def make_font(kind, size, lang):
    if lang in CJK_FONTS:
        path, index = CJK_FONTS[lang][kind]
        return ImageFont.truetype(path, size, index=index)
    font = ImageFont.truetype(FONT, size)
    font.set_variation_by_name(HEADLINE_WEIGHT if kind == "headline" else SUBHEAD_WEIGHT)
    return font


def tracked(draw, xy, text, font, fill, tracking):
    """draw.text with letter-spacing, centred on xy. PIL has no tracking, so
    the run is measured with it applied and then laid out glyph by glyph."""
    widths = [draw.textlength(c, font=font) for c in text]
    total = sum(widths) + tracking * (len(text) - 1)
    x = xy[0] - total / 2
    for c, cw in zip(text, widths):
        draw.text((x, xy[1]), c, font=font, fill=fill, anchor="la")
        x += cw + tracking


def line_width(draw, text, font, tracking):
    widths = [draw.textlength(c, font=font) for c in text]
    return sum(widths) + tracking * (len(text) - 1)


def wrap_two(draw, text, font, tracking, max_w, lang):
    """Greedy wrap into at most two lines; None if two don't fit. ja/zh-Hans
    have no spaces, so they may break at any character (kinsoku deliberately
    not implemented -- two marketing lines don't warrant it)."""
    if line_width(draw, text, font, tracking) <= max_w:
        return [text]
    units, joiner = (
        (list(text), "") if lang in ("ja", "zh-Hans", "zh-Hant") else (text.split(" "), " ")
    )
    for cut in range(len(units) - 1, 0, -1):
        first = joiner.join(units[:cut]).rstrip()
        if line_width(draw, first, font, tracking) <= max_w:
            second = joiner.join(units[cut:]).lstrip()
            if line_width(draw, second, font, tracking) <= max_w:
                return [first, second]
            break
    return None


def layout_text(headline, subhead, w, lang):
    """Resolve both strings into rendered lines: (text, font, tracking_px,
    leading_px, alpha) each. draw_text and text_height both consume this, so
    the drawn stack and the vertical centering can never disagree."""
    draw = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    max_w = w * MAX_TEXT_W_FRAC
    headline_tracking = 0.0 if lang in CJK_FONTS else HEADLINE_TRACKING
    out = []
    for (kind, size_frac, leading, alpha), content, tracking_frac in zip(
        LINES, (headline, subhead), (headline_tracking, SUBHEAD_TRACKING)
    ):
        if not content:
            continue
        nominal = int(w * size_frac)
        size = nominal
        while True:
            font = make_font(kind, size, lang)
            tracking = tracking_frac * size
            if kind == "headline":
                fits = line_width(draw, content, font, tracking) <= max_w
                lines = [content] if fits else None
            else:
                lines = wrap_two(draw, content, font, tracking, max_w, lang)
            if lines:
                break
            size = int(size * SHRINK_STEP)
            if size < nominal * MIN_SHRINK:
                sys.exit(f"{lang}: {kind} too long even at {MIN_SHRINK:.0%} size: {content!r}")
        out.extend((line, font, tracking, size * leading, alpha) for line in lines)
    return out


def draw_text(canvas, y, layout, w):
    """Centred headline block, over a soft dark halo so it stays legible
    wherever the artwork wash happens to be bright."""
    halo = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    text = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    hd, td = ImageDraw.Draw(halo), ImageDraw.Draw(text)

    for line, font, tracking, leading, alpha in layout:
        for draw, fill in ((hd, (0, 0, 0, 150)), (td, (255, 255, 255, alpha))):
            tracked(draw, (w / 2, y), line, font, fill, tracking)
        y += leading

    canvas.alpha_composite(halo.filter(ImageFilter.GaussianBlur(w * 0.012)))
    canvas.alpha_composite(text)


def text_height(layout):
    return sum(leading for _, _, _, leading, _ in layout)


# --- run --------------------------------------------------------------------


def compose(shot, out, headline, subhead, canvas_w, canvas_h, width_frac, glyphs=(), lang="en"):
    win, header = load_window(shot)
    art = win.crop((0, 0, header, header))

    # Width binds for the short shots, height for the tall playlist+pitch one.
    scale = min((canvas_w * width_frac) / win.width, (canvas_h * WINDOW_H_FRAC) / win.height)
    win = win.resize((int(win.width * scale), int(win.height * scale)), Image.LANCZOS)

    canvas = build_background(art, canvas_w, canvas_h)

    glyph_images = []
    glyph_h = glyph_gap = 0
    if glyphs:
        with tempfile.TemporaryDirectory() as tmp:
            glyph_images = render_glyphs(glyphs, tmp)
        glyph_h = layout_glyphs(glyph_images, canvas_w)[2]
        glyph_gap = canvas_w * GLYPH_BLOCK_GAP_FRAC

    layout = layout_text(headline, subhead, canvas_w, lang)
    block_h = text_height(layout)
    gap = canvas_w * 0.032 if block_h else 0
    stack = glyph_h + glyph_gap + block_h + gap + win.height
    top = (canvas_h - stack) * BLOCK_Y_FRAC

    if glyph_images:
        draw_glyphs(canvas, top, glyph_images, canvas_w)
        top += glyph_h + glyph_gap
    if block_h:
        draw_text(canvas, top, layout, canvas_w)

    x = (canvas_w - win.width) // 2
    y = int(top + block_h + gap)
    for shadow in drop_shadow(canvas.size, win.getchannel("A"), (x, y), scale):
        canvas.alpha_composite(shadow)
    canvas.alpha_composite(win, (x, y))

    canvas.convert("RGB").save(out)
    print(f"wrote {out} ({canvas_w}x{canvas_h}, window {win.width}px wide, {scale:.2f}x)")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("shot", nargs="?")
    p.add_argument("out", nargs="?")
    p.add_argument("--headline", default="")
    p.add_argument("--subhead", default="")
    p.add_argument("--lang", default="en")
    p.add_argument("--width", type=float, default=WINDOW_W_FRAC)
    p.add_argument("--canvas", default=f"{CANVAS_W}x{CANVAS_H}")
    p.add_argument(
        "--glyphs",
        default="",
        help="comma-separated SF Symbol names drawn in a row above the headline",
    )
    p.add_argument(
        "--measure",
        action="store_true",
        help="lay the text out and exit; nonzero if it cannot fit (no image written)",
    )
    a = p.parse_args()
    cw, ch = (int(v) for v in a.canvas.split("x"))
    if a.measure:
        layout_text(a.headline, a.subhead, cw, a.lang)
        return
    if not (a.shot and a.out):
        p.error("shot and out are required unless --measure")
    glyphs = [g.strip() for g in a.glyphs.split(",") if g.strip()]
    compose(a.shot, a.out, a.headline, a.subhead, cw, ch, a.width, glyphs, a.lang)


if __name__ == "__main__":
    main()
