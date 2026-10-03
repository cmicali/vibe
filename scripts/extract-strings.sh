#!/bin/bash
#
# Extracts NSLocalizedString keys from the first-party Objective-C sources into
# Resources/Localizable.xcstrings.
#
#   scripts/extract-strings.sh            update the catalog in place
#   scripts/extract-strings.sh --check    fail if the catalog is out of date
#
# NOT a build phase, deliberately: the build has no String Catalog extraction
# for Objective-C (clang emits .stringsdata for Swift only; the only xcstrings
# build task is `compile`), and a phase rewriting a checked-in file would flip
# VIBE_GIT_DIRTY on every build.

set -euo pipefail

REPO_ROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CATALOG="$REPO_ROOT/Resources/Localizable.xcstrings"
REGISTRY="$REPO_ROOT/Vibe/Common/VibeStrings.h"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. Expand the registry through the C preprocessor.
#
# xcstringstool matches localization macros by name AND arity, and the
# three-argument NSLS(key, value, comment) fits no stock shape, even with
# `-s NSLS`: extraction silently yields zero keys. So extract from `clang -E` of
# a throwaway TU referencing every STR_*, which is exact and fails loudly on a
# malformed entry where a regex over the header would quietly mis-parse.
{
    printf '#import "%s"\n' "$REGISTRY"
    printf 'static id vibe_registry_[] = {\n'
    grep -oE '^#define[[:space:]]+STR_[A-Za-z0-9_]+' "$REGISTRY" | awk '{print $2 ","}'
    printf '};\n'
} > "$WORK/registry.m"

if ! grep -q 'STR_' "$WORK/registry.m"; then
    echo "error: no STR_* macros found in $REGISTRY" >&2
    exit 1
fi

# VIBE_STRINGS_EXTRACTION keeps Foundation out of the TU; otherwise
# NSLocalizedStringWithDefaultValue, itself a Foundation macro, expands past
# the shape the extractor matches, yielding zero keys.
xcrun clang -E -P -x objective-c -DVIBE_STRINGS_EXTRACTION=1 "$WORK/registry.m" > "$WORK/registry-expanded.m"

# ---------------------------------------------------------------------------
# 2. Extract.
#
# Every other first-party source is swept too, so a stray inline
# NSLocalizedString cannot hide; VibeStrings.h itself would only warn
# "non-literal key". Debug/ is never localized. (No mapfile: bash 3.2.)
SOURCES=("$WORK/registry-expanded.m")
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$REPO_ROOT/Vibe" \( -name '*.m' -o -name '*.mm' -o -name '*.h' \) \
             -not -path '*/ThirdParty/*' -not -path '*/Debug/*' \
             -not -path "$REGISTRY" -print0 | sort -z)
SOURCES+=("$REPO_ROOT/main.m")

# The genstrings-compatible mode: NSLocalizedString and its siblings.
xcrun xcstringstool extract "${SOURCES[@]}" \
    --legacy-localizable-strings \
    --output-directory "$WORK"

