#!/bin/bash
#
# Extracts NSLocalizedString keys from an app's first-party Objective-C
# sources into its catalog. The app's config file names the registry, the
# catalog, and the sources (AGENTS.md).
#
#   extract-strings.sh <config>            update the catalog in place
#   extract-strings.sh <config> --check    fail if the catalog is out of date
#
# NOT a build phase, deliberately: the build has no String Catalog extraction
# for Objective-C (clang emits .stringsdata for Swift only; the only xcstrings
# build task is `compile`), and a phase rewriting a checked-in file would flip
# VIBE_GIT_DIRTY on every build.

set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $(basename "$0") <config> [--check]" >&2; exit 2; }
# shellcheck source=/dev/null
source "$1"
ROOT="$(cd "$(dirname "$1")/$STRINGS_ROOT" && pwd)"
CATALOG="$ROOT/$STRINGS_CATALOG"
REGISTRY="$ROOT/$STRINGS_REGISTRY"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. Expand the registry through the C preprocessor.
#
# xcstringstool matches localization macros by name AND arity, and the
# three-argument NSLS(key, value, comment) fits no stock shape, even with
# `-s NSLS`: extraction silently yields zero keys. So extract from `clang -E` of
# a throwaway TU referencing every registry macro, which is exact and fails
# loudly on a malformed entry where a regex over the header would quietly
# mis-parse.
{
    printf '#import "%s"\n' "$REGISTRY"
    printf 'static id vibe_registry_[] = {\n'
    grep -oE "^#define[[:space:]]+${STRINGS_MACROS}[A-Za-z0-9_]+" "$REGISTRY" | awk '{print $2 ","}'
    printf '};\n'
} > "$WORK/registry.m"

if ! grep -q "$STRINGS_MACROS" "$WORK/registry.m"; then
    echo "error: no ${STRINGS_MACROS}* macros found in $REGISTRY" >&2
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
# NSLocalizedString cannot hide; the registry itself would only warn
# "non-literal key". (No mapfile: bash 3.2. There an empty array under set -u
# is an error, hence the ${a[@]+...} spelling.)
ROOTS=()
for dir in "${STRINGS_SOURCES[@]}"; do
    ROOTS+=("$ROOT/$dir")
done
SKIP=()
for pattern in ${STRINGS_SKIP[@]+"${STRINGS_SKIP[@]}"}; do
    SKIP+=(-not -path "$pattern")
done
SOURCES=("$WORK/registry-expanded.m")
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "${ROOTS[@]}" \( -name '*.m' -o -name '*.mm' -o -name '*.h' \) \
             ${SKIP[@]+"${SKIP[@]}"} \
             -not -path "$REGISTRY" -print0 | sort -z)

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
# The subset, when the config names one. An app extension resolves strings
# against its own bundle, so its catalog carries the keys under one prefix,
# DERIVED here and never authored; the same basename keeps the table name. Not
# a check-translations catalog, since every key would report twice. A subset
# source reaching for any other key would fall back to English silently, so
# the prefix is checked.
SUBSET="${STRINGS_SUBSET:-}"
subset() {
    jq --indent 2 --arg keys "$STRINGS_SUBSET_KEYS" \
        '.strings |= with_entries(select(.key | startswith($keys)))' "$1" > "$2"
}
if [ -n "$SUBSET" ]; then
    SUBSET_CATALOG="$ROOT/$STRINGS_SUBSET_CATALOG"
    SUBSET_ROOTS=()
    for dir in "${STRINGS_SUBSET_SOURCES[@]}"; do
        SUBSET_ROOTS+=("$ROOT/$dir")
    done
    KEYS_PATTERN=$(printf '%s' "$STRINGS_SUBSET_KEYS" | sed 's/\./\\./g')
    STRAY=$(grep -rhoE "${STRINGS_MACROS}[A-Z_]+|LocalizedStringResource\\(\"[^\"]+\"" "${SUBSET_ROOTS[@]}" \
            | sort -u | grep -vE "^${STRINGS_SUBSET_MACROS}|^LocalizedStringResource\\(\"${KEYS_PATTERN}" || true)
    if [ -n "$STRAY" ]; then
        echo "error: $SUBSET sources reference keys outside ${STRINGS_SUBSET_KEYS}*, which the $SUBSET's own catalog does not carry:" >&2
        echo "$STRAY" | sed 's/^/  /' >&2
        exit 1
    fi
fi

# Keep translations compatible with the arguments at each call site.
# A change to the argument list needs a new key.
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

if [ "${2:-}" = "--check" ]; then
    # The copy MUST keep the catalog's basename, which names its table: under
    # any other name sync sees an empty table and strips every key.
    mkdir -p "$WORK/check"
    cp "$CATALOG" "$WORK/check/"
    COPY="$WORK/check/$(basename "$CATALOG")"
    unshield "$COPY"
    xcrun xcstringstool sync "$COPY" --stringsdata "$WORK"/*.stringsdata
    normalize "$COPY"
    if ! diff -u "$CATALOG" "$COPY"; then
        echo "error: $(basename "$CATALOG") is out of date — run: $STRINGS_UPDATE" >&2
        exit 1
    fi
    if [ -n "$SUBSET" ]; then
        subset "$COPY" "$WORK/check/subset.xcstrings"
        if ! diff -u "$SUBSET_CATALOG" "$WORK/check/subset.xcstrings"; then
            echo "error: $STRINGS_SUBSET_CATALOG is out of date — run: $STRINGS_UPDATE" >&2
            exit 1
        fi
    fi
    check_specifiers "$CATALOG"
    echo "🔊 string catalogs are in sync"
else
    unshield "$CATALOG"
    xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/*.stringsdata
    normalize "$CATALOG"
    SUMMARY="$(jq '.strings | length' "$CATALOG") keys in $(basename "$CATALOG")"
    if [ -n "$SUBSET" ]; then
        subset "$CATALOG" "$SUBSET_CATALOG"
        SUMMARY="$SUMMARY, $(jq '.strings | length' "$SUBSET_CATALOG") of them in the $SUBSET's"
    fi
    check_specifiers "$CATALOG"
    echo "🔊 $SUMMARY"
fi
