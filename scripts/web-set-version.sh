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

URL="https://github.com/cmicali/vibe/releases/download/v$VERSION/Vibe-macOS-$VERSION.dmg"

BEFORE="$(cat "$PAGE")"

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

if [[ "$BEFORE" == "$(cat "$PAGE")" ]]; then
    echo "🔊 web page already points at v$VERSION"
else
    echo "🔊 web page now points at v$VERSION"
fi
echo "   $URL"
