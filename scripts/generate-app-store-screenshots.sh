#!/bin/bash
# Generate the Mac App Store screenshots: the app, playing, composited onto a
# background image at 2880x1800 (one of App Store Connect's accepted macOS
# sizes, and the size the backgrounds were authored at.
#
#   scripts/generate-app-store-screenshots.sh <background ...> [shot ...]
#   shot names: player playlist pitch     # no shot arg = all three
#
#   1. player    default state — playlist and pitch panel hidden, transport
#                buttons NOT showing (nothing hovered)
#   2. playlist  playlist open, transport buttons showing
#   3. pitch     playlist closed, pitch panel open, Sonic Cirrus waveform,
#                transport buttons showing
#
# All three are playing, with the playhead at $SEEK of the track.
#
# Backgrounds are the leading arguments — one for all three shots, or three, in
# the shot order above (that mapping is fixed, so `<bg1> <bg2> <bg3> pitch`
# regenerates the pitch shot on bg3). Arguments are split by existence: a
# leading path that is a file is a background, everything after is a shot name.
#
# A background can be any size or aspect ratio: it is aspect-filled and centred
# into the canvas, so a 16:10 image is used whole and anything else is cropped
# on its long axis (a square wallpaper keeps its middle band).
#
# HOW THE GLASS IS KEPT HONEST. The window chrome is Liquid Glass, and the
# window-spanning backdrop is the Clear style — transparent enough that the
# desktop behind it shows through nearly directly. So the capture cannot be
# taken over an arbitrary desktop and pasted onto the background: what shows
# through the window has to BE the background, at the same scale and alignment
# as the pixels around the window. The run therefore stages the background on
# screen first (backdrop.swift --rect, a scaled rendering of the same canvas
# the compositor builds, positioned so the window sits exactly where it will
# sit in the output) and only then photographs the window. The composite is a
# real screen capture of the app over that background, not a mock-up.
#
# Needs the same setup as the README shots (see screenshot-lib.sh): a DEBUG
# build plus Screen Recording and Accessibility permission for this terminal.
# It moves the mouse cursor and covers the screen while it runs; audio is muted
# (--silent) throughout.
#
# Track paths are hardcoded below — this is a one-off authoring tool, not a
# test. Side effects: pins the app's window appearance to $APPEARANCE (default
# dark), sets the window's body width to $BODY_WIDTH, and restores the waveform
# style it found before quitting.
set -euo pipefail

# shellcheck source=scripts/screenshot-lib.sh
source "$(dirname "$0")/screenshot-lib.sh"

OUT_DIR="${OUT_DIR:-$ROOT/Assets/app-store}"
APPEARANCE="${APPEARANCE:-dark}"

# Canvas — 2880x1800 is the 16:10 macOS screenshot size App Store Connect
# takes. 2560x1600 and 1440x900 are the others; the window is placed by
# fraction, so they work unchanged.
CANVAS_W="${CANVAS_W:-2880}"
CANVAS_H="${CANVAS_H:-1800}"

# Window body width in points (the player without the pitch panel's slice).
# 900pt is 1800px on a 2x display = 62.5% of the canvas width, so the window is
# drawn at its native pixels — SCALE=1 resamples nothing, and the waveform and
# label edges stay exactly as crisp as the screen shows them. Raising SCALE
# upscales the capture; lowering it downscales.
BODY_WIDTH="${BODY_WIDTH:-900}"
SCALE="${SCALE:-1}"

# Where the window's top-left corner sits, as a fraction of the free space left
# over on each axis: 0.5/0.5 centres it. Same numbers for every shot, so the
# three images share a centre line even though they aren't the same height.
POS_X="${POS_X:-0.5}"
POS_Y="${POS_Y:-0.5}"

MUSIC="$HOME/Library/CloudStorage/Dropbox/music/Tracks"
TRACK_PLAYER="$MUSIC/2020-03/Move D - Dots.aiff"
TRACK_PITCH="$MUSIC/2026-05/Silat Beksi - Shushu.flac"
# Opened alongside TRACK_PITCH purely so the playlist has a next track and the
# next button draws enabled instead of dimmed — that shot shows the transport
# buttons, and its playlist is hidden, so the extras cost it nothing else. The
# open passes TRACK_PITCH first and the shot walks to it, so however Launch
# Services orders the batch it is never the last track.
TRACK_PITCH_EXTRAS=(
    "$MUSIC/2026-05/Steve O'Sullivan - Tribal Dub (Original Mix).flac"
    "$MUSIC/2026-05/Talismantra - Warmth Reheated.flac"
)
FOLDER="$MUSIC/2026-05"
FOLDER_TRACK="The Mountain People - Memorandum.flac"

# Fraction of the track the playhead sits at, in every shot. The seek runs
# immediately before the shutter and the track is still playing, so it aims
# SHUTTER_LEAD seconds early to cover the capture itself (a settle sleep plus
# two screencaptures).
SEEK="${SEEK:-0.40}"
SHUTTER_LEAD="${SHUTTER_LEAD:-2.5}"
# Pitch fader position for the pitch shot, in percent.
PITCH="${PITCH:-0}"

