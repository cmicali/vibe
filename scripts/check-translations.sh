#!/bin/bash
#
# Fail if any catalog key is missing a translation. Covers BOTH catalogs —
# Localizable.xcstrings and InfoPlist.xcstrings. Required before either
# release path — see release.sh / release-appstore.sh.
#
# InfoPlist.xcstrings fails the same silent way and is easier to forget: its
# keys are the bundle name, the copyright and the CFBundleTypeName values, so
# a missing one means Launch Services shows an English document-type name in
# that locale — visible in the Finder's Get Info and Open With, and nowhere in
# the app to notice while testing.
#
# Nothing else catches this. `make check-strings` is a round-trip diff: it
# re-runs sync+normalize on a copy and diffs, so it answers "does the catalog
# match the source", and sync never writes a language other than en — a key
# with only an en unit round-trips byte-identically and passes. The build is no
# better: `xcstringstool compile` exits 0 on a partial key and just emits an
# xx.lproj without it, so the lookup misses at runtime and falls through to the
# macro's default value, rendering English in that locale only. Silent in both
# directions, which is how 1.9 shipped 8 keys as English in 29 locales.
#
# The test is "missing any catalog language", NOT "has only en". A key
# spike-translated into el/de/ru to check layout (Greek and German are the
# expansion-heavy ones) passes an only-en test while the other 27 languages
# never get written — the worse failure, because the key looks done.
#
# The language set is the union across all keys (catalog-languages.sh), so it
# defines itself: the first key translated into a new language makes that
# language required everywhere. The converse is the blind spot — a language
# deleted from EVERY key leaves the union and the check goes quiet. Accepted:
# the repo has no other source of truth for the list (knownRegions is
# (Base, en) and gates nothing), and losing a language wholesale is a
# deliberate act, not the drift this is guarding against.
#
# Usage:
#   scripts/check-translations.sh            fail on any missing translation
#                                            (or: make check-translations)
#   scripts/check-translations.sh --github   report only, always exit 0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOGS=("$ROOT/Resources/Localizable.xcstrings" "$ROOT/Resources/InfoPlist.xcstrings")

GITHUB_MODE=0
case "${1:-}" in
    --github) GITHUB_MODE=1 ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--github]" >&2; exit 2 ;;
esac

LANGS=$("$ROOT/scripts/catalog-languages.sh" | jq -Rn '[inputs]')
LANG_COUNT=$(jq -r 'length' <<<"$LANGS")

# One pass over both catalogs, rendered two ways below. Both the human list and
# the CI annotations come off this JSON rather than off each other's text — a
# report mode that re-parsed the human output would break silently the next
# time it is reworded. Each entry carries its catalog, because "which file" is
# the first thing you need in order to fix one.
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
        # Warn, never fail. Untranslated keys are the expected state between a
        # feature landing and the translation batch at the release cut, so a
        # hard failure here would leave main red for that whole window and
        # train everyone to ignore it. The release scripts are the gate; CI
        # only keeps the worklist visible.
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
# language to needs_review by design, and those units still compile and ship
# the old translation. Worth surfacing, never worth blocking a release on.
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
