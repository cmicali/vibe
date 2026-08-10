# Shared machinery for the two screenshot generators — sourced, never run:
#
#   ../generate-readme-screenshots.sh     the README shots (Assets/screenshot-*.png)
#   ../appstore-capture-app-screenshots.sh  the App Store shots (2880x1800, on a
#                                         background image)
#
# The two generators live in scripts/; everything they lean on — this file and
# the swift helpers it drives — lives here.
#
# Everything here drives or photographs a DEBUG build of the app through the
# --debug-cmd channel (see .claude/skills/vibe-debug). Both callers need the
# same two permissions for the terminal:
#   Screen Recording  — the shots must be REAL screen captures, because the
#                       in-process snapshot path cannot render the Liquid Glass
#                       chrome.
#   Accessibility     — revealing the transport buttons needs real cursor
#                       motion (CGEvents); nothing else can drive a hover.
#
# Callers own policy (which tracks, which states, where the output goes); this
# file owns mechanics. Every function assumes `set -euo pipefail` in the caller.

# shellcheck shell=bash

SCREENSHOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCREENSHOT_DIR/../.." && pwd)"
SKILL="$ROOT/.claude/skills/vibe-debug/scripts"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"

# Waveform morph + progress settle before the shutter.
SETTLE="${SETTLE:-2.5}"
# Rows the playing track sits above the bottom of the visible list — see
# center_on_track(). ~9 rows fit in the default height, so 4 puts it mid-list.
CENTER_OFFSET="${CENTER_OFFSET:-4}"

