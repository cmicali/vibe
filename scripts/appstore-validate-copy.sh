#!/bin/bash
# Fail unless every catalog language has complete App Store copy in
# Assets/app-store/copy/<lang>/<platform>/ and it holds up: the four text
# fields present,
# non-empty and within ASC's character limits (counted in characters, not
# bytes), description free of leftover markdown (bold, links, headings and
# bullets — it uploads verbatim), the shared support-url.txt,
# marketing-url.txt and privacy-url.txt each a bare URL, and screenshots.json
# holding a caption for every shot that fits every canvas that platform ships
# (compose-app-store-overlay.swift --measure).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/scripts/compose-app-store-overlay.swift"
FAIL=0

# Compile the compositor once — this measures ~120 captions, and `swift
# file.swift` would recompile on every one.
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
    # The old pattern required a space after the marker, so **bold** headings
    # slipped through and would have shipped as literal asterisks in 30 locales.
    # Bold and links are matched anywhere on the line, headings and bullets only
    # at line start. whats-new.txt is exempt by construction — this only reads
    # description.txt — and its "* " bullets upload verbatim on purpose.
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
        # An iOS caption is the headline alone, and that is enforced in both
        # directions: the store draws a phone screenshot too small for a
        # second, smaller line to be read, so the headline runs at 1.9x and
        # carries the message. A subhead written for one locale would not be
        # dropped — it would render, and that locale alone would be laid out
        # differently from the other 29.
        if [ "$plat" = ios ]; then
            [ -z "$s" ] || err "$label: shot '$id' has a subhead; iOS captions are headline-only"
        else
            [ -n "$s" ] || { err "$label: shot '$id' missing subhead"; continue; }
        fi
        # --lang is the LANGUAGE, not the label: the measurement picks the font
        # and line-breaking rules from it, and "en/macos" is not a language.
        # Every canvas the platform ships is measured, because one caption is
        # written for all of them and each has its own type size and width cap.
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
        *)     echo "" ;;
    esac
}

# The canvases one caption has to fit. macOS has a single screenshot set;
# iOS has two, because iPhone and iPad are separate ASC sets rather than two
# sizes of one, and they share the caption between them.
canvases() {
    case "$1" in
        macos) echo "2880x1800" ;;
        ios)   echo "1290x2796 2048x2732" ;;
    esac
}

# Must match the generator. Getting this wrong makes the fit check pass copy
# that fails the build, which is the one thing it exists to prevent.
headline_scale() {
    case "$1" in
        ios) echo 1.9 ;;
        *)   echo 1.0 ;;
    esac
}

# Shared across locales. ASC requires a support URL per localization — one
# created without it blocks submission; the marketing URL is optional but kept
# uniform the same way. The privacy URL is a different record entirely — it
# lives on appInfoLocalizations rather than the version — but it is the same
# shape of file and the same one-string-everywhere rule.
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

# Every file under copy/<lang>/<platform>/ is an ASC *version* field, and
# versions are per platform — which is the whole reason for the platform
# directory. The three URL files above are not version fields and stay at
# copy/, shared by both.
#
# Both platforms are required: every catalog language now carries copy for
# each. The tolerance that let a wholly absent ios/ pass while it was being
# written is gone, as its own comment said it should be.
PLATFORMS="macos ios"
REQUIRED_PLATFORMS="macos ios"
PENDING=0

while read -r l; do
    for plat in $PLATFORMS; do
        DIR="$ROOT/Assets/app-store/copy/$l/$plat"
        if [ ! -d "$DIR" ]; then
            case " $REQUIRED_PLATFORMS " in
                *" $plat "*) err "$l/$plat: missing $DIR" ;;
                *)           PENDING=$((PENDING + 1)) ;;
            esac
            continue
        fi
        check_text "$l/$plat" "$DIR"
        ids="$(shot_ids "$plat")"
        [ -n "$ids" ] || continue
        if [ -f "$DIR/screenshots.json" ]; then
            # Unquoted on purpose: ids is a space-separated list.
            # shellcheck disable=SC2086
            check_captions "$l/$plat" "$l" "$plat" "$DIR/screenshots.json" $ids
        else
            err "$l/$plat: missing $DIR/screenshots.json"
        fi
    done
done <<< "$LANGS"

[ "$PENDING" = 0 ] || echo "appstore-validate-copy: $PENDING iOS file(s) not written yet"

[ "$FAIL" = 0 ] && echo "appstore-validate-copy: OK" || exit 1
