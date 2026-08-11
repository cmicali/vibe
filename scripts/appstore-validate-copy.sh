#!/bin/bash
# Fail unless every catalog language has complete App Store copy in
# Assets/app-store/copy/<lang>/ and it holds up: the four text fields present,
# non-empty and within ASC's character limits (counted in characters, not
# bytes), description free of leftover markdown, the shared support-url.txt a
# bare URL, and screenshots.json holding a non-empty headline and subhead for
# every shot, each fitting the screenshot layout
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
    if [ -f "$2/description.txt" ] && grep -qE '^(##|\*) ' "$2/description.txt"; then
        err "$1: description.txt contains markdown markup — it uploads verbatim"
    fi
}

check_captions() { # <lang> <screenshots.json>
    local id h s
    jq -e 'type == "array"' "$2" >/dev/null 2>&1 || { err "$1: $2 is not a JSON array"; return; }
    for id in player playlist pitch keys; do
        h="$(jq -r --arg id "$id" 'first(.[] | select(.id == $id)) | .headline // empty' "$2")"
        s="$(jq -r --arg id "$id" 'first(.[] | select(.id == $id)) | .subhead // empty' "$2")"
        [ -n "$h" ] && [ -n "$s" ] || { err "$1: shot '$id' missing headline or subhead"; continue; }
        "$COMPOSE_BIN" --measure --lang "$1" --headline "$h" --subhead "$s" \
            || err "$1: shot '$id' captions do not fit the layout"
    done
}

# Shared across locales. ASC requires a support URL per localization — one
# created without it blocks submission; the marketing URL is optional but kept
# uniform the same way.
for u in support-url marketing-url; do
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

while read -r l; do
    DIR="$ROOT/Assets/app-store/copy/$l"
    [ -d "$DIR" ] || { err "$l: missing $DIR"; continue; }
    check_text "$l" "$DIR"
    if [ -f "$DIR/screenshots.json" ]; then
        check_captions "$l" "$DIR/screenshots.json"
    else
        err "$l: missing $DIR/screenshots.json"
    fi
done <<< "$LANGS"

[ "$FAIL" = 0 ] && echo "appstore-validate-copy: OK" || exit 1
