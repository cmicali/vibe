#!/usr/bin/env bash
#
# Stamp each asset's content hash into every page that references it —
# the stylesheet, and every image under img/.
#
#   scripts/web-stamp-assets.sh [--check]
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
# IMAGES HAVE THE SAME PROBLEM, and used to have none of the fix. The 1.12
# screenshots were re-derived and deployed, the CDN served the new bytes
# immediately (cf-cache-status: REVALIDATED), and browsers that had visited
# before kept drawing the old ones for the rest of the four hours — which reads
# as a broken deploy rather than a cache. Each image is hashed on its own, so
# changing one screenshot does not re-fetch the rest.
#
# --check verifies the stamps are current without writing, for deploy-web.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

CSS="Assets/Web/styles.css"
[[ -f "$CSS" ]] || { echo "error: $CSS not found" >&2; exit 1; }

HASH="$(shasum -a 256 "$CSS" | cut -c1-10)"
CHECK=""
[[ "${1:-}" == "--check" ]] && CHECK=1
[[ -n "${1:-}" && "${1:-}" != "--check" ]] && {
    echo "usage: scripts/web-stamp-assets.sh [--check]" >&2; exit 64; }

STALE=0

# Rewrites one reference in one page, or reports it under --check.
stamp() { # <page> <attr> <path-as-written> <hash>
    local page="$1" attr="$2" ref="$3" hash="$4" current
    current="$(perl -ne "print \$1 if m{$attr=\"\Q$ref\E(?:\\?v=([0-9a-f]*))?\"}" "$page")"
    [[ "$current" == "$hash" ]] && return 0
    STALE=1
    if [[ -n "$CHECK" ]]; then
        echo "  $page: $ref v=${current:-none}, expected v=$hash" >&2
    else
        perl -pi -e "s{$attr=\"\Q$ref\E(\\?v=[0-9a-f]*)?\"}{$attr=\"$ref?v=$hash\"}g" "$page"
        echo "🔊 stamped $page $ref v=$hash"
    fi
}

while IFS= read -r page; do
    stamp "$page" href "$(perl -ne 'print $1 if m{href="([./]*styles\.css)(?:\?v=[0-9a-f]*)?"}' "$page")" "$HASH"
done < <(grep -rl 'styles\.css' Assets/Web --include='*.html')

# Every img/ reference, hashed per file. The path is taken as written so a
# relative ../img/ in privacy/ and an absolute /img/ in 404.html both match.
while IFS= read -r line; do
    page="${line%%:*}"; rest="${line#*:}"
    attr="${rest%%=*}"; ref="${rest#*=\"}"; ref="${ref%\"}"
    ref="${ref%%\?v=*}"
    file="Assets/Web/$(printf '%s' "$ref" | sed 's|^/||; s|^\.\./||')"
    [[ "$page" == *"/privacy/"* && "$ref" != /* && "$ref" != ../* ]] && file="Assets/Web/privacy/$ref"
    [[ -f "$file" ]] || { echo "error: $page references $ref but $file does not exist" >&2; exit 1; }
    stamp "$page" "$attr" "$ref" "$(shasum -a 256 "$file" | cut -c1-10)"
done < <(grep -roE '(src|href|srcset)="[^"]*img/[^"]+"' Assets/Web --include='*.html' | sort -u)

if [[ -n "$CHECK" ]]; then
    if [[ "$STALE" == 1 ]]; then
        echo "error: asset hashes in the pages are out of date." >&2
        echo "       Run: scripts/web-stamp-assets.sh" >&2
        exit 1
    fi
    echo "🔊 asset stamps are current"
elif [[ "$STALE" == 0 ]]; then
    echo "🔊 asset stamps already current"
fi
