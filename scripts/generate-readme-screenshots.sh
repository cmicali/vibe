#!/bin/bash
# Regenerate the README window captures in Assets/, which the App Store and
# web images are also derived from.
#
#   scripts/generate-readme-screenshots.sh [shot ...]     # no args = all five
#   shot names: basic pitch themes playlist playlist-pitch
#
# Needs a debug build, Screen Recording and Accessibility permission and
# ALLOW_GLOBAL_INPUT=1 (screenshots/screenshot-lib.sh); moves the real pointer
# and leaves it parked outside the window. Audio stays off the hardware
# (launch.sh's default). Track paths are hardcoded: an authoring tool, not a
# test. Pins the window appearance to $APPEARANCE (default dark), waveform
# normalization on and the pitch range at 8%, and quits with the playlist and
# pitch panel hidden and the theme back at `vibe`.
set -euo pipefail

# shellcheck source=scripts/screenshots/screenshot-lib.sh
source "$(dirname "$0")/screenshots/screenshot-lib.sh"

OUT_DIR="${OUT_DIR:-$ROOT/Assets}"
APPEARANCE="${APPEARANCE:-dark}"
# window (default) | merged | region — see capture().
CAPTURE="${CAPTURE:-window}"
# region only: points of screen kept around the window.
MARGIN="${MARGIN:-40}"
# Stage backdrop.swift behind the window: on by default for `merged`, whose
# glass shows what is behind it. BACKDROP=0 keeps the real screen.
BACKDROP="${BACKDROP:-$([ "$CAPTURE" = merged ] && echo 1 || echo 0)}"
# The on-screen window captured and redrawn full-screen behind Vibe: an
# owning-app name (case-insensitive substring) or "wallpaper", the fallback.
# WHATEVER IT SHOWS bleeds through the glass and the playlist frost, so look
# before publishing. BACKDROP_IMAGE uses a file instead.
BACKDROP_WINDOW="${BACKDROP_WINDOW:-IntelliJ IDEA}"
BACKDROP_IMAGE="${BACKDROP_IMAGE:-}"
# Last resort: gradient stops, corner to corner. Keep it dark and desaturated;
# a loud one bleeds through the header glass and fights the album-art tint.
BACKDROP_COLORS="${BACKDROP_COLORS:-1B1A6E 4A3AC8}"

# Built-in theme identifiers: the Resources/Themes/ file stems.
#
# TRAP: a theme is a persisted setting, so it outlives the app. Every shot sets
# its own and the end of the run restores `vibe`, but a run that dies in
# between leaves the app themed: `Vibe --debug-cmd set_theme vibe` resets it.
THEME_BASIC="${THEME_BASIC:-vibe}"
THEME_PLAYLIST="${THEME_PLAYLIST:-snake}"
THEME_THEMES="${THEME_THEMES:-sonic_cirrus}"
THEME_PLAYLIST_PITCH="${THEME_PLAYLIST_PITCH:-technical}"
THEME_PITCH="${THEME_PITCH:-record_bin}"

# Every capture is sized explicitly: the autosaved frame differs between a
# single-file and a folder launch. These are the published sizes; changing one
# re-crops that store screenshot. The body width excludes the pitch panel, so
# the pitch shots are wider by the panel. 150 is kMainWindowSmallHeight.
BODY_WIDTH="${BODY_WIDTH:-680}"
HEIGHT_COMPACT="${HEIGHT_COMPACT:-150}"
HEIGHT_PLAYLIST="${HEIGHT_PLAYLIST:-400}"

MUSIC="$HOME/Library/CloudStorage/Dropbox/music/Tracks"
TRACK_BASIC="$MUSIC/2026-04/Jasper Tygner - Kashmer.flac"
# Opened only so the next button draws enabled. All sort after Kashmer, so it
# is never last however Launch Services orders the batch.
TRACK_BASIC_EXTRAS=(
    "$MUSIC/2026-04/Justin Jay, Eva - Do I Like You Like That.flac"
    "$MUSIC/2026-04/Louis The 4th - Ritual Issues.flac"
    "$MUSIC/2026-04/Omni A.M. - Vanilla Chinchilla (Terry Francis Remix).flac"
)
TRACK_PITCH="$MUSIC/2026-05/Silat Beksi - Shushu.flac"
FOLDER="$MUSIC/2026-05"
FOLDER_TRACK_PLAYLIST="The Mountain People - Memorandum.flac"
FOLDER_TRACK_PITCH="Steve O'Sullivan - No Aura (Original Mix).aiff"
FOLDER_TRACK_THEMES="DJ Tennis Carlita - Trouble Symphony.flac"