# Waveform style per shot: the app's default for the first two, and the one the
# third shot is about. Names are the renderers' +displayName.
STYLE_DEFAULT="${STYLE_DEFAULT:-Oversampling Detailed x4}"
STYLE_PITCH="${STYLE_PITCH:-Sonic Cirrus}"

# Seconds to let the playlist metadata scan (artwork, titles, durations)
# finish before capturing the folder shot. Cold, off Dropbox, 67 files takes
# ~30s; a warm metadata cache is near-instant.
SCAN_WAIT="${SCAN_WAIT:-30}"

# --- setup ------------------------------------------------------------------

usage() {
    echo "usage: $(basename "$0") <background-image> [bg2 bg3] [player|playlist|pitch ...]" >&2
    exit 64
}

# Leading existing files are backgrounds; the rest are shot names (no shot name
# is ever a path that exists, so the split needs no separator). Absolute paths,
# because the compositor and backdrop.swift are run from elsewhere.
BACKGROUNDS=()
while [ "$#" -gt 0 ] && [ -f "$1" ]; do
    BACKGROUNDS+=("$(cd "$(dirname "$1")" && pwd)/$(basename "$1")")
    shift
done
case "${#BACKGROUNDS[@]}" in
    0) usage ;;
    1) BG_PLAYER="${BACKGROUNDS[0]}"
       BG_PLAYLIST="${BACKGROUNDS[0]}"
       BG_PITCH="${BACKGROUNDS[0]}" ;;
    3) BG_PLAYER="${BACKGROUNDS[0]}"
       BG_PLAYLIST="${BACKGROUNDS[1]}"
       BG_PITCH="${BACKGROUNDS[2]}" ;;
    *) echo "pass one background for all three shots, or three (player, playlist, pitch)" >&2
       exit 64 ;;
esac

[ "$#" -gt 0 ] && SHOTS=("$@") || SHOTS=(player playlist pitch)
for s in "${SHOTS[@]}"; do
    case "$s" in
        player|playlist|pitch) ;;
        *) echo "unknown shot: $s (player|playlist|pitch)" >&2; exit 64 ;;
    esac
done

for f in "$TRACK_PLAYER" "$TRACK_PITCH" "${TRACK_PITCH_EXTRAS[@]}" "$FOLDER"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

trap screenshot_cleanup EXIT INT TERM
require_debug_build
mkdir -p "$OUT_DIR"
pkill -x Vibe 2>/dev/null && sleep 1 || true
quiet set_appearance "$APPEARANCE"

# --- geometry ---------------------------------------------------------------

# Captures are in backing-store pixels while every window rect the tooling
# reports is in points, so the ratio has to be known before the canvas layout
# can be computed. Measure it off a real capture (the opaque box in a
# window-only shot IS the window rect) rather than assuming 2x.
BACKING=""
measure_backing_scale() {
    local w box
    read -r _ _ _ _ w _ <<<"$(win_geom)"
    capture_window "$SHOT_TMP/measure.png"
    box=$(swift "$ROOT/scripts/compose-window-shot.swift" --info "$SHOT_TMP/measure.png" \
            | awk '{print $4}' | cut -dx -f1)
    BACKING=$(awk -v box="$box" -v w="$w" 'BEGIN{printf "%.6f", box / w}')
    say "display backing scale: ${BACKING}x (${w}pt window captured ${box}px wide)"
}

# Where the window lands on the canvas, and — the other half of the same
# mapping — where the canvas has to be drawn on screen for the pixels behind
# the window to be the canvas's own. Sets DEST_X/DEST_Y/DEST_W (canvas pixels,
# origin top-left) and RECT_* (screen points, origin top-left, for
# backdrop.swift --rect).
plan_geometry() {
    local x y w h
    read -r _ _ x y w h <<<"$(win_geom)"
    eval "$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v b="$BACKING" -v s="$SCALE" \
                -v cw="$CANVAS_W" -v ch="$CANVAS_H" -v px="$POS_X" -v py="$POS_Y" 'BEGIN{
        ppp = b * s;                          # canvas pixels per screen point
        dw = w * ppp; dh = h * ppp;
        dx = int((cw - dw) * px + 0.5); dy = int((ch - dh) * py + 0.5);
        printf "DEST_X=%d\nDEST_Y=%d\nDEST_W=%d\n", dx, dy, int(dw + 0.5);
        # The canvas as a screen rect, shifted so canvas (dx,dy) lands on the
        # top-left corner the window actually has. Parts of it can fall off
        # screen; only the part behind the window is ever photographed.
        printf "RECT_X=%.2f\nRECT_Y=%.2f\nRECT_W=%.2f\nRECT_H=%.2f\n",
               x - dx / ppp, y - dy / ppp, cw / ppp, ch / ppp;
    }')"
}

