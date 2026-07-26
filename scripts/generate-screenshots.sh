#!/bin/bash
# Regenerate the README screenshots in Assets/.
#
#   scripts/generate-screenshots.sh [shot ...]     # no args = all four
#   shot names: basic pitch playlist playlist-pitch
#
# Needs a DEBUG build (the --debug-cmd channel drives the app) plus two
# permissions for this terminal:
#   Screen Recording  — the shots must be REAL screen captures, because the
#                       in-process snapshot path cannot render the Liquid Glass
#                       chrome (see .claude/skills/vibe-debug).
#   Accessibility     — revealing the transport buttons needs real cursor
#                       motion (CGEvents); nothing else can drive a hover.
#
# It moves the mouse cursor around and leaves it parked outside the window.
#
# Track paths are hardcoded below — this is a one-off authoring tool, not a
# test. Audio is muted (--silent) throughout.
#
# Side effects: pins the app's window appearance to $APPEARANCE (default dark)
# so the shots match, and leaves the autosaved window frame wherever the last
# shot left it. The app is quit at the end with the playlist and pitch panel
# hidden again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/.claude/skills/vibe-debug/scripts"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"
OUT_DIR="${OUT_DIR:-$ROOT/Assets}"
APPEARANCE="${APPEARANCE:-dark}"
# window (default) | merged | region — see capture().
CAPTURE="${CAPTURE:-window}"
# region only: points of screen kept around the window.
MARGIN="${MARGIN:-40}"
# Stage scripts/backdrop.swift behind the window — on by default for `merged`,
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

# Fraction of the track the playhead sits at in each shot.
SEEK_BASIC=0.40
SEEK_PITCH=0.35
SEEK_FOLDER=0.40

# Rows the playing track sits above the bottom of the visible list — see
# center_on_track(). ~9 rows fit, so 4 puts it mid-list.
CENTER_OFFSET=4
# Seconds to let the playlist metadata scan (artwork, titles, durations)
# finish before capturing a folder shot. Cold, off Dropbox, 67 files takes
# ~30s; a warm metadata cache is near-instant.
SCAN_WAIT="${SCAN_WAIT:-30}"
# Waveform morph + progress settle before the shutter.
SETTLE=2.5

