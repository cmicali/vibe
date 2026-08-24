#!/usr/bin/env bash
#
# Point the marketing page's Download button at a specific release.
#
#   scripts/web-set-version.sh <version>        # e.g. 1.10
#
# Rewrites the four places in Assets/Web/index.html that name a version: the
# button's href and the label under it, and the softwareVersion and downloadUrl
# of the JSON-LD block that search engines and agents read. github-release.sh calls this with
# the version it just published, so the number the page advertises and the file
# it hands you can never disagree.
#
# It rewrites the /download rules in Assets/Web/_redirects from that same URL,
# which is what makes vibeplayer.app/download/latest a stable link anyone may
# publish. Same URL, one source: the branded link and the button cannot come
# to name different builds.
#
# The page hardcodes a direct .dmg URL rather than /releases/latest because the
# asset name carries the version — Vibe-macOS-<version>.dmg — and GitHub's
# latest/download shortcut only redirects for a filename that never changes.
# A direct link is therefore correct exactly as long as something rewrites it,
# which is this script's whole job.
#
# The edits key on element ids and JSON property names, not on the markup
# around them, so restyling the button or reordering the JSON does not silently
# stop the rewrite. Any one failing to match is an error, never a silent no-op:
# a page that advertises one version and links another is worse than a stale
# one, and the JSON-LD is the copy no human proofreads.
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

URL="https://github.com/cmicali/vibe/releases/download/v$VERSION/Vibe-macOS-$VERSION.dmg"

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

# The /download* rules in _redirects. Keyed on the path column and the 302,
# so the target may be swapped without the rule text being reproduced here;
# the count is asserted because a rule that stopped matching would leave the
# branded link pointing at the previous release while the button moved on.
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
