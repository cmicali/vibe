#!/bin/bash
# Print the catalog's language codes, one per line: the single source of truth
# for which languages the app ships. Never hardcode the list.
#   catalog-languages.sh <config>
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $(basename "$0") <config>" >&2; exit 2; }
# shellcheck source=/dev/null
source "$1"
ROOT="$(cd "$(dirname "$1")/$STRINGS_ROOT" && pwd)"
jq -r '[.strings[].localizations // {} | keys[]] | unique[]' "$ROOT/$STRINGS_CATALOG"
