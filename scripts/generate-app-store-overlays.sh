#!/bin/bash
# Build the Mac App Store screenshots by compositing the README captures in
# Assets/ onto generated backgrounds.
#
#   scripts/generate-app-store-overlays.sh [out-dir]     # default Assets/app-store
#
# This is the mock-up path: it needs no app, no debug build and no screen
# recording permission, only the alpha-channel window captures that
# generate-readme-screenshots.sh leaves in Assets/. Regenerate those first if
# the UI has changed, then run this.
#
# The other path, generate-app-store-screenshots.sh, photographs the window
# over a staged desktop so the Liquid Glass shows a real backdrop. It is the
# honest one, but it can only show the window at its captured size, which on a
# 2880x1800 canvas leaves the UI small. This one upscales the capture ~1.6x so
# the window is the picture, at the cost of being a composite. See the header
# of compose-app-store-overlay.py.
#
# The headline copy lives in docs/app-store-screenshot-copy.sh rather than in
# the compositor or this script: it is marketing text, and it is the thing
# most likely to be revised.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$ROOT/Assets"
OUT="${1:-$ROOT/Assets/app-store}"
COMPOSE="$ROOT/scripts/compose-app-store-overlay.py"

source "$ROOT/docs/app-store-screenshot-copy.sh"

mkdir -p "$OUT"

shot() { # <source> <output> <headline> <subhead> [glyphs]
    [ -f "$IN/$1" ] || { echo "missing: $IN/$1 — run generate-readme-screenshots.sh" >&2; exit 1; }
    python3 "$COMPOSE" "$IN/$1" "$OUT/$2" --headline "$3" --subhead "$4" --glyphs "${5:-}"
}

shot screenshot-basic.png          01-player.png   "$COPY_PLAYER_HEADLINE"   "$COPY_PLAYER_SUBHEAD" \
                                                   "$COPY_PLAYER_GLYPHS"
shot screenshot-playlist.png       02-playlist.png "$COPY_PLAYLIST_HEADLINE" "$COPY_PLAYLIST_SUBHEAD"
shot screenshot-playlist-pitch.png 03-pitch.png    "$COPY_PITCH_HEADLINE"    "$COPY_PITCH_SUBHEAD"
shot screenshot-pitch.png          04-keys.png     "$COPY_KEYS_HEADLINE"     "$COPY_KEYS_SUBHEAD"

echo "done — $OUT"