# Playhead position as a fraction of the track. SEEK_PITCH is mid-way through
# the full section after Shushu's breakdown (0.48-0.56).
SEEK_BASIC=0.40
SEEK_PITCH=0.64
SEEK_FOLDER=0.40

# Seconds for the folder's metadata scan: ~30s for 67 files cold off Dropbox,
# near-instant with a warm cache.
SCAN_WAIT="${SCAN_WAIT:-30}"

# --- setup ------------------------------------------------------------------

# The factory values of two settings the shots show, so a capture never
# carries its author's own: normalization fills the waveform's height, and the
# fader reads ±8. Neither has a channel verb, so this drives the Settings
# window; the switch sits behind a disclosure, and clicking an open one would
# close it.
pin_settings_defaults() {
    quiet settings_open appearance
    if [ "$("$V" --debug-cmd dump_settings_ui \
            | jq -r '.controls[] | select(.name == "Normalize waveform") | .hidden')" = true ]; then
        quiet settings_click Waveform
    fi
    quiet settings_click "Normalize waveform" on
    quiet settings_open playback
    quiet settings_click 8%
    quiet settings_close
}

[ "$#" -gt 0 ] && SHOTS=("$@") || SHOTS=(basic pitch themes playlist playlist-pitch)

for f in "$TRACK_BASIC" "${TRACK_BASIC_EXTRAS[@]}" "$TRACK_PITCH" "$FOLDER"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

trap screenshot_cleanup EXIT INT TERM
require_global_input
require_debug_build
mkdir -p "$OUT_DIR"
pkill -x Vibe 2>/dev/null && sleep 1 || true
# TRAP: --debug-cmd needs a RUNNING app and the pkill just ended it, so the
# appearance pin needs this launch; without it the command times out and the
# run exits.
launch
quiet set_appearance "$APPEARANCE"
pin_settings_defaults

if [ "$BACKDROP" = 1 ]; then
    if [ -z "$BACKDROP_IMAGE" ]; then
        BACKDROP_ID="$(swift "$SCREENSHOT_DIR/backdrop-window-id.swift" \
                "$BACKDROP_WINDOW" 2>/dev/null || true)"
        if [ -z "$BACKDROP_ID" ] && [ "$BACKDROP_WINDOW" != wallpaper ]; then
            echo "warning: no '$BACKDROP_WINDOW' window on screen — using the wallpaper" >&2
            BACKDROP_ID="$(swift "$SCREENSHOT_DIR/backdrop-window-id.swift" \
                    wallpaper 2>/dev/null || true)"
        fi
        if [ -n "$BACKDROP_ID" ] \
                && screencapture -x -l"$BACKDROP_ID" "$SHOT_TMP/backdrop.png" 2>/dev/null \
                && [ -s "$SHOT_TMP/backdrop.png" ]; then
            BACKDROP_IMAGE="$SHOT_TMP/backdrop.png"
        else
            echo "warning: no backdrop window captured — falling back to a gradient" >&2
        fi
    fi
    say "staging the backdrop (covers the screen until this finishes)"
    if [ -n "$BACKDROP_IMAGE" ]; then
        start_backdrop "$BACKDROP_IMAGE"
    else
        # shellcheck disable=SC2086 # intentional word split: one arg per stop
        start_backdrop $BACKDROP_COLORS
    fi
fi

# --- capture ----------------------------------------------------------------

# The three paths do NOT produce the same picture. `window` and `merged` are
# screenshot-lib.sh's capture_window and capture_merged. `region` is the
# composited screen over the window rect plus $MARGIN: real translucency, but
# no alpha or shadow, and WHATEVER IS ON SCREEN around the window.
capture() { # <output-name>
    local out="$OUT_DIR/$1" x y w h
    activate_vibe || echo "warning: Vibe window is not key — glass may look dimmed" >&2
    case "$CAPTURE" in
        window)
            capture_window "$out"
            ;;
        region)
            read -r _ _ x y w h <<<"$(win_geom)"
            x=$(( x - MARGIN )); [ "$x" -lt 0 ] && x=0 || true
            y=$(( y - MARGIN )); [ "$y" -lt 0 ] && y=0 || true
            screencapture -x -R"$x,$y,$(( w + 2 * MARGIN )),$(( h + 2 * MARGIN ))" "$out"
            ;;
        merged)
            capture_merged "$out"
            ;;
        *)
            echo "CAPTURE must be window, region or merged (got '$CAPTURE')" >&2
            exit 64
            ;;
    esac
    say "wrote $out ($(png_size "$out")px)"
}

