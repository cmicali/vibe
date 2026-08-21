#!/usr/bin/env bash
#
# Publish the notarized Developer ID build as a GitHub release.
#
#   scripts/github-release.sh [--draft]
#
# Takes the artifact `make release` produced (build/release/Vibe.dmg), verifies
# the image and the app inside it really are the stapled copies, tags HEAD as
# v<version> and creates the release with the image attached as
# vibe-macos-<arch>-<version>.dmg (arch read from the binary itself: a single
# slice names it, several read as "universal").
#
# Deliberately a separate step from release.sh: building+notarizing is
# repeatable, publishing is not — a deleted release leaves the tag and any
# download links behind — so the irreversible half only runs when asked.
#
# The version comes from the built app's Info.plist (MARKETING_VERSION via
# project.yml), never from git, so the tag always names what the image actually
# contains. Release notes are Assets/app-store/copy/en/whats-new.txt — the
# same file the App Store upload requires per release — so the two channels
# cannot drift.
#
# --draft creates the release unpublished, for a final look in the web UI.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="build/release"
APP="$BUILD_DIR/export/Vibe.app"
DMG="$BUILD_DIR/Vibe.dmg"
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
[[ -f "$DMG" && -d "$APP" ]] || {
    echo "error: no release artifact at $DMG — run 'make release' first" >&2
    exit 1
}
[[ -s "$NOTES" ]] || {
    echo "error: $NOTES is missing or empty — write the release notes first" >&2
    exit 1
}

# Verify BOTH staples on the artifact itself, by mounting it exactly as a
# recipient would. The image and the app inside it are notarized separately —
# release.sh staples the app before packaging and the image after — and either
# one missing means a download Gatekeeper re-checks online, which is precisely
# what stapling exists to avoid. Read the version out of the mounted app too,
# so the tag names what is really inside the image rather than what is sitting
# in the export directory beside it.
xcrun stapler validate "$DMG" >/dev/null || {
    echo "error: $DMG is not stapled — re-run 'make release'" >&2
    exit 1
}
MOUNT="$(mktemp -d)"
# The image must be detached before the mount point is removed, and both must
# happen however this script exits.
trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; rm -rf "$MOUNT"' EXIT
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet -readonly
MOUNTED_APP="$MOUNT/Vibe.app"
[[ -d "$MOUNTED_APP" ]] || {
    echo "error: $DMG holds no Vibe.app — re-run 'make release'" >&2
    exit 1
}
[[ -L "$MOUNT/Applications" ]] || {
    echo "error: $DMG holds no /Applications alias — re-run 'make release'" >&2
    exit 1
}
xcrun stapler validate "$MOUNTED_APP" >/dev/null || {
    echo "error: the app inside $DMG is not stapled — re-run 'make release'" >&2
    exit 1
}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$MOUNTED_APP/Contents/Info.plist")"
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
ARCHS="$(lipo -archs "$MOUNTED_APP/Contents/MacOS/Vibe")"
if [[ "$ARCHS" == *" "* ]]; then ARCH="universal"; else ARCH="$ARCHS"; fi

# Everything read out of the image has been read; give it back before the
# upload, so a failure there cannot leave a volume mounted.
hdiutil detach "$MOUNT" -quiet
ASSET="$BUILD_DIR/vibe-macos-$ARCH-$VERSION.dmg"
cp "$DMG" "$ASSET"

echo "🔊 releasing $TAG (build $BUILD) at $(git rev-parse --short HEAD)"
gh release create "$TAG" \
    "$ASSET#Vibe $VERSION (macOS, notarized)" \
    --title "Vibe $VERSION" \
    --notes-file "$NOTES" \
    --target "$(git rev-parse HEAD)" \
    ${DRAFT:+"$DRAFT"}

echo "🔊 done"
gh release view "$TAG" --json url -q .url
