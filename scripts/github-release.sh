#!/usr/bin/env bash
#
# Publish the notarized Developer ID build as a GitHub release.
#
#   scripts/github-release.sh [--draft]
#
# Takes both artifacts `make release` produced (build/release/Vibe.dmg and
# Vibe.zip), verifies every staple in them, tags HEAD as v<version> and creates
# the release with both attached, as Vibe-macOS-<version>.dmg and
# Vibe-macOS-<arch>-<version>.zip. The image is listed first: it is the
# download that lands the app in /Applications, and the zip is there for
# anyone who wants the bundle without mounting anything.
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
[[ -f "$DMG" && -f "$ZIP" && -d "$APP" ]] || {
    echo "error: no release artifacts at $DMG and $ZIP — run 'make release' first" >&2
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

# The zip ships too, and it holds its own copy of the app — release.sh zips
# twice, once to submit for notarization and once after stapling, so this is
# the check that the SECOND one is what is about to be uploaded.
ZIP_TMP="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; rm -rf "$MOUNT" "$ZIP_TMP"' EXIT
ditto -x -k "$ZIP" "$ZIP_TMP"
xcrun stapler validate "$ZIP_TMP/Vibe.app" >/dev/null || {
    echo "error: the app inside $ZIP is not stapled — re-run 'make release'" >&2
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
# The zip carries the bare bundle, so its name says which machines that bundle
# runs on — read from the binary itself, never assumed: one slice names its
# arch, more collapse to "universal". The image is the download for a human
# with a Mac in front of them and says only the version.
ARCHS="$(lipo -archs "$MOUNTED_APP/Contents/MacOS/Vibe")"
if [[ "$ARCHS" == *" "* ]]; then ARCH="universal"; else ARCH="$ARCHS"; fi

# Everything read out of the image has been read; give it back before the
# upload, so a failure there cannot leave a volume mounted.
hdiutil detach "$MOUNT" -quiet
ASSET_DMG="$BUILD_DIR/Vibe-macOS-$VERSION.dmg"
ASSET_ZIP="$BUILD_DIR/Vibe-macOS-$ARCH-$VERSION.zip"
cp "$DMG" "$ASSET_DMG"
cp "$ZIP" "$ASSET_ZIP"

echo "🔊 releasing $TAG (build $BUILD) at $(git rev-parse --short HEAD)"
gh release create "$TAG" \
    "$ASSET_DMG#Vibe $VERSION (macOS, notarized disk image)" \
    "$ASSET_ZIP#Vibe $VERSION (macOS, notarized zip)" \
    --title "Vibe $VERSION" \
    --notes-file "$NOTES" \
    --target "$(git rev-parse HEAD)" \
    ${DRAFT:+"$DRAFT"}

# The marketing page advertises a direct .dmg URL, which only stays correct
# because this runs. Commit just that file by explicit path, so a dirty tree
# cannot ride along. The release is already published by here, so a failure to
# commit or push is a warning with the manual command, never a hard failure.
# A draft has no public download yet, so pointing the live page at it would
# ship a 404 — leave the page on the previous release until the draft goes out.
if [[ -n "$DRAFT" ]]; then
    echo "🔊 draft — leaving the web page pointing at the previous release"
    echo "   once published: scripts/web-set-version.sh $VERSION && make deploy-web"
else
    scripts/web-set-version.sh "$VERSION"
    if [[ -n "$(git status --porcelain -- Assets/Web/index.html)" ]]; then
        if git commit -q -m "web: point the download at v$VERSION" -- Assets/Web/index.html \
                && git push -q origin HEAD; then
            echo "🔊 pushed the web page update — GitHub Pages redeploys itself"
        else
            echo "warning: could not commit or push the web page update. Run:" >&2
            echo "         git commit -m 'web: point the download at v$VERSION' -- Assets/Web/index.html && git push" >&2
        fi
    fi
fi

echo "🔊 done"
gh release view "$TAG" --json url -q .url
[[ -n "$DRAFT" ]] || echo "🔊 next: make deploy-web    (publishes the page to Cloudflare)"
