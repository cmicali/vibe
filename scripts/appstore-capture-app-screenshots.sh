#!/bin/bash
# Mac App Store screenshots taken for real: the app, playing, photographed over
# a staged background and composited at 2880x1800. The usual path is
# appstore-generate-store-screenshots.sh, which composites the README captures
# larger.
#
#   scripts/appstore-capture-app-screenshots.sh <background ...> [shot ...]
#
#   player    playlist and pitch panel hidden, transport buttons hidden
#   playlist  playlist open, transport buttons showing
#   pitch     pitch panel open, Sonic Cirrus waveform, transport buttons showing
#
# No shot names means all three, each playing with the playhead at $SEEK. Pass
# one background for every shot, or three in the order above (`<bg1> <bg2>
# <bg3> pitch` redoes the pitch shot on bg3): leading arguments that are
# existing files are backgrounds, the rest shot names. Any aspect ratio is
# aspect-filled and centred.
#
# Staged because the Liquid Glass (Clear style) shows the desktop nearly
# directly: what is behind the window must BE the background, at the output's
# scale and alignment. So the canvas is drawn on screen (backdrop.swift --rect)
# exactly where the window will sit in the output, then the window is
# photographed over it.
#
# Needs a debug build, Screen Recording and Accessibility permission and
# ALLOW_GLOBAL_INPUT=1 (screenshots/screenshot-lib.sh); takes over the pointer
# and covers the screen while it runs. Audio stays off the hardware (launch.sh's
# default). Track paths are hardcoded: an authoring tool, not a test. Pins the
# window appearance to $APPEARANCE (default dark); restores the body width and
# waveform style it found.
set -euo pipefail

# shellcheck source=scripts/screenshots/screenshot-lib.sh
source "$(dirname "$0")/screenshots/screenshot-lib.sh"

OUT_DIR="${OUT_DIR:-$ROOT/Assets/app-store/screenshots/en/macos}"
APPEARANCE="${APPEARANCE:-dark}"

# ASC's other 16:10 macOS sizes (2560x1600, 1440x900) work unchanged: the
# window is placed by fraction.
CANVAS_W="${CANVAS_W:-2880}"
CANVAS_H="${CANVAS_H:-1800}"

# Body width in points, pitch panel excluded. 900pt is 1800px at 2x, 62.5% of
# the canvas, so SCALE=1 resamples nothing.
BODY_WIDTH="${BODY_WIDTH:-900}"
SCALE="${SCALE:-1}"

# The window's position as a fraction of the free space on each axis (0.5
# centres). Shared by every shot, so shots of different heights share a centre.
POS_X="${POS_X:-0.5}"
POS_Y="${POS_Y:-0.5}"

MUSIC="$HOME/Library/CloudStorage/Dropbox/music/Tracks"
TRACK_PLAYER="$MUSIC/2020-03/Move D - Dots.aiff"
TRACK_PITCH="$MUSIC/2026-05/Silat Beksi - Shushu.flac"
# Opened only so the next button draws enabled. The shot walks to TRACK_PITCH,
# which is never last however Launch Services orders the batch.
TRACK_PITCH_EXTRAS=(
    "$MUSIC/2026-05/Steve O'Sullivan - Tribal Dub (Original Mix).flac"
    "$MUSIC/2026-05/Talismantra - Warmth Reheated.flac"
)
FOLDER="$MUSIC/2026-05"
FOLDER_TRACK="The Mountain People - Memorandum.flac"

# Playhead position as a fraction of the track. The track keeps playing, so the
# seek aims SHUTTER_LEAD seconds early to cover the capture itself.
SEEK="${SEEK:-0.40}"
SHUTTER_LEAD="${SHUTTER_LEAD:-2.5}"
# Pitch fader, in percent.
PITCH="${PITCH:-0}"

# Renderer +styleIdentifier values, not the localized +displayName.
STYLE_DEFAULT="${STYLE_DEFAULT:-oversampling_detailed_x4}"
STYLE_PITCH="${STYLE_PITCH:-sonic_cirrus}"

# Seconds for the folder's metadata scan: ~30s for 67 files cold off Dropbox,
# near-instant with a warm cache.
SCAN_WAIT="${SCAN_WAIT:-30}"

# --- setup ------------------------------------------------------------------

usage() {
    echo "usage: $(basename "$0") <background-image> [bg2 bg3] [player|playlist|pitch ...]" >&2
    exit 64
}

# Absolute, because the compositor and backdrop.swift run from elsewhere.
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
require_global_input
require_debug_build
mkdir -p "$OUT_DIR"
pkill -x Vibe 2>/dev/null && sleep 1 || true
quiet set_appearance "$APPEARANCE"