# One .stringsdata per table; globbed so a new table cannot drop keys.
if ! ls "$WORK"/*.stringsdata >/dev/null 2>&1; then
    echo "error: no .stringsdata produced — extraction found nothing" >&2
    exit 1
fi

# One key with two defaults is fatal, where sync only warns: it keeps one value,
# so every caller of the other renders that text in every language.
CONFLICTS=$(jq -r -s '[.[].tables.Localizable // [] | .[]] | group_by(.key)
    | map(select((map(.value) | unique | length) > 1))
    | .[] | "  \(.[0].key): " + (map(.value) | unique | map("\"\(.)\"") | join(", "))' \
    "$WORK"/*.stringsdata)
if [ -n "$CONFLICTS" ]; then
    echo "error: a key is used with more than one default value — give each its own key, or unify the macros:" >&2
    echo "$CONFLICTS" >&2
    exit 1
fi

# TRAP: an Xcode build emits no .stringsdata for ObjC, so Xcode's catalog pass
# sees every key as unreferenced and WRITES stale marks into the checked-in
# catalog. extractionState "manual" makes Xcode leave a key alone, but sync
# skips manual keys too. Hence the sandwich: unshield() strips the marks, sync
# updates comments, adds keys and marks dead ones stale, and normalize()
# re-shields every key that is not stale. A stale key stays visible (in --check
# diffs and as one Xcode warning) until it is deleted from the catalog.
unshield() {
    local file="$1" tmp="$1.tmp"
    jq --indent 2 '
        .strings |= map_values(
            if .extractionState == "manual" then del(.extractionState) else . end
        )
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# The extracted English defaults, key → value. sync stamps a key's en value
# only on FIRST sight, so without normalize() copying these over a reworded
# default the catalog would serve the old English forever.
jq -s '[.[].tables.Localizable // [] | .[]] | map({(.key): .value}) | add // {}' \
    "$WORK"/*.stringsdata > "$WORK/envalues.json"

# sync marks new source-language units "new", and the compiler emits .strings
# only for "translated" ones, so en is promoted: without it the app ships no
# en.lproj/Localizable.strings. On a reword en is overwritten and every other
# language flips to "needs_review", which still compiles and ships.
#
# The write and --check paths run the same unshield/sync/normalize sequence,
# so jq's formatting is identical on both sides.
normalize() {
    local file="$1" tmp="$1.tmp"
    jq --indent 2 --slurpfile src "$WORK/envalues.json" '
        .strings |= with_entries(
            ($src[0][.key] // null) as $en |
            .value |= (
                (if .localizations.en.stringUnit.state == "new"
                 then .localizations.en.stringUnit.state = "translated"
                 else . end)
                | (if $en != null and .localizations.en.stringUnit.value != $en
                   then .localizations.en.stringUnit.value = $en
                        | (.localizations |= with_entries(
                              if .key == "en" then .
                              else .value.stringUnit.state = "needs_review" end))
                   else . end)
                # Delete-then-append, never update in place: sync places the
                # extractionState of a new key alphabetically, while the --check
                # round trip appends it, a spurious diff on every fresh key.
                | .extractionState as $st
                | del(.extractionState)
                | (if $st == "stale"
                   then .extractionState = "stale"
                   else .extractionState = "manual" end)
            )
        )
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# The widget's subset. The extension resolves strings against its own bundle
# (the TRAP in Vibe/iOS/Widget/VibeWidgetIntents.swift), so
# VibeWidget/Localizable.xcstrings carries the widget.* keys, DERIVED here and
# never authored; the same basename keeps the table name. Not a
# check-translations catalog, since every key would report twice. A widget
# source reaching for any other key would fall back to English silently, so
# the prefix is checked.
WIDGET_CATALOG="$REPO_ROOT/VibeWidget/Localizable.xcstrings"
widget_subset() {
    jq --indent 2 '.strings |= with_entries(select(.key | startswith("widget.")))' "$1" > "$2"
}
STRAY=$(grep -rhoE 'STR_[A-Z_]+|LocalizedStringResource\("[^"]+"' \
            "$REPO_ROOT/VibeWidget" "$REPO_ROOT/Vibe/iOS/Widget" \
        | sort -u | grep -vE '^STR_WIDGET_|^LocalizedStringResource\("widget\.' || true)
if [ -n "$STRAY" ]; then
    echo "error: widget sources reference keys outside widget.*, which the widget's own catalog does not carry:" >&2
    echo "$STRAY" | sed 's/^/  /' >&2
    exit 1
fi

# A translation whose format specifiers differ from the English draws a
# literal %@, or crashes on a type it was not given. Rewording a default keeps
# its key and its translations, so a reword that adds or drops a specifier, or
# moves the string to another surface, needs a NEW key. Run on both paths: the
# mismatch is made by `make strings`, whose author should hear of it there.
check_specifiers() {
    local mismatched
    mismatched=$(jq -r '
        def specs: [scan("%(?:[0-9]+\\$)?(?:@|l{0,2}[dui]|[sf]|\\.[0-9]+f)") | sub("[0-9]+\\$"; "")] | sort;
        .strings | to_entries[]
        | .key as $k | (.value.localizations // {}) as $l
        | (($l.en.stringUnit.value // "") | specs) as $en
        | [$l | to_entries[] | select(.key != "en")
              | select(((.value.stringUnit.value // "") | specs) != $en) | .key]
        | select(length > 0) | "  \($k): \(join(" "))"' "$1")
    if [ -n "$mismatched" ]; then
        echo "error: translations whose format specifiers differ from the English (give the reworded string a new key):" >&2
        echo "$mismatched" >&2
        exit 1
    fi
}

if [ "${1:-}" = "--check" ]; then
    # The copy MUST keep the catalog's basename, which names its table: under
    # any other name sync sees an empty table and strips every key.
    mkdir -p "$WORK/check"
    cp "$CATALOG" "$WORK/check/"
    COPY="$WORK/check/$(basename "$CATALOG")"
    unshield "$COPY"
    xcrun xcstringstool sync "$COPY" --stringsdata "$WORK"/*.stringsdata
    normalize "$COPY"
    if ! diff -u "$CATALOG" "$COPY"; then
        echo "error: Localizable.xcstrings is out of date — run: make strings" >&2
        exit 1
    fi
    widget_subset "$COPY" "$WORK/check/widget.xcstrings"
    if ! diff -u "$WIDGET_CATALOG" "$WORK/check/widget.xcstrings"; then
        echo "error: VibeWidget/Localizable.xcstrings is out of date — run: make strings" >&2
        exit 1
    fi
    check_specifiers "$CATALOG"
    echo "🔊 string catalogs are in sync"
else
    unshield "$CATALOG"
    xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/*.stringsdata
    normalize "$CATALOG"
    widget_subset "$CATALOG" "$WIDGET_CATALOG"
    check_specifiers "$CATALOG"
    echo "🔊 $(jq '.strings | length' "$CATALOG") keys in Localizable.xcstrings, $(jq '.strings | length' "$WIDGET_CATALOG") of them in the widget's"
fi
