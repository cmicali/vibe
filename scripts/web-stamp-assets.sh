#!/usr/bin/env bash
#
# Stamp each asset's content hash into every page that references it: the
# stylesheet, and each image under img/.
#
#   scripts/web-stamp-assets.sh [--check]
#
# Cloudflare Pages ignores Cache-Control from _headers, so after a deploy a
# browser holding the old stylesheet or screenshot keeps drawing it until its
# TTL (four hours) runs out, which reads as a broken deploy. A hash in the
# query string changes the URL with the bytes, so no cache is consulted and the
# TTL can stay long. Images are hashed one by one, so changing one screenshot
# does not re-fetch the rest.
#
# --check verifies the stamps without writing; deploy-web.sh runs it.
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

# The path is taken as written, so privacy/'s relative ../img/ and 404.html's
# absolute /img/ both match.
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