quiet() { "$V" --debug-cmd "$@" >/dev/null; }
state() { "$V" --debug-cmd dump_state; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# --- setup ------------------------------------------------------------------

[ "$#" -gt 0 ] && SHOTS=("$@") || SHOTS=(basic pitch playlist playlist-pitch)

for f in "$TRACK_BASIC" "${TRACK_BASIC_EXTRAS[@]}" "$TRACK_PITCH" "$FOLDER"; do
    [ -e "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

if [ -z "${VIBE_SKIP_BUILD:-}" ]; then
    say "building Debug"
    "$ROOT/scripts/build.sh" Debug >/dev/null
fi
[ -x "$V" ] || { echo "no debug build at $APP" >&2; exit 1; }

mkdir -p "$OUT_DIR"
TMP="$(mktemp -d)"
BACKDROP_PID=""
cleanup() {
    [ -n "$BACKDROP_PID" ] && kill "$BACKDROP_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT
pkill -x Vibe 2>/dev/null && sleep 1 || true
quiet set_appearance "$APPEARANCE"

if [ "$BACKDROP" = 1 ]; then
    if [ -z "$BACKDROP_IMAGE" ]; then
        BACKDROP_ID="$(swift "$ROOT/scripts/backdrop-window-id.swift" \
                "$BACKDROP_WINDOW" 2>/dev/null || true)"
        if [ -z "$BACKDROP_ID" ] && [ "$BACKDROP_WINDOW" != wallpaper ]; then
            echo "warning: no '$BACKDROP_WINDOW' window on screen — using the wallpaper" >&2
            BACKDROP_ID="$(swift "$ROOT/scripts/backdrop-window-id.swift" \
                    wallpaper 2>/dev/null || true)"
        fi
        if [ -n "$BACKDROP_ID" ] \
                && screencapture -x -l"$BACKDROP_ID" "$TMP/backdrop.png" 2>/dev/null \
                && [ -s "$TMP/backdrop.png" ]; then
            BACKDROP_IMAGE="$TMP/backdrop.png"
        else
            echo "warning: no backdrop window captured — falling back to a gradient" >&2
        fi
    fi
    say "staging the backdrop (covers the screen until this finishes)"
    if [ -n "$BACKDROP_IMAGE" ]; then
        swift "$ROOT/scripts/backdrop.swift" "$BACKDROP_IMAGE" &
    else
        # shellcheck disable=SC2086 # intentional word split: one arg per stop
        swift "$ROOT/scripts/backdrop.swift" $BACKDROP_COLORS &
    fi
    BACKDROP_PID=$!
    sleep 5   # swift compiles the script before the window appears
fi

# --- helpers ----------------------------------------------------------------

# Wait until the current track's duration is known (the open + header metadata
# have landed), then let the waveform settle.
wait_loaded() {
    for _ in $(seq 1 60); do
        if [ "$(state | jq -r '.player.duration > 0')" = true ]; then break; fi
        quiet sleep 0.5
    done
    quiet sleep "$SETTLE"
}

seek_fraction() { # <fraction>
    local dur
    dur=$(state | jq -r .player.duration)
    quiet seek "$(awk -v d="$dur" -v f="$1" 'BEGIN{printf "%.2f", d*f}')"
    quiet sleep 1
}

# Put a panel in the wanted state ($2 = 0|1). Already-there is NOT a no-op: the
# restored autosaved window frame can disagree with the persisted shown/hidden
# setting (killing the app loses its last frame write), which leaves e.g. a
# tall window with the playlist "hidden". Round-tripping the toggle makes the
# layout set the frame explicitly, so the geometry always matches the state.
ensure_panel() { # <toggle-verb> <0|1> <state-key>
    local verb=$1 want=$2 key=$3
    if [ "$(state | jq -r --arg k "$key" 'if .window[$k] then 1 else 0 end')" = "$want" ]; then
        quiet "$verb"
        quiet sleep 0.3
    fi
    quiet "$verb"
    quiet sleep 0.3
}
ensure_playlist() { ensure_panel toggle_size "$1" playlistShown; }
ensure_pitch() { ensure_panel toggle_pitch_panel "$1" pitchPanelShown; }

playlist_index() { # <basename> -> 0-based index in the loaded playlist
    state | jq -r --arg n "$1" '.playlist.files | index($n) // empty'
}

# Walk the playlist with next/previous, one command per step, in a single
# script so the whole run is one channel round-trip per line.
step_to() { # <from> <to>
    local from=$1 to=$2 verb=next n
    if [ "$from" -eq "$to" ]; then return 0; fi
    n=$(( to - from ))
    if [ "$n" -lt 0 ]; then verb=previous; n=$(( -n )); fi
    for _ in $(seq 1 "$n"); do echo "$verb"; done \
        | "$V" --debug-cmd script - >/dev/null
}

# Land on <basename> with its row mid-list instead of jammed against the
# bottom edge: every track change scrolls the playing row into view, so walk
# PAST the target first (that scrolls the row CENTER_OFFSET below it to the
# bottom), then step back up — the target is already visible by then, so the
# list doesn't scroll again.
center_on_track() { # <basename>
    local name=$1 target count via cur
    target=$(playlist_index "$name")
    [ -n "$target" ] || { echo "not in playlist: $name" >&2; exit 1; }
    count=$(state | jq -r .playlist.count)
    via=$(( target + CENTER_OFFSET ))
    if [ "$via" -gt $(( count - 1 )) ]; then via=$(( count - 1 )); fi
    cur=$(state | jq -r .playlist.currentIndex)
    step_to "$cur" "$via"
    quiet sleep 0.5
    step_to "$via" "$target"
}

# --- cursor -----------------------------------------------------------------
#
# The transport/traffic-light buttons are revealed by a window-wide
# NSTrackingArea, and tracking areas are driven by the window server — posted
# NSEvents (--debug-cmd mouse_move) never reach them, so hovering means moving
# the REAL cursor with CGEvents. Enter/exit fire on boundary crossings only,
# hence the always-leave-first dance.

win_geom() { swift "$SKILL/find-window.swift" "$(pgrep -x Vibe | head -1)" | head -1; }

cursor_to() { # <global-x> <global-y>
    swift "$SKILL/input.swift" move "$1" "$2"
    quiet sleep 0.3
}

# Park the cursor clear of the window, left of it (or right, if the window is
# too close to the screen edge) — this is what hides the transport buttons.
cursor_out() {
    local x y w h out
    read -r _ _ x y w h <<<"$(win_geom)"
    out=$(( x - 60 ))
    if [ "$out" -lt 0 ]; then out=$(( x + w + 60 )); fi
    cursor_to "$out" "$(( y + h / 2 ))"
}

# Reveal the buttons: out first (so there IS a crossing), then onto the title
# row — a neutral spot, so every button draws in its normal, non-hover color.
cursor_hover_window() {
    local x y w h
    cursor_out
    read -r _ _ x y w h <<<"$(win_geom)"
    cursor_to "$(( x + w * 66 / 100 ))" "$(( y + 25 ))"
    quiet sleep 0.6   # the reveal is a fade (kControlFadeDur)
}

# Select the playing playlist row so the shot shows the selection highlight.
# A single click selects without playing (the double-click is what plays), and
# this goes through the debug channel rather than input.swift: the channel's
# click self-activates the app and queues down+up together (safe against the
# table's mouse-tracking loop), while a CGEvent click would land in whatever
# app is frontmost at the time. It also leaves the hover state alone — posted
# events don't reach tracking areas — so the transport buttons stay hidden.
select_playing_row() {
    local pt
    pt=$(playing_row_point "$(state | jq -r .playlist.currentIndex)")
    quiet click $pt
    quiet sleep 0.5
}

# Centre of a playlist row, as "<x> <y>" in window points (top-left origin).
# NSTableView rows are uniform, and the clip view only instantiates rows it
# overlaps, so the scroll offset is pinned to within (instantiated span -
# viewport height) — a 2pt window on a 28pt row, plenty to aim a click.
playing_row_point() { # <0-based row>
    "$V" --debug-cmd dump_view_tree | python3 -c '
import json, sys

def find(node, cls):
    if node["class"] == cls:
        return node
    for child in node.get("subviews") or []:
        hit = find(child, cls)
        if hit:
            return hit
    return None

def rect(s):  # "{{0, 0}, {680, 250}}" -> [0.0, 0.0, 680.0, 250.0]
    return [float(v) for v in s.replace("{", "").replace("}", "").split(", ")]

row = int(sys.argv[1])
window = json.load(sys.stdin)["windows"][0]
_, _, _, win_h = rect(window["frame"])
scroll = find(window["contentView"], "NSScrollView")
_, sv_y, sv_w, sv_h = rect(scroll["frame"])
table = find(scroll, "PlaylistTableView")
rows = [rect(r["frame"]) for r in (table.get("subviews") or [])
        if r["class"] == "NSTableRowView"]
if not rows:
    sys.exit("no playlist rows in the view tree")
row_h = rows[0][3]
lo = min(r[1] for r in rows)
hi = max(r[1] for r in rows) + row_h
offset = (lo + (hi - sv_h)) / 2                 # scrolled-to position
top = win_h - (sv_y + sv_h)                     # scroll view top edge
print("%d %d" % (sv_w / 2, top + row * row_h + row_h / 2 - offset))
' "$1"
}

# Three capture paths, and they do NOT produce the same picture:
#
#   window (default) — screencapture -l<windowID>. Only the window's own
#       buffer, so it carries a transparent background, the real drop shadow and
#       antialiased rounded corners, sized exactly window + shadow. But its
#       glass and NSVisualEffectView materials resolved against a NEUTRAL
#       backdrop instead of the actual screen: the playlist frost renders
#       mid-gray no matter what is behind the window.
#
#   region — screencapture -R over the window's rect plus $MARGIN. The truly
#       composited screen, so the translucency shows what is behind. Costs the
#       alpha channel and the shadow, and it captures WHATEVER IS ON SCREEN
#       around the window.
#
#   merged — both, combined by compose-window-shot.swift: correct composited
#       window content, still with the transparent background, shadow and corner
#       clipping. What shows THROUGH the glass is still whatever is behind the
#       window, so stage the desktop first — otherwise the frost quietly picks
#       up the shapes of your other windows.
capture() { # <output-name>
    local out="$OUT_DIR/$1" x y w h
    osascript -e 'tell application "Vibe" to activate' 2>/dev/null || true
    quiet sleep 1
    [ "$(state | jq -r .window.keyWindow)" = true ] \
        || echo "warning: Vibe window is not key — glass may look dimmed" >&2
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
            # The region must cover EXACTLY the window rect — that is what lets
            # the compositor line the two up without guessing the (asymmetric)
            # shadow padding.
            read -r _ _ x y w h <<<"$(win_geom)"
            capture_window "$TMP/window.png"
            screencapture -x -R"$x,$y,$w,$h" "$TMP/region.png"
            swift "$ROOT/scripts/compose-window-shot.swift" \
                    "$TMP/window.png" "$TMP/region.png" "$out" >/dev/null
            ;;
        *)
            echo "CAPTURE must be window, region or merged (got '$CAPTURE')" >&2
            exit 64
            ;;
    esac
    say "wrote $out ($(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/{printf "%s ", $2}')px)"
}

capture_window() { "$SKILL/capture-window.sh" "$1" "$(pgrep -x Vibe | head -1)" >/dev/null; }

launch() { "$SKILL/launch.sh" "$@" >/dev/null; }

# --- shots ------------------------------------------------------------------

shot_basic() {
    say "basic: Kashmer, playing at $SEEK_BASIC, transport buttons hovered"
    launch "$TRACK_BASIC" "${TRACK_BASIC_EXTRAS[@]}"
    ensure_playlist 0
    ensure_pitch 0
    # Launch Services decides which of the batch plays first, so walk to the
    # one this shot is about.
    step_to "$(state | jq -r .playlist.currentIndex)" \
            "$(playlist_index "$(basename "$TRACK_BASIC")")"
    wait_loaded
    seek_fraction "$SEEK_BASIC"
    cursor_hover_window
    capture screenshot-basic.png
}

shot_pitch() {
    say "pitch: Shushu, pitch panel at 0%, playing at $SEEK_PITCH"
    launch "$TRACK_PITCH"
    ensure_playlist 0
    ensure_pitch 1
    quiet set_pitch 0
    cursor_out
    wait_loaded
    seek_fraction "$SEEK_PITCH"
    capture screenshot-pitch.png
}

# The two folder shots share one launch: opening 67 files off Dropbox and
# waiting out the metadata scan is the slow part, and the scan result is the
# same for both.
shot_folder() { # <pitch 0|1> <track basename> <output>
    cursor_out
    ensure_playlist 1
    ensure_pitch "$1"
    if [ "$1" = 1 ]; then quiet set_pitch 0; fi
    center_on_track "$2"
    wait_loaded
    seek_fraction "$SEEK_FOLDER"
    select_playing_row
    capture "$3"
}

shot_playlist() {
    say "playlist: 2026-05 folder, Memorandum"
    shot_folder 0 "$FOLDER_TRACK_PLAYLIST" screenshot-playlist.png
}

shot_playlist_pitch() {
    say "playlist+pitch: 2026-05 folder, No Aura"
    shot_folder 1 "$FOLDER_TRACK_PITCH" screenshot-playlist-pitch.png
}

# --- run --------------------------------------------------------------------

needs_folder=no
for s in "${SHOTS[@]}"; do
    case "$s" in playlist|playlist-pitch) needs_folder=yes ;; esac
done

for s in "${SHOTS[@]}"; do
    case "$s" in
        basic) shot_basic ;;
        pitch) shot_pitch ;;
        playlist|playlist-pitch) ;;  # handled together below
        *) echo "unknown shot: $s (basic|pitch|playlist|playlist-pitch)" >&2; exit 64 ;;
    esac
done

if [ "$needs_folder" = yes ]; then
    say "opening $FOLDER (waiting ${SCAN_WAIT}s for the metadata scan)"
    launch "$FOLDER"
    ensure_playlist 1
    quiet sleep "$SCAN_WAIT"
    for s in "${SHOTS[@]}"; do
        case "$s" in
            playlist) shot_playlist ;;
            playlist-pitch) shot_playlist_pitch ;;
        esac
    done
fi

# Leave the autosaved window state small again, then quit.
ensure_pitch 0
ensure_playlist 0
quiet sleep 0.5
pkill -x Vibe 2>/dev/null || true
say "done — app appearance left pinned to $APPEARANCE"