# Put the aligned background up and raise the app over it. Called BEFORE the
# cursor is placed: the backdrop window orders itself front, which pulls the
# cursor out of the app's window-wide tracking area and hides the transport
# buttons — so a shot that wants them showing has to hover after this, not
# before.
stage_for_capture() {
    [ -n "$BACKING" ] || measure_backing_scale
    plan_geometry
    say "staging the background (covers the screen until this finishes)"
    start_backdrop --rect "$RECT_X" "$RECT_Y" "$RECT_W" "$RECT_H" "$BACKGROUND"
    activate_vibe
}

# Set the playhead, photograph the window over the staged background, composite
# the canvas. The seek is here, at the last possible moment: staging the
# backdrop takes seconds and the track is playing throughout, so a seek before
# it would show the playhead wherever those seconds left it.
capture_app_store_shot() { # <output-name>
    local out="$OUT_DIR/$1"
    activate_vibe
    seek_fraction "$SEEK" "$SHUTTER_LEAD"
    capture_merged "$SHOT_TMP/merged.png"
    swift "$ROOT/scripts/compose-app-store-shot.swift" \
            "$BACKGROUND" "$SHOT_TMP/merged.png" "$out" \
            "$CANVAS_W" "$CANVAS_H" "$DEST_X" "$DEST_Y" "$DEST_W"
    stop_backdrop
    say "wrote $out ($(png_size "$out")px)"
}

# --- shots ------------------------------------------------------------------

shot_player() {
    BACKGROUND="$BG_PLAYER"
    say "player: $(basename "$TRACK_PLAYER") on $(basename "$BACKGROUND"), no transport buttons"
    launch "$TRACK_PLAYER"
    ensure_playlist 0
    ensure_pitch 0
    ensure_body_width "$BODY_WIDTH"
    ensure_waveform_style "$STYLE_DEFAULT"
    wait_loaded
    stage_for_capture
    cursor_out
    capture_app_store_shot 01-player.png
}

shot_playlist() {
    BACKGROUND="$BG_PLAYLIST"
    say "playlist: $FOLDER_TRACK on $(basename "$BACKGROUND"), transport buttons hovered"
    launch "$FOLDER"
    ensure_playlist 1
    ensure_pitch 0
    ensure_body_width "$BODY_WIDTH"
    ensure_waveform_style "$STYLE_DEFAULT"
    say "waiting ${SCAN_WAIT}s for the playlist metadata scan"
    quiet sleep "$SCAN_WAIT"
    center_on_track "$FOLDER_TRACK"
    wait_loaded
    select_playing_row
    stage_for_capture
    cursor_hover_window
    capture_app_store_shot 02-playlist.png
}

shot_pitch() {
    BACKGROUND="$BG_PITCH"
    say "pitch: $(basename "$TRACK_PITCH") on $(basename "$BACKGROUND"), ${PITCH}% pitch, $STYLE_PITCH waveform, transport buttons hovered"
    launch "$TRACK_PITCH" "${TRACK_PITCH_EXTRAS[@]}"
    play_track "$(basename "$TRACK_PITCH")"
    ensure_playlist 0
    ensure_pitch 1
    ensure_body_width "$BODY_WIDTH"
    ensure_waveform_style "$STYLE_PITCH"
    quiet set_pitch "$PITCH"
    wait_loaded
    stage_for_capture
    cursor_hover_window
    capture_app_store_shot 03-pitch.png
}

# --- run --------------------------------------------------------------------

# The waveform style and the window width are persisted settings this run
# overwrites, so note what the user had before touching either. Both live in
# the sandboxed container, so reading them means asking a running app; the
# pitch panel goes away first so the frame width IS the body width.
launch "$TRACK_PLAYER"
ensure_pitch 0
ORIGINAL_STYLE="$(state | jq -r .settings.waveformStyle)"
ORIGINAL_WIDTH="$(state | jq -r .window.frame | tr -d '{}' | awk -F', ' '{printf "%d", $3}')"
say "restoring afterwards: ${ORIGINAL_WIDTH}pt wide, '$ORIGINAL_STYLE' waveform"

for s in "${SHOTS[@]}"; do
    case "$s" in
        player) shot_player ;;
        playlist) shot_playlist ;;
        pitch) shot_pitch ;;
    esac
done

# Put the persisted state back and quit — best effort, hence no assertions:
# the shots are already written, and nothing here is worth failing the run for.
if [ -n "$(pgrep -x Vibe || true)" ]; then
    ensure_pitch 0
    ensure_playlist 0
    if [ -n "$ORIGINAL_STYLE" ]; then
        quiet dump_menu   # builds the delegate submenu so the title resolves
        quiet click_menu "$ORIGINAL_STYLE" || true
    fi
    if [ "$ORIGINAL_WIDTH" -gt 0 ]; then
        ensure_body_width "$ORIGINAL_WIDTH"
    fi
    quiet sleep 0.5
fi
quit_app
say "done — $OUT_DIR ($APPEARANCE appearance)"
