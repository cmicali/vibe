#!/bin/bash
# Build the Mac App Store screenshots by compositing window captures onto
# generated backgrounds.
#
#   scripts/appstore-generate-store-screenshots.sh [lang]     # default en
#   scripts/appstore-generate-store-screenshots.sh --all      # every catalog language
#
# Every language composites the same README captures from Assets/ — the
# window shows only song titles and artwork, nothing localized, so the
# captures are shared. Captions come from Assets/app-store/copy/<lang>/
# screenshots.json and the output goes to Assets/app-store/screenshots/<lang>/
# (only the English set is tracked). A missing translation fails loudly — an
# English caption must never ship silently on a localized screenshot.
#
# This is the mock-up path: it needs no app, no debug build and no screen
# recording permission, only the alpha-channel window captures. Regenerate
# those first if the UI has changed, then run this.
#
# The other path, appstore-capture-app-screenshots.sh, photographs the window
# over a staged desktop so the Liquid Glass shows a real backdrop. It is the
# honest one, but it can only show the window at its captured size, which on a
# 2880x1800 canvas leaves the UI small. This one upscales the capture ~1.6x so
# the window is the picture, at the cost of being a composite. See the header
# of compose-app-store-overlay.swift.
#
# The captions live in Assets/app-store/copy/ rather than here: they are
# marketing text, revised alongside the rest of the App Store copy. The shot
# table below is design, not copy — it maps each caption id to a capture, an
# output name and an optional glyph row, identically for every language.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/scripts/compose-app-store-overlay.swift"
LANGS="$ROOT/scripts/catalog-languages.sh"

# Compile the compositor once and reuse the binary — `swift file.swift`
# recompiles per run, and --all invokes it four times per language. The
# exported path survives the --all recursion so children skip the compile.
if [ -z "${COMPOSE_BIN:-}" ]; then
    COMPOSE_BIN="$(mktemp -d)/compose"
    export COMPOSE_BIN
    trap 'rm -rf "$(dirname "$COMPOSE_BIN")"' EXIT
    xcrun swiftc -O -o "$COMPOSE_BIN" "$COMPOSE"
fi

if [ "${1:-}" = --all ]; then
    # Capture first: a process substitution's exit status is never checked, so
    # a failing catalog-languages.sh would silently generate nothing.
    ALL_LANGS="$("$LANGS")"
    [ -n "$ALL_LANGS" ] || { echo "catalog-languages.sh returned no languages" >&2; exit 1; }
    # Each child derives its per-language output dir, and an exported OUT_DIR
    # would send every language into the same directory — so scope it: an
    # override becomes the base, gaining a /<lang> suffix per child.
    while read -r l; do
        if [ -n "${OUT_DIR:-}" ]; then
            OUT_DIR="$OUT_DIR/$l" "$0" "$l"
        else
            "$0" "$l"
        fi
    done <<< "$ALL_LANGS"
    exit 0
fi

# macOS by default; --platform ios composites the two iOS canvases instead.
PLATFORM=macos
case "${1:-}" in
    --platform) shift; PLATFORM="${1:-}"; shift ;;
    --platform=*) PLATFORM="${1#*=}"; shift ;;
esac
case "$PLATFORM" in macos|ios) ;; *) echo "--platform must be macos or ios" >&2; exit 64 ;; esac

L="${1:-en}"
if ! "$LANGS" | grep -qx "$L"; then
    echo "unknown language '$L' — catalog languages:" >&2
    "$LANGS" | tr '\n' ' ' >&2
    echo >&2
    exit 64
fi

IN="$ROOT/Assets"
COPY="$ROOT/Assets/app-store/copy/$L/$PLATFORM/screenshots.json"

[ -f "$COPY" ] || {
    echo "missing: $COPY — translate Assets/app-store/copy/en/$PLATFORM/screenshots.json for '$L'" >&2
    exit 1
}

