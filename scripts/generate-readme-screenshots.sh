#!/bin/bash
# Regenerate the README screenshots in Assets/.
#
#   scripts/generate-readme-screenshots.sh [shot ...]     # no args = all five
#   shot names: basic pitch themes playlist playlist-pitch
#
# The App Store shots (2880x1800, composited onto a background image) are a
# separate tool: scripts/appstore-capture-app-screenshots.sh. Both share
# scripts/screenshots/screenshot-lib.sh, which documents the two permissions
# this terminal needs (Screen Recording, Accessibility) and the debug build
# requirement.
#
# It moves the mouse cursor around and leaves it parked outside the window.
#
# Track paths are hardcoded below — this is a one-off authoring tool, not a
# test. Audio is off-hardware (--no-audio-hw --silent, via launch.sh) throughout.
#
# Side effects: pins the app's window appearance to $APPEARANCE (default dark)
# so the shots match, and leaves the autosaved window frame wherever the last
# shot left it. The app is quit at the end with the playlist and pitch panel
# hidden again.
set -euo pipefail

# shellcheck source=scripts/screenshots/screenshot-lib.sh
source "$(dirname "$0")/screenshots/screenshot-lib.sh"

OUT_DIR="${OUT_DIR:-$ROOT/Assets}"
APPEARANCE="${APPEARANCE:-dark}"
# window (default) | merged | region — see capture().
CAPTURE="${CAPTURE:-window}"
# region only: points of screen kept around the window.
MARGIN="${MARGIN:-40}"
# Stage backdrop.swift behind the window — on by default for `merged`,
# whose whole point is that the glass shows what is behind it. BACKDROP=0 to use
# whatever is already on screen; BACKDROP=1 to force it on for the other paths.
BACKDROP="${BACKDROP:-$([ "$CAPTURE" = merged ] && echo 1 || echo 0)}"
# Which on-screen window gets copied behind Vibe: an owning-app name (matched as
# a case-insensitive substring), or "wallpaper" for the desktop picture. It is
# captured once and redrawn full-screen by backdrop.swift, so the shots look like
# Vibe sitting on top of that window without anything else being in the way.
# WHATEVER THAT WINDOW IS SHOWING bleeds through the glass and the playlist
# frost — look at it before publishing the shots. Falls back to the wallpaper if
# no such window is on screen. BACKDROP_IMAGE overrides with a file instead.
BACKDROP_WINDOW="${BACKDROP_WINDOW:-IntelliJ IDEA}"
BACKDROP_IMAGE="${BACKDROP_IMAGE:-}"
# Last-resort fallback: gradient stops, corner to corner. Keep a backdrop dark
# and desaturated — a loud one bleeds through the header glass strongly enough to
# fight the album-art tint, by an amount that depends on where on screen the
# window happens to sit.
BACKDROP_COLORS="${BACKDROP_COLORS:-1B1A6E 4A3AC8}"

# One theme per App Store shot, so the four-shot set shows the theme system off
# without any single shot having to be about it. Values are built-in theme
# IDENTIFIERS, which are the Resources/Themes/ file stems (AppTheme.m) — the
# debug channel's set_theme also accepts the display name.
#
# TRAP: a theme is a persisted setting, not window state, so it outlives the
# app. Every shot sets its own and the cleanup at the bottom restores `vibe`;
# a run that dies in between leaves the app themed, and the NEXT run's first
# shot is captured under whatever was left until its own set_theme lands.
# `Vibe --debug-cmd set_theme vibe` resets it by hand.
THEME_BASIC="${THEME_BASIC:-vibe}"
THEME_PLAYLIST="${THEME_PLAYLIST:-snake}"
THEME_THEMES="${THEME_THEMES:-sonic_cirrus}"
THEME_PLAYLIST_PITCH="${THEME_PLAYLIST_PITCH:-technical}"
# README-only — not part of the App Store set, so it keeps the default.
THEME_PITCH="${THEME_PITCH:-vibe}"

