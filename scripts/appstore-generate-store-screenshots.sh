#!/bin/bash
# Build the App Store screenshots by compositing the window captures in
# Assets/ onto generated backgrounds.
#
#   scripts/appstore-generate-store-screenshots.sh [--platform macos|ios] [lang]
#   scripts/appstore-generate-store-screenshots.sh --all [--platform macos|ios]
#
# Defaults: macos, en; --all runs every catalog language. OUT_DIR overrides the
# output directory (under --all, the base of one directory per language).
#
# Every language composites the same captures; nothing in them is localized.
# Captions come from Assets/app-store/copy/<lang>/<platform>/screenshots.json,
# output goes to Assets/app-store/screenshots/<lang>/<platform>/ (only en is
# tracked). A missing translation fails: an English caption must never ship on
# a localized screenshot.
#
# Needs no app, debug build or screen recording permission, only the captures,
# so re-capture first if the UI changed. appstore-capture-app-screenshots.sh
# instead photographs the window over a staged desktop, so the Liquid Glass
# shows a real backdrop, but only at its captured size; this upscales the
# capture ~1.6x so the window fills the canvas.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/scripts/compose-app-store-overlay.swift"
LANGS="$ROOT/scripts/catalog-languages.sh"

# Compile the compositor once: `swift file.swift` recompiles per run. Exported,
# so --all's children reuse it.
if [ -z "${COMPOSE_BIN:-}" ]; then
    COMPOSE_BIN="$(mktemp -d)/compose"
    export COMPOSE_BIN
    trap 'rm -rf "$(dirname "$COMPOSE_BIN")"' EXIT
    xcrun swiftc -O -o "$COMPOSE_BIN" "$COMPOSE"
fi

if [ "${1:-}" = --all ]; then
    shift
    # Forward every flag, or `--all --platform ios` silently builds macOS.
    REST=("$@")
    # Capture first: a process substitution's exit status is never checked, so
    # a failing catalog-languages.sh would silently generate nothing.
    ALL_LANGS="$("$LANGS")"
    [ -n "$ALL_LANGS" ] || { echo "catalog-languages.sh returned no languages" >&2; exit 1; }
    # An inherited OUT_DIR would send every language to one directory, so it
    # becomes the base of a per-language one.
    while read -r l; do
        if [ -n "${OUT_DIR:-}" ]; then
            OUT_DIR="$OUT_DIR/$l" "$0" ${REST[@]+"${REST[@]}"} "$l"
        else
            "$0" ${REST[@]+"${REST[@]}"} "$l"
        fi
    done <<< "$ALL_LANGS"
    exit 0
fi

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

# Cleared first: the uploader takes every .png in the directory, so a renamed
# or removed shot would ship beside the current set.
prepare_out() { # <dir>
    OUT="$1"
    mkdir -p "$OUT"
    rm -f "$OUT"/*.png
}

# SF Symbols drawn above the player headline; empty draws no row. The FX row
# is "dial.min,dial.max.fill,water.waves,repeat,repeat.circle" (Q-W-E-R-T), and
# any names here must match the FX menu's in Vibe/Mac/Menu/MainMenuBuilder.m so
# the shot shows the app's own glyphs.
PLAYER_GLYPHS=""

# iOS captions are headline-only; an empty subhead makes the compositor drop
# the line.
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

# iOS: one directory per ASC screenshot set, since iPhone (APP_IPHONE_67) and
# iPad (APP_IPAD_PRO_3GEN_129) are separate sets. Each canvas is its set's
# exact size, which is also the simulator's native size.
if [ "$PLATFORM" = ios ]; then
    # At the size the store draws a phone shot, a second, smaller line is
    # unreadable, so the headline alone carries it at nearly twice nominal.
    # appstore-validate-copy.sh's headline_scale must match, or its fit check
    # passes copy that fails here.
    HEADLINE_SCALE="${HEADLINE_SCALE:-1.9}"
    # One- and two-line headlines sit side by side, so the device is pinned
    # and the text centred above it; otherwise the phone jumps between shots.
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

# The leading number is the store's display order: the uploader sends each
# set in file-name order.
shot player   screenshot-basic.png          01-player.png   "$PLAYER_GLYPHS"
shot playlist screenshot-playlist.png       02-playlist.png
# The only fixed background: this track's art is a red hat on green, and the
# derived red wash fought the orange waveform. 5C9488 is the art's own green,
# which solidWash halves to #2E4A44.
#
# TRAP: 5C9488 is eyedropped from FOLDER_TRACK_THEMES's artwork
# (generate-readme-screenshots.sh). Change that track and resample it, or drop
# the argument.
shot themes   screenshot-themes.png         03-themes.png   ""              5C9488
# The compact pitch capture: a playlist under the fader would compete with
# shot 02. (screenshot-playlist-pitch.png is the README's.)
shot pitch    screenshot-pitch.png          04-pitch.png

echo "done — $OUT"
