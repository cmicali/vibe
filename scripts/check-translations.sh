#!/bin/bash
#
# Fail if any catalog key is missing a translation. Required before either
# release path — see release.sh / release-appstore.sh.
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
# language required everywhere.
#
# Usage: scripts/check-translations.sh   (or: make check-translations)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/Resources/Localizable.xcstrings"

LANGS=$("$ROOT/scripts/catalog-languages.sh" | jq -Rn '[inputs]')
COUNT=$(jq -r 'length' <<<"$LANGS")

MISSING=$(jq -r --argjson all "$LANGS" '
    .strings | to_entries[]
    | {key: .key, missing: ($all - ((.value.localizations // {}) | keys))}
    | select(.missing | length > 0)
    | "  \(.key)  missing: \(.missing | join(", "))"
' "$CATALOG")

if [[ -n "$MISSING" ]]; then
    echo "error: untranslated keys in Resources/Localizable.xcstrings" >&2
    echo "$MISSING" >&2
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
REVIEW=$(jq -r '
    [.strings | to_entries[]
     | select((.value.localizations // {}) | to_entries[]
              | select(.key != "en" and .value.stringUnit.state == "needs_review"))
     | .key] | unique | length
' "$CATALOG")

echo "🔊 $(jq '.strings | length' "$CATALOG") keys translated into all $COUNT languages"
[[ "$REVIEW" -gt 0 ]] && echo "🔊 $REVIEW key(s) marked needs_review (reworded English; still shipping)"
exit 0
