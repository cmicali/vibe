#!/usr/bin/env bash
#
# Point the web page's Download button at a release.
#
#   scripts/web-set-version.sh <version>        # e.g. 1.10
#
# From one URL, rewrites Assets/Web/index.html's button href and version label,
# its JSON-LD softwareVersion and downloadUrl, and the /download rules in
# Assets/Web/_redirects (vibeplayer.app/download/latest), so the page, the
# branded link and the file cannot disagree. github-release.sh runs it.
#
# A direct .dmg URL, not /releases/latest/download: the asset name carries the
# version, and that shortcut only redirects to a fixed filename. So the link is
# correct only while something rewrites it.
#
# Edits key on element ids and JSON property names, and any one that fails to
# match is an error: a page that advertises one version and links another is
# worse than a stale one.
set -euo pipefail

cd "$(dirname "$0")/.."

PAGE="Assets/Web/index.html"
REDIRECTS="Assets/Web/_redirects"
REDIRECT_RULES=3                       # /download, /download/, /download/latest
VERSION="${1:-}"

[[ -n "$VERSION" ]] || {
    echo "usage: scripts/web-set-version.sh <version>   (e.g. 1.10)" >&2
    exit 64
}
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
    echo "error: '$VERSION' is not a version number like 1.10" >&2
    exit 64
}
[[ -f "$PAGE" ]] || {
    echo "error: $PAGE not found" >&2
    exit 1
}
[[ -f "$REDIRECTS" ]] || {
    echo "error: $REDIRECTS not found" >&2
    exit 1
}

URL="https://github.com/cmicali/vibe/releases/download/v$VERSION/Vibe-macOS-universal-$VERSION.dmg"

BEFORE="$(cat "$PAGE" "$REDIRECTS")"

perl -0pi -e "s{(id=\"dmg-link\"\\s+href=\")[^\"]*(\")}{\${1}$URL\${2}}" "$PAGE"
perl -0pi -e "s{(id=\"dmg-version\">)[^<]*(</span>)}{\${1}v$VERSION\${2}}" "$PAGE"
perl -0pi -e "s{(\"softwareVersion\": \")[^\"]*(\")}{\${1}$VERSION\${2}}" "$PAGE"
perl -0pi -e "s{(\"downloadUrl\": \")[^\"]*(\")}{\${1}$URL\${2}}" "$PAGE"

grep -q "href=\"$URL\"" "$PAGE" || {
    echo "error: the href rewrite did not match — has the Download button's markup changed?" >&2
    echo "       expected an element with id=\"dmg-link\" carrying an href." >&2
    exit 1
}
grep -q "id=\"dmg-version\">v$VERSION<" "$PAGE" || {
    echo "error: the version label rewrite did not match — expected id=\"dmg-version\"." >&2
    exit 1
}
grep -q "\"softwareVersion\": \"$VERSION\"" "$PAGE" || {
    echo "error: the JSON-LD softwareVersion rewrite did not match." >&2
    exit 1
}
grep -q "\"downloadUrl\": \"$URL\"" "$PAGE" || {
    echo "error: the JSON-LD downloadUrl rewrite did not match." >&2
    exit 1
}

# Keyed on the path column and the 302. The count is asserted: a rule that
# stopped matching would leave the branded link on the previous release.
perl -0pi -e "s{^(/download\\S*\\s+)\\S+\\s+302\$}{\${1}$URL   302}mg" "$REDIRECTS"

FOUND="$(grep -c "^/download.*[[:space:]]$URL[[:space:]]*302\$" "$REDIRECTS" || true)"
if [[ "$FOUND" != "$REDIRECT_RULES" ]]; then
    echo "error: rewrote $FOUND of $REDIRECT_RULES /download rules in $REDIRECTS." >&2
    echo "       Each must read: /<path>  <url>  302" >&2
    exit 1
fi

if [[ "$BEFORE" == "$(cat "$PAGE" "$REDIRECTS")" ]]; then
    echo "🔊 web page already points at v$VERSION"
else
    echo "🔊 web page now points at v$VERSION"
fi
echo "   $URL"
echo "   https://vibeplayer.app/download/latest redirects there"
