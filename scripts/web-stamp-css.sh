#!/usr/bin/env bash
#
# Stamp the stylesheet's content hash into every page that links it.
#
#   scripts/web-stamp-css.sh [--check]
#
# The stylesheet and the markup are deployed together and have to expire
# together, but Cloudflare Pages manages caching for its own assets and ignores
# Cache-Control from _headers. Fixing the TTL at the edge only helps the next
# fetch — a browser already holding a copy under the old four-hour TTL will not
# ask again until it expires, so a layout change renders under the old rules
# for hours.
#
# A content hash in the query string sidesteps all of it: change the stylesheet
# and the URL changes, so no cache anywhere is consulted. It also lets the TTL
# be long rather than zero, since a given URL's bytes never change.
#
# --check verifies the stamp is current without writing, for deploy-web.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

CSS="Assets/Web/styles.css"
[[ -f "$CSS" ]] || { echo "error: $CSS not found" >&2; exit 1; }

HASH="$(shasum -a 256 "$CSS" | cut -c1-10)"
CHECK=""
[[ "${1:-}" == "--check" ]] && CHECK=1
[[ -n "${1:-}" && "${1:-}" != "--check" ]] && {
    echo "usage: scripts/web-stamp-css.sh [--check]" >&2; exit 64; }

STALE=0
while IFS= read -r page; do
    current="$(perl -ne 'print $1 if m{href="[./]*styles\.css(?:\?v=([0-9a-f]*))?"}' "$page")"
    if [[ "$current" != "$HASH" ]]; then
        STALE=1
        if [[ -n "$CHECK" ]]; then
            echo "  $page: v=${current:-none}, expected v=$HASH" >&2
        else
            perl -pi -e "s{href=\"([./]*styles\\.css)(\\?v=[0-9a-f]*)?\"}{href=\"\${1}?v=$HASH\"}" "$page"
            echo "🔊 stamped $page with v=$HASH"
        fi
    fi
done < <(grep -rl 'styles\.css' Assets/Web --include='*.html')

if [[ -n "$CHECK" ]]; then
    if [[ "$STALE" == 1 ]]; then
        echo "error: the stylesheet hash in the pages is out of date." >&2
        echo "       Run: scripts/web-stamp-css.sh" >&2
        exit 1
    fi
    echo "🔊 stylesheet stamp is current (v=$HASH)"
elif [[ "$STALE" == 0 ]]; then
    echo "🔊 stylesheet stamp already current (v=$HASH)"
fi
