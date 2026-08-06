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
# The headline copy lives here rather than in the compositor: it is marketing
# text, and it is the thing most likely to be revised.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$ROOT/Assets"
OUT="${1:-$ROOT/Assets/app-store}"
COMPOSE="$ROOT/scripts/compose-app-store-overlay.py"

mkdir -p "$OUT"

shot() { # <source> <output> <headline> <subhead>
    [ -f "$IN/$1" ] || { echo "missing: $IN/$1 — run generate-readme-screenshots.sh" >&2; exit 1; }
    python3 "$COMPOSE" "$IN/$1" "$OUT/$2" --headline "$3" --subhead "$4"
}

shot screenshot-basic.png 01-player.png \
    "Your files, played instantly" \
    "MP3, FLAC, AIFF, WAV and more. Click the waveform to seek."

shot screenshot-playlist.png 02-playlist.png \
    "Drop a folder, start playing" \
    "Artwork, tags and BPM read on the fly, cached for speed."

shot screenshot-playlist-pitch.png 03-pitch.png \
    "DJs will feel at home" \
    "An SL-1200-style pitch fader, bar-accurate skips, and performance FX on the keys."

shot screenshot-pitch.png 04-keys.png \
    "Hands on the keyboard" \
    "Transport, bar skips, performance FX and pitch — no modifier keys."

echo "done — $OUT"
