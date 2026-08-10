#!/bin/bash
# Build the Mac App Store screenshots by compositing window captures onto
# generated backgrounds.
#
#   scripts/appstore-generate-store-screenshots.sh [lang]     # default en
#   scripts/appstore-generate-store-screenshots.sh --all      # every catalog language
#
# Every language composites the same README captures from Assets/ — the
# window shows only song titles and artwork, nothing localized, so the
# captures are shared. Captions come from Assets/app-store/copy/<lang>/
# screenshots.json and the output goes to Assets/app-store/screenshots/<lang>/
# (only the English set is tracked). A missing translation fails loudly — an
# English caption must never ship silently on a localized screenshot.
#
# This is the mock-up path: it needs no app, no debug build and no screen
# recording permission, only the alpha-channel window captures. Regenerate
# those first if the UI has changed, then run this.
#
# The other path, appstore-capture-app-screenshots.sh, photographs the window
# over a staged desktop so the Liquid Glass shows a real backdrop. It is the
# honest one, but it can only show the window at its captured size, which on a
# 2880x1800 canvas leaves the UI small. This one upscales the capture ~1.6x so
# the window is the picture, at the cost of being a composite. See the header
# of compose-app-store-overlay.py.
#
# The captions live in Assets/app-store/copy/ rather than here: they are
# marketing text, revised alongside the rest of the App Store copy. The shot
# table below is design, not copy — it maps each caption id to a capture, an
# output name and an optional glyph row, identically for every language.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/scripts/compose-app-store-overlay.py"
LANGS="$ROOT/scripts/catalog-languages.sh"

if [ "${1:-}" = --all ]; then
    while read -r l; do "$0" "$l"; done < <("$LANGS")
    exit 0
fi

L="${1:-en}"
if ! "$LANGS" | grep -qx "$L"; then
    echo "unknown language '$L' — catalog languages:" >&2
    "$LANGS" | tr '\n' ' ' >&2
    echo >&2
    exit 64
fi

IN="$ROOT/Assets"
COPY="$ROOT/Assets/app-store/copy/$L/screenshots.json"
OUT="${OUT_DIR:-$ROOT/Assets/app-store/screenshots/$L}"

[ -f "$COPY" ] || {
    echo "missing: $COPY — translate Assets/app-store/copy/en/screenshots.json for '$L'" >&2
    exit 1
}

mkdir -p "$OUT"

# Optional row of SF Symbols drawn above the player headline, larger than it.
# Empty means no row, which is the current design — the glyphs are OFF.
#
# To turn the row back on, restore the five performance FX in Q-W-E-R-T order:
#   PLAYER_GLYPHS="dial.min,dial.max.fill,water.waves,repeat,repeat.circle"
#
# Any names used here must stay identical to the ones the FX menu passes to
# NSImage(systemSymbolName:) in Vibe/Menu/MainMenuBuilder.m, so the shot shows
# the app's own artwork rather than a lookalike. The rendering path is
# scripts/screenshots/render-symbols.swift.
PLAYER_GLYPHS=""

caption() { # <id> <headline|subhead>
    local v
    v="$(jq -r --arg id "$1" --arg f "$2" \
        'first(.[] | select(.id == $id)) | .[$f] // empty' "$COPY")"
    [ -n "$v" ] || { echo "missing or empty $2 for shot '$1' in $COPY" >&2; exit 1; }
    printf '%s' "$v"
}

shot() { # <id> <source> <output> [glyphs]
    [ -f "$IN/$2" ] || { echo "missing: $IN/$2 — run generate-readme-screenshots.sh" >&2; exit 1; }
    python3 "$COMPOSE" "$IN/$2" "$OUT/$3" --lang "$L" \
        --headline "$(caption "$1" headline)" \
        --subhead "$(caption "$1" subhead)" \
        --glyphs "${4:-}"
}

shot player   screenshot-basic.png          01-player.png   "$PLAYER_GLYPHS"
shot playlist screenshot-playlist.png       02-playlist.png
shot pitch    screenshot-playlist-pitch.png 03-pitch.png
shot keys     screenshot-pitch.png          04-keys.png

echo "done — $OUT"
