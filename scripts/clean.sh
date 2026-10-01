#!/usr/bin/env bash
#
# Remove build/ and the generated projects, Vibe.xcodeproj and
# VibeBenchComponents.xcodeproj. A path git tracks is skipped, so this cannot
# clobber a checked-in project.
set -euo pipefail

cd "$(dirname "$0")/.."

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

clean_path build
clean_path Vibe.xcodeproj
clean_path VibeBenchComponents.xcodeproj

echo "🔊 cleaned"