# --- geometry ---------------------------------------------------------------

# Captures are in pixels, window rects in points. Measured off a real capture
# (its opaque box IS the window rect) rather than assuming 2x.
BACKING=""
measure_backing_scale() {
    local w box
    read -r _ _ _ _ w _ <<<"$(win_geom)"
    capture_window "$SHOT_TMP/measure.png"
    box=$(swift "$SCREENSHOT_DIR/compose-window-shot.swift" --info "$SHOT_TMP/measure.png" \
            | awk '{print $4}' | cut -dx -f1)
    BACKING=$(awk -v box="$box" -v w="$w" 'BEGIN{printf "%.6f", box / w}')
    say "display backing scale: ${BACKING}x (${w}pt window captured ${box}px wide)"
}

# Where the window lands on the canvas, and where the canvas must be drawn on
# screen so the pixels behind the window are its own. Sets DEST_X/Y/W (canvas
# pixels) and RECT_* (screen points, for backdrop.swift --rect), both
# top-left origin.
plan_geometry() {
    local x y w h
    read -r _ _ x y w h <<<"$(win_geom)"
    eval "$(awk -v x="$x" -v y="$y" -v w="$w" -v h="$h" -v b="$BACKING" -v s="$SCALE" \
                -v cw="$CANVAS_W" -v ch="$CANVAS_H" -v px="$POS_X" -v py="$POS_Y" 'BEGIN{
        ppp = b * s;                          # canvas pixels per screen point
        dw = w * ppp; dh = h * ppp;
        dx = int((cw - dw) * px + 0.5); dy = int((ch - dh) * py + 0.5);
        printf "DEST_X=%d\nDEST_Y=%d\nDEST_W=%d\n", dx, dy, int(dw + 0.5);
        # Shifted so canvas (dx,dy) lands on the window top-left. Parts may
        # fall off screen; only the part behind the window is photographed.
        printf "RECT_X=%.2f\nRECT_Y=%.2f\nRECT_W=%.2f\nRECT_H=%.2f\n",
               x - dx / ppp, y - dy / ppp, cw / ppp, ch / ppp;
    }')"
}

# Call BEFORE placing the cursor: the backdrop orders itself front, which
# pulls the cursor out of the app's tracking area and hides the transport
# buttons.
stage_for_capture() {
    [ -n "$BACKING" ] || measure_backing_scale
    plan_geometry
    say "staging the background (covers the screen until this finishes)"
    # --no-reassert: a late re-order would put the backdrop back over the
    # window being photographed.
    start_backdrop --no-reassert --rect "$RECT_X" "$RECT_Y" "$RECT_W" "$RECT_H" "$BACKGROUND"
    raise_over_backdrop
}

# Fatal, not a warning: under the backdrop the window photographs as a
# window-shaped hole.
raise_over_backdrop() {
    activate_vibe || {
        echo "error: Vibe never came to the front — the capture would photograph" \
             "the staged backdrop instead of the window" >&2
        exit 1
    }
}

# The seek comes after staging, which takes seconds while the track plays.
capture_app_store_shot() { # <output-name>
    local out="$OUT_DIR/$1"
    raise_over_backdrop
    seek_fraction "$SEEK" "$SHUTTER_LEAD"
    capture_merged "$SHOT_TMP/merged.png"
    swift "$SCREENSHOT_DIR/compose-app-store-shot.swift" \
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

# Record the persisted style and width this run overwrites. Only a running app
# can report them; the pitch panel goes first so the frame width IS the body
# width.
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

# Best effort: the shots are written, so nothing here fails the run.
if [ -n "$(pgrep -x Vibe || true)" ]; then
    ensure_pitch 0
    ensure_playlist 0
    if [ -n "$ORIGINAL_STYLE" ]; then
        quiet dump_menu   # builds the delegate submenu so the item resolves
        quiet click_menu "waveform_style_$ORIGINAL_STYLE" || true
        if [ "$(state | jq -r .settings.waveformStyle)" != "$ORIGINAL_STYLE" ]; then
            echo "warning: waveform style left as" \
                 "'$(state | jq -r .settings.waveformStyle)' — could not restore" \
                 "'$ORIGINAL_STYLE'" >&2
        fi
    fi
    if [ "$ORIGINAL_WIDTH" -gt 0 ]; then
        ensure_body_width "$ORIGINAL_WIDTH"
    fi
    quiet sleep 0.5
fi
quit_app
say "done — $OUT_DIR ($APPEARANCE appearance)"
