# Mechanics for generate-readme-screenshots.sh and
# appstore-capture-app-screenshots.sh — sourced, never run. Assumes
# `set -euo pipefail`.
#
# Drives a DEBUG build through --debug-cmd (the vibe-debug skill). The terminal
# needs Screen Recording (real screen captures: the in-process snapshot cannot
# render the Liquid Glass) and Accessibility (only real cursor motion drives a
# hover).

# shellcheck shell=bash

SCREENSHOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCREENSHOT_DIR/../.." && pwd)"
SKILL="$ROOT/.claude/skills/vibe-debug/scripts"
APP="${VIBE_APP:-$ROOT/build/DerivedData/Build/Products/Debug/Vibe.app}"
V="$APP/Contents/MacOS/Vibe"

# Waveform morph + progress settle before the shutter.
SETTLE="${SETTLE:-2.5}"
# Rows the playing track sits above the bottom of the list (center_on_track).
# ~9 rows fit in the default height, so 4 is mid-list.
CENTER_OFFSET="${CENTER_OFFSET:-4}"

quiet() { "$V" --debug-cmd "$@" >/dev/null; }
state() { "$V" --debug-cmd dump_state; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# --- setup ------------------------------------------------------------------

# Build Debug unless VIBE_SKIP_BUILD; Release has no debug channel.
require_debug_build() {
    if [ -z "${VIBE_SKIP_BUILD:-}" ]; then
        say "building Debug"
        "$ROOT/scripts/build.sh" Debug >/dev/null
    fi
    [ -x "$V" ] || { echo "no debug build at $APP" >&2; exit 1; }
}

# Callers install `trap screenshot_cleanup EXIT INT TERM`: INT and TERM
# matter, or a Ctrl-C leaves the full-screen backdrop up.
SHOT_TMP="$(mktemp -d)"
BACKDROP_PID=""
screenshot_cleanup() {
    stop_backdrop
    rm -rf "$SHOT_TMP"
}

# Cover the screen with backdrop.swift (its arguments: an image, gradient
# stops, --rect), so what shows through the glass is chosen, not whatever is
# on screen.
start_backdrop() {
    stop_backdrop
    swift "$SCREENSHOT_DIR/backdrop.swift" "$@" &
    BACKDROP_PID=$!
    sleep 5   # swift compiles the script before the window appears
}

stop_backdrop() {
    if [ -n "$BACKDROP_PID" ]; then
        kill "$BACKDROP_PID" 2>/dev/null || true
        # Reaped, or bash prints "Terminated: 15" mid-run.
        wait "$BACKDROP_PID" 2>/dev/null || true
        BACKDROP_PID=""
    fi
    # `swift file.swift` runs the script in a child, which outlives killing
    # the driver and keeps the full-screen window up, so sweep by name too.
    pkill -f 'backdrop\.swift' 2>/dev/null || true
}

launch() { "$SKILL/launch.sh" "$@" >/dev/null; }

# Quit, not kill: the frame autosave and the settings the run restored are
# flushed only on a real termination.
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

# Wait for the current track's duration, then let the waveform settle.
wait_loaded() {
    for _ in $(seq 1 60); do
        if [ "$(state | jq -r '.player.duration > 0')" = true ]; then break; fi
        quiet sleep 0.5
    done
    quiet sleep "$SETTLE"
}

# The lead seeks that much earlier, since the track keeps playing until the
# shutter.
seek_fraction() { # <fraction> [lead seconds]
    local dur
    dur=$(state | jq -r .player.duration)
    quiet seek "$(awk -v d="$dur" -v f="$1" -v l="${2:-0}" \
            'BEGIN{p = d * f - l; if (p < 0) p = 0; printf "%.2f", p}')"
    quiet sleep 1
}

# Already-there is NOT a no-op: the autosaved frame can disagree with the
# persisted shown/hidden setting (a killed app loses its last frame write), so
# the toggle is round-tripped to make the layout set the frame.
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

# Body width EXCLUDES the pitch panel: set_window_width adds it back when the
# panel is shown.
ensure_body_width() { # <body-points> [height-points]
    quiet set_window_width "$1" ${2:+"$2"}
    quiet sleep 0.5   # let the autoresize + glass relayout land
}

# Takes a renderer +styleIdentifier, not the localized +displayName. The style
# submenu is delegate-built and click_menu does not ask the delegate; dump_menu
# does, and the items it builds stay, so it runs first.
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

# next/previous, one per step, piped as one debug script.
step_to() { # <from> <to>
    local from=$1 to=$2 verb=next n
    if [ "$from" -eq "$to" ]; then return 0; fi
    n=$(( to - from ))
    if [ "$n" -lt 0 ]; then verb=previous; n=$(( -n )); fi
    for _ in $(seq 1 "$n"); do echo "$verb"; done \
        | "$V" --debug-cmd script - >/dev/null
}

play_track() { # <basename>
    local target
    target=$(playlist_index "$1")
    [ -n "$target" ] || { echo "not in playlist: $1" >&2; exit 1; }
    step_to "$(state | jq -r .playlist.currentIndex)" "$target"
}

# Land on <basename> with its row mid-list: every track change scrolls the
# playing row into view, so walk CENTER_OFFSET PAST it first, then back, which
# does not scroll again.
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

# A single click selects without playing. Through the debug channel, not
# input.swift: it activates the app and queues down+up together (safe against
# the table's tracking loop), where a CGEvent lands in whatever app is
# frontmost; and posted events leave the transport buttons hidden.
select_playing_row() {
    local pt
    pt=$(playing_row_point "$(state | jq -r .playlist.currentIndex)")
    quiet click $pt
    quiet sleep 0.5
}

# Centre of a playlist row, "<x> <y>" in window points (top-left origin). The
# scroll offset is inferred from the instantiated rows, which bounds it to a
# couple of points on a 28pt row.
playing_row_point() { # <0-based row>
    "$V" --debug-cmd dump_view_tree | jq -r --argjson row "$1" '
        def rect: gsub("[{}]"; "") | split(", ") | map(tonumber);  # "{{0, 0}, {680, 250}}" -> [0, 0, 680, 250]
        def find(cls): first(recurse(.subviews[]?) | select(.class == cls))
            // error("no \(cls) in the view tree");
        .windows[0] as $win
        | ($win.frame | rect | .[3]) as $winH
        | ($win.contentView | find("NSScrollView")) as $scroll
        | ($scroll.frame | rect) as $sv                            # [x, y, w, h]
        | [($scroll | find("PlaylistTableView")).subviews[]?
           # The app subclasses NSTableRowView (PlaylistRowView), so match the
           # suffix rather than the AppKit name.
           | select(.class | endswith("RowView")) | .frame | rect] as $rows
        | if $rows == [] then error("no playlist rows in the view tree") else . end
        | $rows[0][3] as $rowH
        | ([$rows[] | .[1]] | min) as $lo
        | (([$rows[] | .[1]] | max) + $rowH) as $hi
        | (($lo + ($hi - $sv[3])) / 2) as $offset                  # scrolled-to position
        | ($winH - ($sv[1] + $sv[3])) as $top                      # scroll view top edge
        | "\($sv[2] / 2 | floor) \($top + $row * $rowH + $rowH / 2 - $offset | floor)"
    '
}

# --- cursor -----------------------------------------------------------------
#
# The transport and traffic-light buttons are revealed by a window-wide
# NSTrackingArea, which posted NSEvents (--debug-cmd mouse_move) never reach,
# so hovering moves the REAL cursor. Enter/exit fire only on a boundary
# crossing, hence leaving first.

# "<windowID> <pid> <x> <y> <w> <h>" — global screen points, top-left origin.
win_geom() { swift "$SKILL/find-window.swift" "$(pgrep -x Vibe | head -1)" | head -1; }

# input.swift gates global CGEvents behind --isolated-desktop, which ASSERTS
# isolation rather than creating it, so a person makes the assertion, per run,
# with ALLOW_GLOBAL_INPUT=1; this library never makes it for a caller.
#
# TRAP: input.swift refuses a cursor move without --isolated-desktop. Both
# capture scripts call require_global_input before their build and launch, so
# a missing assertion fails there, not at the first cursor move.
require_global_input() {
    [ "${ALLOW_GLOBAL_INPUT:-}" = 1 ] && return 0
    cat >&2 <<'MSG'
error: these captures move the REAL mouse pointer with global CGEvents.

       They have to: the transport and traffic-light buttons are revealed by a
       window-wide NSTrackingArea, tracking areas are driven by the window
       server, and posted NSEvents (--debug-cmd mouse_move) never reach them.

       input.swift requires --isolated-desktop for this, meaning a dedicated
       test Mac or a disposable VM. The flag asserts isolation; it does not
       create it. Running here takes over this machine's pointer for the whole
       run, so assert it deliberately, per run:

           ALLOW_GLOBAL_INPUT=1 make screenshots

       Do not set it in a shell profile, in CI, or during unattended stress.
MSG
    exit 64
}

cursor_to() { # <global-x> <global-y>
    require_global_input
    swift "$SKILL/input.swift" --isolated-desktop move "$1" "$2"
    quiet sleep 0.3
}

# Park the cursor left of the window (right, near the screen edge), hiding the
# transport buttons.
cursor_out() {
    local x y w h out
    read -r _ _ x y w h <<<"$(win_geom)"
    out=$(( x - 60 ))
    if [ "$out" -lt 0 ]; then out=$(( x + w + 60 )); fi
    cursor_to "$out" "$(( y + h / 2 ))"
}

# Out first so there IS a crossing, then onto a neutral spot of the title
# row, so no button draws its hover colour.
cursor_hover_window() {
    local x y w h
    cursor_out
    read -r _ _ x y w h <<<"$(win_geom)"
    cursor_to "$(( x + w * 66 / 100 ))" "$(( y + 25 ))"
    quiet sleep 0.6   # the reveal is a fade (kControlFadeDur)
}

# --- capture ----------------------------------------------------------------

# A key window can still sit under another app's, and the merged capture reads
# the composited screen, so this, not keyWindow, decides. The backdrop window
# belongs to the swift driver's child, hence the pid set. True with no backdrop.
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

# Bring Vibe to the front, above any backdrop; nonzero if it never got there.
# The glass dims when the window is not key (no public opt-out).
#
# Activating an app ALREADY frontmost is a no-op that cannot raise it back over
# a backdrop, so each attempt bounces through Finder first. The bundle is opened
# by path: `tell application "Vibe"` may resolve to another installed copy.
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

# The window's own buffer: transparent background, real shadow and corners,
# but glass and NSVisualEffectView materials resolve against a NEUTRAL backdrop
# (the playlist frost is mid-grey whatever is behind).
capture_window() { # <out.png>
    "$SKILL/capture-window.sh" "$1" "$(pgrep -x Vibe | head -1)" >/dev/null
}

# The window buffer's alpha, shadow and corners with the composited screen's
# real translucency (compose-window-shot.swift). The region is EXACTLY the
# window rect, which lets the two be aligned without guessing the asymmetric
# shadow padding, so the window must not move between the shutters.
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
