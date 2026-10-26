#!/usr/bin/env bash
#
# Remove build/ and the generated projects, Vibe.xcodeproj and
# VibeBenchComponents.xcodeproj. A path git tracks is skipped, so this cannot
# clobber a checked-in project.
#
# Usage: scripts/build/clean.sh [--all]
#   A slotted shell (scripts/vibe-env.sh) removes only its slot's DerivedData,
#   so another session's build tree survives. --all removes everything.
set -euo pipefail

cd "$(dirname "$0")/../.."
. scripts/vibe-env.sh

case "${1:-}" in
    "") ALL=0 ;;
    --all) ALL=1 ;;
    *) echo "usage: scripts/build/clean.sh [--all]" >&2; exit 64 ;;
esac

clean_path() {
    local path="$1"
    [[ -e "$path" ]] || { echo "skip $path (absent)"; return 0; }
    if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
        echo "skip $path (tracked by git)"
        return 0
    fi
    rm -rf "$path"
    echo "🔊 removed $path"
}

if [[ "$ALL" == 0 && -n "$VIBE_SLOT" ]]; then
    clean_path "build/DerivedData-$VIBE_SLOT"
else
    clean_path build
    clean_path Vibe.xcodeproj
    clean_path VibeBenchComponents.xcodeproj
fi

echo "🔊 cleaned"
