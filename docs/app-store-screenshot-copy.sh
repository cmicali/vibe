# Marketing copy for the Mac App Store screenshots — one headline/subhead pair
# per shot, in App Store display order. Sourced by
# scripts/generate-app-store-overlays.sh; edit the text here and rerun that
# script to regenerate the screenshots. No logic belongs in this file.

COPY_PLAYER_HEADLINE="Play local files fast"
COPY_PLAYER_SUBHEAD="MP3, FLAC, AIFF, WAV, and more. Click the waveform to seek."
# Optional row of SF Symbols drawn above the headline, larger than it. Empty
# means no row, which is the current design — the glyphs are OFF.
#
# To turn the row back on, restore the five performance FX in Q-W-E-R-T order:
#   COPY_PLAYER_GLYPHS="dial.min,dial.max.fill,water.waves,repeat,repeat.circle"
#
# Any names used here must stay identical to the ones the FX menu passes to
# NSImage(systemSymbolName:) in Vibe/Menu/MainMenuBuilder.m, so the shot shows
# the app's own artwork rather than a lookalike. The rendering path is
# scripts/screenshots/render-symbols.swift.
COPY_PLAYER_GLYPHS=""

COPY_PLAYLIST_HEADLINE="Drop a folder, start playing"
COPY_PLAYLIST_SUBHEAD="Artwork, tags, and BPM read in the background, cached for speed."

COPY_PITCH_HEADLINE="DJs will feel at home"
COPY_PITCH_SUBHEAD="A turntable-style pitch fader, bar-accurate skips, and performance FX on the keys."

COPY_KEYS_HEADLINE="Hands on the keyboard"
COPY_KEYS_SUBHEAD="Transport, bar skips, performance FX, and pitch — no modifier keys."
