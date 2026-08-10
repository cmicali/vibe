#!/bin/bash
# Print the catalog's language codes, one per line. The single source of truth
# for which languages the app ships — never hardcode the list (CLAUDE.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
jq -r '[.strings[].localizations // {} | keys[]] | unique[]' "$ROOT/Resources/Localizable.xcstrings"