# Empties and recreates one output directory. Every shot is regenerated on
# every run, so it is cleared first: otherwise a renamed or removed shot
# survives there and the uploader, which takes every .png in file-name order,
# ships it beside the current set.
prepare_out() { # <dir>
    OUT="$1"
    mkdir -p "$OUT"
    rm -f "$OUT"/*.png
}

# Optional row of SF Symbols drawn above the player headline, larger than it.
# Empty means no row, which is the current design — the glyphs are OFF.
#
# To turn the row back on, restore the five performance FX in Q-W-E-R-T order:
#   PLAYER_GLYPHS="dial.min,dial.max.fill,water.waves,repeat,repeat.circle"
#
# Any names used here must stay identical to the ones the FX menu passes to
# NSImage(systemSymbolName:) in Vibe/Mac/Menu/MainMenuBuilder.m, so the shot shows
# the app's own artwork rather than a lookalike. The compositor renders them
# through that same API.
PLAYER_GLYPHS=""

# The iOS sets are headline-only, so a missing subhead there is the format
# rather than an omission; on macOS both are required and an empty one is an
# error. Passing an empty subhead to the compositor drops the line entirely.
caption() { # <id> <headline|subhead>
    local v
    v="$(jq -r --arg id "$1" --arg f "$2" \
        'first(.[] | select(.id == $id)) | .[$f] // empty' "$COPY")"
    if [ -z "$v" ] && ! { [ "$PLATFORM" = ios ] && [ "$2" = subhead ]; }; then
        echo "missing or empty $2 for shot '$1' in $COPY" >&2; exit 1
    fi
    printf '%s' "$v"
}

shot() { # <id> <source> <output> [glyphs] [wash-color]
    [ -f "$IN/$2" ] || { echo "missing: $IN/$2 — run generate-readme-screenshots.sh" >&2; exit 1; }
    local wash=() canvas=() hscale=() centre=()
    [ -n "${CENTER_TEXT:-}" ] && centre=(--center-text)
    [ -n "${5:-}" ] && wash=(--wash-color "$5")
    [ -n "${CANVAS:-}" ] && canvas=(--canvas "$CANVAS")
    [ -n "${HEADLINE_SCALE:-}" ] && hscale=(--headline-scale "$HEADLINE_SCALE")
    "$COMPOSE_BIN" "$IN/$2" "$OUT/$3" --lang "$L" \
        --headline "$(caption "$1" headline)" \
        --subhead "$(caption "$1" subhead)" \
        --glyphs "${4:-}" ${wash[@]+"${wash[@]}"} ${canvas[@]+"${canvas[@]}"} \
        ${hscale[@]+"${hscale[@]}"} ${centre[@]+"${centre[@]}"}
}

# iOS: one directory per App Store Connect screenshot set, because iPhone and
# iPad are SEPARATE sets (APP_IPHONE_67 and APP_IPAD_PRO_3GEN_129) rather than
# two sizes of one. The canvases are those sets' exact pixel sizes, which are
# also the simulators' native sizes, so nothing is resampled. macOS has a
# single set (APP_DESKTOP) and keeps its flat directory.
if [ "$PLATFORM" = ios ]; then
    # No subhead, and a headline nearly twice nominal. At the size the store
    # actually draws these, a second smaller line is unreadable and only takes
    # room from the one line that is, so the headline carries the message
    # alone — which is why the iOS captions are short enough to wrap to two
    # lines at this size rather than shrink back down.
    HEADLINE_SCALE="${HEADLINE_SCALE:-1.9}"
    # One- and two-line headlines sit side by side in this set, so the device
    # is pinned and the text centred above it rather than the whole stack
    # being centred — otherwise the phone visibly jumps between shots.
    CENTER_TEXT=1
    for device in iphone:1290x2796 ipad:2048x2732; do
        DEV="${device%%:*}"; CANVAS="${device##*:}"
        prepare_out "${OUT_DIR:-$ROOT/Assets/app-store/screenshots/$L/ios/$DEV}"
        shot player   "screenshot-ios-$DEV-player.png"   01-player.png
        shot seek     "screenshot-ios-$DEV-seek.png"     02-seek.png
        shot playlist "screenshot-ios-$DEV-playlist.png" 03-playlist.png
        shot widget   "screenshot-ios-$DEV-widget.png"   04-widget.png
    done
    echo "done — $ROOT/Assets/app-store/screenshots/$L/ios"
    exit 0
fi

prepare_out "${OUT_DIR:-$ROOT/Assets/app-store/screenshots/$L/macos}"

# The leading number is the App Store's display order: ASC sorts a locale's
# screenshot set by file name. Renaming or reordering a shot therefore changes
# what the store shows, which is why $OUT is emptied above — a shot that has
# been renamed or dropped would otherwise linger there and upload alongside
# the new set.
shot player   screenshot-basic.png          01-player.png   "$PLAYER_GLYPHS"
shot playlist screenshot-playlist.png       02-playlist.png
# The only shot with a fixed background. Every other one derives its wash
# from the playing track's artwork, which here is a red hat on a green
# backdrop — and a red field behind the shot that advertises THEMES fought
# both the orange waveform and the point being made. 5C9488 is that artwork's
# own green, sampled from its corners; solidWash halves it, so the field lands
# at #2E4A44, the level the green reads at inside the art.
#
# TRAP: it is eyedropped from THIS track. Change FOLDER_TRACK_THEMES in
# generate-readme-screenshots.sh and the background no longer has anything to
# do with the artwork above it — resample or drop the argument.
shot themes   screenshot-themes.png         03-themes.png   ""              5C9488
# The COMPACT pitch capture, not the folder one: the pitch fader is the
# subject, and a playlist under it only competes with shot 02. screenshot-
# playlist-pitch.png is still captured — the README uses it.
shot pitch    screenshot-pitch.png          04-pitch.png

echo "done — $OUT"
