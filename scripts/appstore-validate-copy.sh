#!/bin/bash
# Fail unless every catalog language has complete App Store copy for both
# platforms in Assets/app-store/copy/<lang>/<platform>/: the four text fields
# non-empty and within ASC's limits (in characters, not bytes), no markdown in
# description.txt (it uploads verbatim), the shared copy/*-url.txt files each a
# bare URL, and a screenshots.json caption for every shot that fits every
# canvas the platform ships (compose-app-store-overlay.swift --measure).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/scripts/compose-app-store-overlay.swift"
FAIL=0

# Compiled once: `swift file.swift` would recompile for every caption.
COMPOSE_BIN="$(mktemp -d)/compose"
trap 'rm -rf "$(dirname "$COMPOSE_BIN")"' EXIT
xcrun swiftc -O -o "$COMPOSE_BIN" "$COMPOSE"

err() { echo "appstore-validate-copy: $*" >&2; FAIL=1; }

check_text() { # <lang> <dir>
    local f path len limit
    for f in promotional-text keywords description whats-new; do
        case "$f" in # ASC field limits
            promotional-text) limit=170 ;;
            keywords)         limit=100 ;;
            description)      limit=4000 ;;
            whats-new)        limit=4000 ;;
        esac
        path="$2/$f.txt"
        [ -f "$path" ] || { err "$1: missing $path"; continue; }
        len="$(jq -Rs 'rtrimstr("\n") | length' "$path")"
        if [ "$len" -eq 0 ]; then
            err "$1: $f.txt is empty"
        elif [ "$len" -gt "$limit" ]; then
            err "$1: $f.txt is $len chars (ASC limit $limit)"
        fi
    done
    # Bold and links anywhere on a line, headings and bullets at its start.
    # whats-new.txt is not checked: its "* " bullets upload verbatim on purpose.
    if [ -f "$2/description.txt" ] \
        && grep -qE '(\*\*|__|\[[^]]+\]\([^)]+\))|^(#{1,6}|\*|-) ' "$2/description.txt"; then
        err "$1: description.txt contains markdown markup — it uploads verbatim"
    fi
}

check_captions() { # <label> <lang> <platform> <screenshots.json> <shot ids…>
    local label="$1" lang="$2" plat="$3" json="$4"
    shift 4
    local id h s canvas hscale
    hscale="$(headline_scale "$plat")"
    jq -e 'type == "array"' "$json" >/dev/null 2>&1 || { err "$label: $json is not a JSON array"; return; }
    for id in "$@"; do
        h="$(jq -r --arg id "$id" 'first(.[] | select(.id == $id)) | .headline // empty' "$json")"
        s="$(jq -r --arg id "$id" 'first(.[] | select(.id == $id)) | .subhead // empty' "$json")"
        [ -n "$h" ] || { err "$label: shot '$id' missing headline"; continue; }
        # iOS captions are headline-only, enforced both ways: a subhead in one
        # locale would render, laying that locale out unlike the rest.
        if [ "$plat" = ios ]; then
            [ -z "$s" ] || err "$label: shot '$id' has a subhead; iOS captions are headline-only"
        else
            [ -n "$s" ] || { err "$label: shot '$id' missing subhead"; continue; }
        fi
        # --lang is the language (it picks font and line breaking), not the
        # label. Each canvas has its own type size and width cap.
        for canvas in $(canvases "$plat"); do
            "$COMPOSE_BIN" --measure --lang "$lang" --headline "$h" --subhead "$s" \
                --canvas "$canvas" --headline-scale "$hscale" \
                || err "$label: shot '$id' captions do not fit $canvas"
        done
    done
}

# The shots each platform's screenshots.json must caption, in display order.
shot_ids() {
    case "$1" in
        macos) echo "player playlist themes pitch" ;;
        ios)   echo "player seek playlist widget" ;;
    esac
}

# The canvases one caption must fit; iPhone and iPad share a caption.
canvases() {
    case "$1" in
        macos) echo "2880x1800" ;;
        ios)   echo "1290x2796 2048x2732" ;;
    esac
}

# Must match appstore-generate-store-screenshots.sh's HEADLINE_SCALE, or the
# fit check passes copy that fails the build.
headline_scale() {
    case "$1" in
        ios) echo 1.9 ;;
        *)   echo 1.0 ;;
    esac
}

# Shared by every locale, and not version fields, so they live at copy/. ASC
# blocks submission of a localization without a support URL.
for u in support-url marketing-url privacy-url; do
    URL_FILE="$ROOT/Assets/app-store/copy/$u.txt"
    if [ ! -f "$URL_FILE" ]; then
        err "missing copy/$u.txt"
    elif ! grep -qE '^https?://[^[:space:]]+$' "$URL_FILE"; then
        err "copy/$u.txt must be a single bare URL"
    fi
done

# Capture first: a process substitution's exit status is never checked, so a
# failing catalog-languages.sh would yield zero iterations and a vacuous OK.
LANGS="$("$ROOT/scripts/catalog-languages.sh")"
[ -n "$LANGS" ] || { echo "appstore-validate-copy: catalog-languages.sh returned no languages" >&2; exit 1; }

# A language per background job: each caption measure is a process that
# mostly waits, and there are a dozen per language, so one after another they
# were most of the check. A job's FAIL is its own, so it reports by status.
PIDS=()
while read -r l; do
    (
        for plat in macos ios; do
            DIR="$ROOT/Assets/app-store/copy/$l/$plat"
            [ -d "$DIR" ] || { err "$l/$plat: missing $DIR"; continue; }
            check_text "$l/$plat" "$DIR"
            ids="$(shot_ids "$plat")"
            if [ -f "$DIR/screenshots.json" ]; then
                # Unquoted on purpose: ids is a space-separated list.
                # shellcheck disable=SC2086
                check_captions "$l/$plat" "$l" "$plat" "$DIR/screenshots.json" $ids
            else
                err "$l/$plat: missing $DIR/screenshots.json"
            fi
        done
        exit "$FAIL"
    ) &
    PIDS+=($!)
done <<< "$LANGS"
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAIL=1
done

[ "$FAIL" = 0 ] && echo "appstore-validate-copy: OK" || exit 1
