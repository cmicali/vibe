#!/bin/bash
# Brings cm_libs/ in for a fresh clone or worktree, and says when its checkout
# is not the commit this repo pins. It never moves a checkout already there,
# because that may be work in progress on a piece.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ ! -f cm_libs/cm_libs.yml ]; then
    git submodule update --init --recursive cm_libs
    exit 0
fi

pinned=$(git ls-files --stage cm_libs | awk '{print $2}')
current=$(git -C cm_libs rev-parse HEAD)
if [ -n "$pinned" ] && [ "$pinned" != "$current" ]; then
    echo "note: cm_libs/ is at ${current:0:8}, but this checkout pins ${pinned:0:8}." >&2
    echo "      'git submodule update cm_libs' moves it to the pinned commit." >&2
fi
