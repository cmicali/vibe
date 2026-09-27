#!/bin/bash
#
# Fail if any key in any catalog (CATALOGS below) is missing a catalog
# language. Both release paths run it.
#
# Nothing else catches this. `make check-strings` only asks whether the catalog
# matches the source, and sync never writes a language other than en; the
# build's `xcstringstool compile` exits 0 on a partial key, which then renders
# English in that locale only (1.9 shipped 8 keys as English in 29 locales).
# InfoPlist.xcstrings is the easy one to forget: a missing document-type name
# shows in English only in the Finder.
#
# The test is "missing any catalog language", NOT "has only en": a key
# spike-translated into a few languages to check layout must not pass.
#
# The language set is the union across all keys (catalog-languages.sh), so a
# language deleted from EVERY key silently stops being required. Accepted: no
# other source lists the languages, and that loss is deliberate, not drift.
#
# Usage:
#   scripts/check-translations.sh            fail on any missing translation
#                                            (or: make check-translations)
#   scripts/check-translations.sh --github   report only, always exit 0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOGS=("$ROOT/Resources/Localizable.xcstrings" "$ROOT/Resources/InfoPlist.xcstrings" "$ROOT/Resources/ThemeNames.xcstrings")

GITHUB_MODE=0
case "${1:-}" in
    --github) GITHUB_MODE=1 ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--github]" >&2; exit 2 ;;
esac

LANGS=$("$ROOT/scripts/catalog-languages.sh" | jq -Rn '[inputs]')
LANG_COUNT=$(jq -r 'length' <<<"$LANGS")

# One pass over every catalog, rendered two ways below, so the CI annotations
# never re-parse the human text.
REPORT=$(jq -sc --argjson all "$LANGS" '
    [.[] | .file as $file | .doc.strings | to_entries[]
     | {catalog: $file, key: .key,
        missing: ($all - ((.value.localizations // {}) | keys))}
     | select(.missing | length > 0)]
' <(for c in "${CATALOGS[@]}"; do
        jq -c --arg f "${c##*/}" '{file: $f, doc: .}' "$c"
    done))

LIST=$(jq -r '.[] | "  \(.catalog)  \(.key)  missing: \(.missing | join(", "))"' <<<"$REPORT")

if [[ -n "$LIST" ]]; then
    if (( GITHUB_MODE )); then
        # Warn, never fail: untranslated keys are expected between a feature
        # landing and the release-cut batch. The release scripts are the gate.
        echo "untranslated keys (pending the release-cut translation batch):"
        echo "$LIST"
        jq -r '.[] | "::warning title=Untranslated key::\(.catalog) \(.key) is missing \(.missing | join(", "))"' \
            <<<"$REPORT"
        if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
            {
                echo "### Translation coverage"
                echo
                echo "$(jq -r 'length' <<<"$REPORT") key(s) awaiting translation:"
                echo '```'
                echo "$LIST"
                echo '```'
            } >> "$GITHUB_STEP_SUMMARY"
        fi
        exit 0
    fi

    echo "error: untranslated catalog keys" >&2
    echo "$LIST" >&2
    cat >&2 <<'MSG'

  These ship rendering English in the locales listed. Translate them into the
  catalog (localizations.<lang>.stringUnit = {"state": "translated", …}), then
  run `make strings` to re-serialize canonically.
  The vibe-strings skill has the register, quote and terminology conventions.
MSG
    exit 1
fi

# needs_review is not a failure: a reworded English default flips every other
# language to it, and those units still ship the old translation.
REVIEW=$(jq -s -r '
    [.[] | .strings | to_entries[]
     | select((.value.localizations // {}) | to_entries[]
              | select(.key != "en" and .value.stringUnit.state == "needs_review"))
     | .key] | unique | length
' "${CATALOGS[@]}")

TOTAL=$(jq -s '[.[].strings | length] | add' "${CATALOGS[@]}")
echo "🔊 $TOTAL keys across ${#CATALOGS[@]} catalogs translated into all $LANG_COUNT languages"
[[ "$REVIEW" -gt 0 ]] && echo "🔊 $REVIEW key(s) marked needs_review (reworded English; still shipping)"
exit 0
