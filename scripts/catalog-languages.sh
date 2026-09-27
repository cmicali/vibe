#!/bin/bash
# Print the catalog's language codes, one per line: the single source of truth
# for which languages the app ships. Never hardcode the list.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
jq -r '[.strings[].localizations // {} | keys[]] | unique[]' "$ROOT/Resources/Localizable.xcstrings"
