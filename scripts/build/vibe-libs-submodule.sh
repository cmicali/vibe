#!/bin/bash
# Brings vibe-libs/ in for a fresh clone or worktree, and says when its checkout
# is not the commit this repo pins. It never moves a checkout already there,
# because that may be work in progress on a piece.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ ! -f vibe-libs/vibe-libs.yml ]; then
    git submodule update --init --recursive vibe-libs
    exit 0
fi

pinned=$(git ls-files --stage vibe-libs | awk '{print $2}')
current=$(git -C vibe-libs rev-parse HEAD)
if [ -n "$pinned" ] && [ "$pinned" != "$current" ]; then
    echo "note: vibe-libs/ is at ${current:0:8}, but this checkout pins ${pinned:0:8}." >&2
    echo "      'git submodule update vibe-libs' moves it to the pinned commit." >&2
fi
