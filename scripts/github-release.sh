#!/usr/bin/env bash
#
# Publish the notarized Developer ID build as a GitHub release.
#
#   scripts/github-release.sh [--draft]
#
# Takes the artifact `make release` produced (build/release/Vibe.zip), verifies
# the app inside really is the stapled copy, tags HEAD as v<version> and
# creates the release with the zip attached as vibe-macos-<arch>-<version>.zip
# (arch read from the binary itself: a single slice names it, several read as
# "universal").
#
# Deliberately a separate step from release.sh: building+notarizing is
# repeatable, publishing is not — a deleted release leaves the tag and any
# download links behind — so the irreversible half only runs when asked.
#
# The version comes from the built app's Info.plist (MARKETING_VERSION via
# project.yml), never from git, so the tag always names what the zip actually
# contains. Release notes are Assets/app-store/copy/en/whats-new.txt — the
# same file the App Store upload requires per release — so the two channels
# cannot drift.
#
# --draft creates the release unpublished, for a final look in the web UI.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="build/release"
APP="$BUILD_DIR/export/Vibe.app"
ZIP="$BUILD_DIR/Vibe.zip"
NOTES="Assets/app-store/copy/en/whats-new.txt"

DRAFT=""
case "${1:-}" in
    --draft) DRAFT="--draft" ;;
    "") ;;
    *) echo "usage: scripts/github-release.sh [--draft]" >&2; exit 64 ;;
esac

# ---------------------------------------------------------------------------
# Preflight — fail early with actionable messages.
# ---------------------------------------------------------------------------
command -v gh >/dev/null || {
    echo "error: gh (GitHub CLI) is not installed — brew bundle installs it (see Brewfile)" >&2
    exit 1
}
gh auth status >/dev/null 2>&1 || {
    echo "error: gh is not authenticated — run: gh auth login" >&2
    exit 1
}
[[ -f "$ZIP" && -d "$APP" ]] || {
    echo "error: no release artifact at $ZIP — run 'make release' first" >&2
    exit 1
}
[[ -s "$NOTES" ]] || {
    echo "error: $NOTES is missing or empty — write the release notes first" >&2
    exit 1
}

# Verify the zip holds the stapled app, not the pre-notarization packaging —
# release.sh zips twice (once to submit, once after stapling), and uploading
# the first would ship a build Gatekeeper re-checks online.
STAPLE_TMP="$(mktemp -d)"
trap 'rm -rf "$STAPLE_TMP"' EXIT
ditto -x -k "$ZIP" "$STAPLE_TMP"
xcrun stapler validate "$STAPLE_TMP/Vibe.app" >/dev/null || {
    echo "error: the app inside $ZIP is not stapled — re-run 'make release'" >&2
    exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STAPLE_TMP/Vibe.app/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$STAPLE_TMP/Vibe.app/Contents/Info.plist")"
TAG="v$VERSION"

# The tag is created on HEAD, so HEAD must be what the remote will see.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "warning: working tree is dirty — the release tags HEAD, not these changes" >&2
fi
git fetch -q origin
if [[ -z "$(git branch -r --contains HEAD 2>/dev/null)" ]]; then
    echo "error: HEAD is not pushed — the tag would dangle. Push first." >&2
    exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "error: release $TAG already exists — bump MARKETING_VERSION in project.yml and rebuild" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
        && [[ "$(git rev-parse "refs/tags/$TAG^{commit}")" != "$(git rev-parse HEAD)" ]]; then
    echo "error: tag $TAG exists and does not point at HEAD" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Publish.
# ---------------------------------------------------------------------------
# Name the asset by what the binary actually contains, not by assumption:
# one slice names its arch, more collapse to "universal".
ARCHS="$(lipo -archs "$STAPLE_TMP/Vibe.app/Contents/MacOS/Vibe")"
if [[ "$ARCHS" == *" "* ]]; then ARCH="universal"; else ARCH="$ARCHS"; fi

ASSET="$BUILD_DIR/vibe-macos-$ARCH-$VERSION.zip"
cp "$ZIP" "$ASSET"

echo "🔊 releasing $TAG (build $BUILD) at $(git rev-parse --short HEAD)"
gh release create "$TAG" \
    "$ASSET#Vibe $VERSION (macOS, notarized)" \
    --title "Vibe $VERSION" \
    --notes-file "$NOTES" \
    --target "$(git rev-parse HEAD)" \
    ${DRAFT:+"$DRAFT"}

echo "🔊 done"
gh release view "$TAG" --json url -q .url