# --- shots ------------------------------------------------------------------

shot_basic() {
    say "basic: Kashmer, playing at $SEEK_BASIC, transport buttons hovered, $THEME_BASIC theme"
    launch "$TRACK_BASIC" "${TRACK_BASIC_EXTRAS[@]}"
    ensure_playlist 0
    ensure_pitch 0
    ensure_body_width "$BODY_WIDTH" "$HEIGHT_COMPACT"
    quiet set_theme "$THEME_BASIC"
    # Launch Services picks which of the batch plays first.
    play_track "$(basename "$TRACK_BASIC")"
    wait_loaded
    seek_fraction "$SEEK_BASIC"
    cursor_hover_window
    capture screenshot-basic.png
}

shot_pitch() {
    say "pitch: Shushu, pitch panel at 0%, playing at $SEEK_PITCH, $THEME_PITCH theme"
    launch "$TRACK_PITCH"
    ensure_playlist 0
    ensure_pitch 1
    quiet set_pitch 0
    ensure_body_width "$BODY_WIDTH" "$HEIGHT_COMPACT"
    quiet set_theme "$THEME_PITCH"
    cursor_out
    wait_loaded
    seek_fraction "$SEEK_PITCH"
    capture screenshot-pitch.png
}

# The folder shots share one launch and one metadata scan, the slow part.
shot_folder() { # <pitch 0|1> <track basename> <output> <theme>
    cursor_out
    ensure_playlist 1
    ensure_pitch "$1"
    if [ "$1" = 1 ]; then quiet set_pitch 0; fi
    ensure_body_width "$BODY_WIDTH" "$HEIGHT_PLAYLIST"
    quiet set_theme "$4"
    center_on_track "$2"
    wait_loaded
    seek_fraction "$SEEK_FOLDER"
    select_playing_row
    capture "$3"
}

# A folder shot: on a single track the playlist panel is one row and empty
# grey.
shot_themes() {
    say "themes: 2026-05 folder, Trouble Symphony, $THEME_THEMES theme"
    shot_folder 0 "$FOLDER_TRACK_THEMES" screenshot-themes.png "$THEME_THEMES"
}

shot_playlist() {
    say "playlist: 2026-05 folder, Memorandum, $THEME_PLAYLIST theme"
    shot_folder 0 "$FOLDER_TRACK_PLAYLIST" screenshot-playlist.png "$THEME_PLAYLIST"
}

shot_playlist_pitch() {
    say "playlist+pitch: 2026-05 folder, No Aura, $THEME_PLAYLIST_PITCH theme"
    shot_folder 1 "$FOLDER_TRACK_PITCH" screenshot-playlist-pitch.png "$THEME_PLAYLIST_PITCH"
}

# --- run --------------------------------------------------------------------

needs_folder=no
for s in "${SHOTS[@]}"; do
    case "$s" in themes|playlist|playlist-pitch) needs_folder=yes ;; esac
done

for s in "${SHOTS[@]}"; do
    case "$s" in
        basic) shot_basic ;;
        pitch) shot_pitch ;;
        themes|playlist|playlist-pitch) ;;  # handled together below
        *) echo "unknown shot: $s (basic|pitch|themes|playlist|playlist-pitch)" >&2; exit 64 ;;
    esac
done

if [ "$needs_folder" = yes ]; then
    say "opening $FOLDER (waiting ${SCAN_WAIT}s for the metadata scan)"
    launch "$FOLDER"
    ensure_playlist 1
    quiet sleep "$SCAN_WAIT"
    for s in "${SHOTS[@]}"; do
        case "$s" in
            themes) shot_themes ;;
            playlist) shot_playlist ;;
            playlist-pitch) shot_playlist_pitch ;;
        esac
    done
fi

ensure_pitch 0
ensure_playlist 0
quiet set_theme vibe
quiet sleep 0.5
quit_app
say "done — app appearance left pinned to $APPEARANCE"
