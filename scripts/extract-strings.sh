#!/bin/bash
#
# Extracts NSLocalizedString keys from the first-party Objective-C sources into
# Resources/Localizable.xcstrings.
#
#   scripts/extract-strings.sh            update the catalog in place
#   scripts/extract-strings.sh --check    fail if the catalog is out of date
#
# NOT a build phase, deliberately. Two reasons:
#
#   1. There IS no build-time String Catalog sync for Objective-C. The only
#      xcstrings task in the build system is `xcstringstool compile`; the
#      extract side rides on .stringsdata files, which clang emits for Swift
#      only (SWIFT_EMIT_LOC_STRINGS). So the build compiles the catalog but can
#      never populate it — that has to happen here.
#   2. A phase that rewrote a checked-in file on every build would dirty the
#      tree, including flipping the VIBE_GIT_DIRTY flag that
#      generate-git-info.sh stamps into the startup log.
#
# Run it by hand after touching UI strings: `make strings` (and `make
# check-strings` in review to catch a catalog someone forgot to regenerate).
#
# The repo root comes from SRCROOT when Xcode runs it, else from this script's
# own location, so it works from any directory.

set -euo pipefail

REPO_ROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CATALOG="$REPO_ROOT/Resources/Localizable.xcstrings"
REGISTRY="$REPO_ROOT/Vibe/Common/Strings.h"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. Expand the registry through the C preprocessor.
#
# Strings.h declares its entries as NSLS(key, value, comment) — a three-argument
# shape the extractor cannot see: xcstringstool matches localization macros by
# name AND arity, and even `-s NSLS` only teaches it the stock shapes
# ((key, comment), (key, tbl, comment), (key, tbl, bundle, val, comment)). A
# three-argument macro matches none, and extraction silently yields zero keys.
#
# So hand it the expansion instead of the source. Building a throwaway
# translation unit that references every STR_* and running `clang -E` gives the
# real preprocessor's answer — exact, and it fails loudly on a malformed entry,
# where a regex over the header would quietly mis-parse. The only pattern
# matched here is the macro NAME on a #define line, never string content.
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

xcrun clang -E -P -x objective-c "$WORK/registry.m" > "$WORK/registry-expanded.m"

# ---------------------------------------------------------------------------
# 2. Extract.
#
# The expanded registry supplies every real key. Every other first-party source
# is still swept so a stray inline NSLocalizedString outside the registry can't
# hide from the catalog — Strings.h itself is excluded because its unexpanded
# NSLS lines only produce "non-literal key" warnings.
#
# ThirdParty/ is vendored (not ours to restyle) and Debug/ is the
# debug-build-only command channel, whose strings are JSON keys and CLI replies
# — never localized. Paths are NUL-separated because "Vibe/Main Window"
# contains a space. (No mapfile: macOS ships bash 3.2.)
SOURCES=("$WORK/registry-expanded.m")
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$REPO_ROOT/Vibe" \( -name '*.m' -o -name '*.mm' -o -name '*.h' \) \
             -not -path '*/ThirdParty/*' -not -path '*/Debug/*' \
             -not -path "$REGISTRY" -print0 | sort -z)
SOURCES+=("$REPO_ROOT/main.m")

# --legacy-localizable-strings is the genstrings-compatible mode: NSLocalizedString
# and its siblings, which is what NSLS expands to.
xcrun xcstringstool extract "${SOURCES[@]}" \
    --legacy-localizable-strings \
    --output-directory "$WORK"

# extract writes one .stringsdata per table; with a single Localizable table
# that is one file, but glob for all of them so adding a table can't silently
# drop keys.
if ! ls "$WORK"/*.stringsdata >/dev/null 2>&1; then
    echo "error: no .stringsdata produced — extraction found nothing" >&2
    exit 1
fi

# sync marks freshly extracted source-language values "new", and the XCStrings
# compiler emits a .strings file only for units marked "translated" — so
# without this the app would ship no en.lproj/Localizable.strings at all and
# every lookup would fall through to the macro's default value. The English
# here IS the reviewed source (it was written by hand in Strings.h), so promote
# it and let the catalog be authoritative at runtime too.
#
# Both the write and the check path run this, so the formatting jq imposes is
# identical on both sides and --check compares like with like.
# It also drops "extractionState": "extracted_with_value", which sync stamps on
# a key the first time it sees it and then removes on the next pass once the
# catalog already matches — leaving it in would make the first `make strings`
# after adding a string disagree with the second. "stale" (source no longer
# references the key) and "manual" are kept: those carry real information.
normalize() {
    local file="$1" tmp="$1.tmp"
    jq --indent 2 '
        .strings |= map_values(
            (if .localizations.en.stringUnit.state == "new"
             then .localizations.en.stringUnit.state = "translated"
             else . end)
            | (if .extractionState == "extracted_with_value"
               then del(.extractionState)
               else . end)
        )
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

if [ "${1:-}" = "--check" ]; then
    # The copy MUST keep the catalog's filename: xcstringstool matches a
    # catalog to its .stringsdata by table name, which comes from the file's
    # basename. A copy named anything else looks like an empty table and sync
    # strips every key. Hence a subdirectory rather than a renamed file.
    mkdir -p "$WORK/check"
    cp "$CATALOG" "$WORK/check/"
    COPY="$WORK/check/$(basename "$CATALOG")"
    xcrun xcstringstool sync "$COPY" --stringsdata "$WORK"/*.stringsdata
    normalize "$COPY"
    if ! diff -u "$CATALOG" "$COPY"; then
        echo "error: Localizable.xcstrings is out of date — run: make strings" >&2
        exit 1
    fi
    echo "🔊 string catalog is in sync"
else
    xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/*.stringsdata
    normalize "$CATALOG"
    echo "🔊 $(jq '.strings | length' "$CATALOG") keys in Localizable.xcstrings"
fi