# The window is sized explicitly before every capture. It used to inherit
# whatever frame was autosaved, so the same shot came out 1214px wide after a
# single-file launch and 1452px after a folder one, and the App Store set ended
# up carrying four different widths. These are the sizes the published shots
# have; changing one re-crops that store screenshot.
#
# Body width EXCLUDES the pitch panel (ensure_body_width), which is why the
# compact and pitch shots share a number. Heights are the window's own: 150 is
# kMainWindowSmallHeight, the collapsed floor.
# ONE body width for every shot — the published set has always been 680pt,
# and the pitch shots are wider only because the panel adds to it. Heights are
# the window's own: 150 is kMainWindowSmallHeight, the collapsed floor.
BODY_WIDTH="${BODY_WIDTH:-680}"
HEIGHT_COMPACT="${HEIGHT_COMPACT:-150}"
HEIGHT_PLAYLIST="${HEIGHT_PLAYLIST:-400}"

MUSIC="$HOME/Library/CloudStorage/Dropbox/music/Tracks"
TRACK_BASIC="$MUSIC/2026-04/Jasper Tygner - Kashmer.flac"
# Opened alongside TRACK_BASIC purely so the playlist has a next track and the
# next button draws enabled. All sort AFTER Kashmer, so it can never end up
# last however Launch Services orders the batch.
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

# Fraction of the track the playhead sits at in each shot.
SEEK_BASIC=0.40
SEEK_PITCH=0.35
SEEK_FOLDER=0.40

# Seconds to let the playlist metadata scan (artwork, titles, durations)
# finish before capturing a folder shot. Cold, off Dropbox, 67 files takes
# ~30s; a warm metadata cache is near-instant.
SCAN_WAIT="${SCAN_WAIT:-30}"

# --- setup ------------------------------------------------------------------

[ "$#" -gt 0 ] && SHOTS=("$@") || SHOTS=(basic pitch themes playlist playlist-pitch)

for f in "$TRACK_BASIC" "${TRACK_BASIC_EXTRAS[@]}" "$TRACK_PITCH" "$FOLDER"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

trap screenshot_cleanup EXIT INT TERM
require_global_input
require_debug_build
mkdir -p "$OUT_DIR"
pkill -x Vibe 2>/dev/null && sleep 1 || true
# TRAP: --debug-cmd talks to a RUNNING app, and the pkill above just ended it,
# so the appearance pin needs its own launch. Appearance and theme are both
# persisted settings rather than window state, which is why they are pinned
# once here instead of per shot — but that is also what makes it easy to
# forget they need the app up to be written at all.
launch
quiet set_appearance "$APPEARANCE"

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

# Three capture paths, and they do NOT produce the same picture — `window` and
# `merged` are screenshot-lib.sh's capture_window/capture_merged (which document
# what each buffer does and doesn't carry), plus:
#
#   region — screencapture -R over the window's rect plus $MARGIN. The truly
#       composited screen, so the translucency shows what is behind. Costs the
#       alpha channel and the shadow, and it captures WHATEVER IS ON SCREEN
#       around the window.
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
    # Launch Services decides which of the batch plays first, so walk to the
    # one this shot is about.
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

# The two folder shots share one launch: opening 67 files off Dropbox and
# waiting out the metadata scan is the slow part, and the scan result is the
# same for both.
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

# A FOLDER shot, not a single-file one: opened on one track the playlist panel
# is a row and then half a frame of empty grey, which is no advertisement for
# anything. It shares the folder launch with the two below.
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

# Leave the autosaved window state small again and the theme back at the
# default, then quit. The theme is persisted, so skipping this would leave the
# app wearing whichever shot ran last.
ensure_pitch 0
ensure_playlist 0
quiet set_theme vibe
quiet sleep 0.5
quit_app
say "done — app appearance left pinned to $APPEARANCE"