quiet() { "$V" --debug-cmd "$@" >/dev/null; }
state() { "$V" --debug-cmd dump_state; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# --- setup ------------------------------------------------------------------

# Build Debug (unless VIBE_SKIP_BUILD) and fail early if there is no binary to
# drive. Every command below needs the debug channel, which Release doesn't
# compile in.
require_debug_build() {
    if [ -z "${VIBE_SKIP_BUILD:-}" ]; then
        say "building Debug"
        "$ROOT/scripts/build.sh" Debug >/dev/null
    fi
    [ -x "$V" ] || { echo "no debug build at $APP" >&2; exit 1; }
}

# Scratch space + the one process this library leaves running. Callers install
# the trap: `trap screenshot_cleanup EXIT INT TERM` — INT and TERM matter
# because the backdrop covers the whole screen, and a Ctrl-C that skipped this
# would leave it there.
SHOT_TMP="$(mktemp -d)"
BACKDROP_PID=""
screenshot_cleanup() {
    stop_backdrop
    rm -rf "$SHOT_TMP"
}

# Cover the screen with backdrop.swift (arguments are that script's:
# an image path, gradient stops, and/or --rect). Merged captures show what is
# genuinely behind the window through the glass and the playlist frost, which
# otherwise means "whatever happens to be on your screen" — not reproducible,
# and not something to publish unexamined.
start_backdrop() {
    stop_backdrop
    swift "$SCREENSHOT_DIR/backdrop.swift" "$@" &
    BACKDROP_PID=$!
    sleep 5   # swift compiles the script before the window appears
}

stop_backdrop() {
    if [ -n "$BACKDROP_PID" ]; then
        kill "$BACKDROP_PID" 2>/dev/null || true
        # Reap it here, or bash reports the signal ("Terminated: 15") on its own
        # schedule, in the middle of the run's output.
        wait "$BACKDROP_PID" 2>/dev/null || true
        BACKDROP_PID=""
    fi
    # `swift file.swift` runs the script in a child of the driver, and killing
    # the driver leaves that child — with the full-screen window — alive. Nothing
    # else on the machine is named backdrop.swift, and leaving one running covers
    # the user's screen until they find it, so sweep by name as well.
    pkill -f 'backdrop\.swift' 2>/dev/null || true
}

launch() { "$SKILL/launch.sh" "$@" >/dev/null; }

# Quit rather than kill, at the end of a run: the window's frame autosave and
# the settings the run overwrote (appearance, panels, waveform style) are only
# flushed on a real termination, so a pkill'd app comes back with whatever state
# AppKit last happened to write — losing the restore the run just did. Falls
# back to the kill if the quit doesn't take.
quit_app() {
    [ -n "$(pgrep -x Vibe || true)" ] || return 0
    osascript -e 'tell application "Vibe" to quit' 2>/dev/null || true
    for _ in $(seq 1 20); do
        [ -n "$(pgrep -x Vibe || true)" ] || return 0
        sleep 0.25
    done
    echo "warning: Vibe did not quit — killing it (window state may not persist)" >&2
    pkill -x Vibe 2>/dev/null || true
}

# --- app state --------------------------------------------------------------

# Wait until the current track's duration is known (the open + header metadata
# have landed), then let the waveform settle.
wait_loaded() {
    for _ in $(seq 1 60); do
        if [ "$(state | jq -r '.player.duration > 0')" = true ]; then break; fi
        quiet sleep 0.5
    done
    quiet sleep "$SETTLE"
}

# The track keeps playing, so the playhead has moved on by the time the shutter
# opens: pass the lead to seek that much earlier and land where you asked.
seek_fraction() { # <fraction> [lead seconds]
    local dur
    dur=$(state | jq -r .player.duration)
    quiet seek "$(awk -v d="$dur" -v f="$1" -v l="${2:-0}" \
            'BEGIN{p = d * f - l; if (p < 0) p = 0; printf "%.2f", p}')"
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

# Body width in points — the player without the pitch panel's slice. The
# window is user-resizable and restores whatever width the autosave kept, so
# any shot that wants a known size has to say so.
ensure_body_width() { # <points>
    quiet set_window_width "$1"
    quiet sleep 0.5   # let the autoresize + glass relayout land
}

# The style submenu is delegate-built, and click_menu's lookup does NOT ask the
# delegate — dump_menu does, and the items it builds stay in the menu, so the
# dump is what makes the item findable. Takes the renderer's +styleIdentifier
# ("sonic_cirrus", "detailed", "oversampling_detailed_x4", …), NOT the localized
# +displayName: the menu item's identifier is "waveform_style_<id>" and the
# state dump reports the identifier, so the identifier is the stable handle for
# both the click and the check.
ensure_waveform_style() { # <style identifier>
    local want=$1 got
    quiet dump_menu
    quiet click_menu "waveform_style_$want"
    got=$(state | jq -r .settings.waveformStyle)
    [ "$got" = "$want" ] || { echo "waveform style is '$got', wanted '$want'" >&2; exit 1; }
    quiet sleep "$SETTLE"   # the new renderer morphs in
}

# --- playlist ---------------------------------------------------------------

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

# Walk to <basename> wherever it landed in the loaded playlist.
play_track() { # <basename>
    local target
    target=$(playlist_index "$1")
    [ -n "$target" ] || { echo "not in playlist: $1" >&2; exit 1; }
    step_to "$(state | jq -r .playlist.currentIndex)" "$target"
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

# --- cursor -----------------------------------------------------------------
#
# The transport/traffic-light buttons are revealed by a window-wide
# NSTrackingArea, and tracking areas are driven by the window server — posted
# NSEvents (--debug-cmd mouse_move) never reach them, so hovering means moving
# the REAL cursor with CGEvents. Enter/exit fire on boundary crossings only,
# hence the always-leave-first dance.

# "<windowID> <pid> <x> <y> <w> <h>" — global screen points, top-left origin.
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

# --- capture ----------------------------------------------------------------

# Is the app's window above the staged backdrop? A window can be key while
# another app's window sits on top of it, and the merged capture reads the
# COMPOSITED screen — so this, not keyWindow, is the check that decides whether
# a shot is of the app or of the backdrop. Both windows are at layer 0; the
# backdrop's window belongs to the swift interpreter's child process, hence the
# pid set rather than a name match. True when no backdrop is staged.
app_above_backdrop() {
    [ -n "$BACKDROP_PID" ] || return 0
    local stack pids app_index backdrop_index
    pids=" $BACKDROP_PID $(pgrep -P "$BACKDROP_PID" 2>/dev/null | tr '\n' ' ') "
    stack=$(swift "$SCREENSHOT_DIR/window-stack.swift")
    app_index=$(awk '$2 == "Vibe" {print $1; exit}' <<<"$stack")
    backdrop_index=$(awk -v pids="$pids" \
            '{ if (index(pids, " " $3 " ")) { print $1; exit } }' <<<"$stack")
    [ -n "$app_index" ] || return 1
    [ -n "$backdrop_index" ] || return 0
    [ "$app_index" -lt "$backdrop_index" ]
}

# Bring Vibe to the front, above any staged backdrop; nonzero if it never got
# there — callers decide how bad that is. It matters twice over: the glass views
# dim themselves when the window isn't key (no public opt-out), and a window
# left under the backdrop photographs as a window-shaped hole.
#
# Two traps, both learned the hard way. Activating an app that is ALREADY
# frontmost is a no-op, and a no-op cannot raise the window back over a backdrop
# that ordered itself front afterwards — so each attempt bounces through Finder
# to make the activation a real transition. And it activates the bundle by path
# rather than `tell application "Vibe"`, whose name lookup goes through Launch
# Services and is free to resolve to some other installed copy.
activate_vibe() {
    local attempt
    for attempt in 1 2 3; do
        osascript -e 'tell application "Finder" to activate' 2>/dev/null || true
        sleep 0.3
        open -a "$APP" 2>/dev/null || true
        quiet sleep 1
        if [ "$(state | jq -r .window.keyWindow)" = true ] && app_above_backdrop; then
            return 0
        fi
    done
    return 1
}

# screencapture -l<windowID>: the window's own buffer, so it carries a
# transparent background, the real drop shadow and antialiased rounded corners,
# sized exactly window + shadow. But its glass and NSVisualEffectView materials
# resolved against a NEUTRAL backdrop instead of the actual screen: the playlist
# frost renders mid-gray no matter what is behind the window.
capture_window() { # <out.png>
    "$SKILL/capture-window.sh" "$1" "$(pgrep -x Vibe | head -1)" >/dev/null
}

# Both capture paths, combined by compose-window-shot.swift: composited window
# content (translucency showing what is really behind), still with the
# transparent background, real shadow and corner clipping. The region must
# cover EXACTLY the window rect — that is what lets the compositor line the two
# up without guessing the (asymmetric) shadow padding — so the window must not
# move between the two shutters. What shows THROUGH the glass is whatever is
# behind the window, so stage the desktop first (start_backdrop).
capture_merged() { # <out.png>
    local x y w h
    read -r _ _ x y w h <<<"$(win_geom)"
    capture_window "$SHOT_TMP/window.png"
    screencapture -x -R"$x,$y,$w,$h" "$SHOT_TMP/region.png"
    swift "$SCREENSHOT_DIR/compose-window-shot.swift" \
            "$SHOT_TMP/window.png" "$SHOT_TMP/region.png" "$1" >/dev/null
}

# "<width> <height>" in pixels.
png_size() { # <file.png>
    sips -g pixelWidth -g pixelHeight "$1" | awk '/pixel/{printf "%s ", $2} END{print ""}'
}
