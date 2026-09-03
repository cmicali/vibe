#!/usr/bin/env bash
#
# Publish the notarized Developer ID build as a GitHub release.
#
#   scripts/github-release.sh [--draft]
#
# Takes the universal and arm64-only products from `make release`, verifies
# every app/image staple and exact binary architecture, tags HEAD as v<version>
# and attaches four carriers:
#
#   Vibe-macOS-universal-<version>.dmg   universal, website default
#   Vibe-macOS-universal-<version>.zip   universal bare bundle
#   Vibe-macOS-arm64-<version>.dmg       Apple silicon only
#   Vibe-macOS-arm64-<version>.zip       Apple silicon bare bundle
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
UNIVERSAL_APP="$BUILD_DIR/export/Vibe.app"
UNIVERSAL_DMG="$BUILD_DIR/Vibe-universal.dmg"
UNIVERSAL_ZIP="$BUILD_DIR/Vibe.zip"
ARM64_APP="$BUILD_DIR/arm64/export/Vibe.app"
ARM64_DMG="$BUILD_DIR/arm64/Vibe.dmg"
ARM64_ZIP="$BUILD_DIR/arm64/Vibe.zip"
NOTES="Assets/app-store/copy/en/whats-new.txt"

# shellcheck source=scripts/asc-build-lib.sh
source scripts/asc-build-lib.sh

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
[[ -d "$UNIVERSAL_APP" && -f "$UNIVERSAL_DMG" && -f "$UNIVERSAL_ZIP" \
        && -d "$ARM64_APP" && -f "$ARM64_DMG" && -f "$ARM64_ZIP" ]] || {
    echo "error: universal or arm64 release artifacts are missing — run 'make release' first" >&2
    echo "       expected $UNIVERSAL_DMG, $UNIVERSAL_ZIP," >&2
    echo "                $ARM64_DMG, and $ARM64_ZIP" >&2
    exit 1
}
[[ -s "$NOTES" ]] || {
    echo "error: $NOTES is missing or empty — write the release notes first" >&2
    exit 1
}

# Verify each image exactly as a recipient gets it. The image and its app are
# notarized separately, and either missing staple forces an online Gatekeeper
# check. The zip holds another copy made only after the app was stapled, so it
# is unpacked and checked independently. This also refuses mislabeled payloads:
# lipo's architecture assertion compares the exact slice set, not containment.
verify_release_variant() (
    local label="$1"
    local app="$2"
    local dmg="$3"
    local zip="$4"
    shift 4
    local expected_architectures=("$@")
    local mount
    local zip_tmp
    local mounted_app
    local zipped_app
    local version
    local build
    local candidate_version
    local candidate_build

    mount="$(mktemp -d)"
    zip_tmp="$(mktemp -d)"
    trap 'hdiutil detach "$mount" -quiet -force 2>/dev/null || true; rm -rf "$mount" "$zip_tmp"' EXIT

    xcrun stapler validate "$app" >/dev/null || {
        echo "error: $label exported app is not stapled — re-run 'make release'" >&2
        exit 1
    }
    asc_require_binary_architectures "$app/Contents/MacOS/Vibe" \
        "${expected_architectures[@]}"

    xcrun stapler validate "$dmg" >/dev/null || {
        echo "error: $dmg is not stapled — re-run 'make release'" >&2
        exit 1
    }
    hdiutil attach "$dmg" -mountpoint "$mount" -nobrowse -quiet -readonly
    mounted_app="$mount/Vibe.app"
    [[ -d "$mounted_app" ]] || {
        echo "error: $dmg holds no Vibe.app — re-run 'make release'" >&2
        exit 1
    }
    [[ -L "$mount/Applications" ]] || {
        echo "error: $dmg holds no /Applications alias — re-run 'make release'" >&2
        exit 1
    }
    xcrun stapler validate "$mounted_app" >/dev/null || {
        echo "error: the app inside $dmg is not stapled — re-run 'make release'" >&2
        exit 1
    }
    asc_require_binary_architectures "$mounted_app/Contents/MacOS/Vibe" \
        "${expected_architectures[@]}"

    ditto -x -k "$zip" "$zip_tmp"
    zipped_app="$zip_tmp/Vibe.app"
    xcrun stapler validate "$zipped_app" >/dev/null || {
        echo "error: the app inside $zip is not stapled — re-run 'make release'" >&2
        exit 1
    }
    asc_require_binary_architectures "$zipped_app/Contents/MacOS/Vibe" \
        "${expected_architectures[@]}"

    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
        "$mounted_app/Contents/Info.plist")"
    build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' \
        "$mounted_app/Contents/Info.plist")"
    [[ -n "$version" && -n "$build" ]] || {
        echo "error: $label image carries no version" >&2
        exit 1
    }
    for candidate in "$app" "$zipped_app"; do
        candidate_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
            "$candidate/Contents/Info.plist")"
        candidate_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' \
            "$candidate/Contents/Info.plist")"
        [[ "$candidate_version" == "$version" && "$candidate_build" == "$build" ]] || {
            echo "error: $label app carriers do not have one version/build" >&2
            exit 1
        }
    done

    printf '%s\t%s\n' "$version" "$build"
)

UNIVERSAL_METADATA="$(verify_release_variant universal "$UNIVERSAL_APP" \
    "$UNIVERSAL_DMG" "$UNIVERSAL_ZIP" arm64 x86_64)"
IFS=$'\t' read -r VERSION BUILD <<< "$UNIVERSAL_METADATA"
ARM64_METADATA="$(verify_release_variant arm64-only "$ARM64_APP" \
    "$ARM64_DMG" "$ARM64_ZIP" arm64)"
IFS=$'\t' read -r ARM64_VERSION ARM64_BUILD <<< "$ARM64_METADATA"
[[ "$ARM64_VERSION" == "$VERSION" && "$ARM64_BUILD" == "$BUILD" ]] || {
    echo "error: universal is $VERSION ($BUILD), but arm64 is $ARM64_VERSION ($ARM64_BUILD)" >&2
    echo "       re-run 'make release' so every asset comes from one build" >&2
    exit 1
}
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
# ---------------------------------------------------------------------------
# Publish.
# ---------------------------------------------------------------------------
# Every carrier names its verified architecture. The website and its stable
# /download redirect point to this same universal asset name.
ASSET_UNIVERSAL_DMG="$BUILD_DIR/Vibe-macOS-universal-$VERSION.dmg"
ASSET_UNIVERSAL_ZIP="$BUILD_DIR/Vibe-macOS-universal-$VERSION.zip"
ASSET_ARM64_DMG="$BUILD_DIR/Vibe-macOS-arm64-$VERSION.dmg"
ASSET_ARM64_ZIP="$BUILD_DIR/Vibe-macOS-arm64-$VERSION.zip"
cp "$UNIVERSAL_DMG" "$ASSET_UNIVERSAL_DMG"
cp "$UNIVERSAL_ZIP" "$ASSET_UNIVERSAL_ZIP"
cp "$ARM64_DMG" "$ASSET_ARM64_DMG"
cp "$ARM64_ZIP" "$ASSET_ARM64_ZIP"

# ---------------------------------------------------------------------------
# Repoint the marketing page, and land it BEFORE the tag.
# ---------------------------------------------------------------------------
# The page advertises a direct .dmg URL, and so do the /download rules in
# _redirects that make vibeplayer.app/download/latest stable; both are only
# correct because this runs, and web-set-version.sh has the why. It happens
# here rather than after publishing so the tag names a tree whose website
# already points at this release — checking out v<version> gets the page that
# goes with it.
#
# Commit just those two files by explicit pathspec, so a dirty tree cannot
# ride along. Unlike every other step here this one moves main, and it does so
# before anything irreversible: the release is created from HEAD immediately
# after, so a failed commit or push has to be fatal — a tag on an unpushed
# commit would dangle, and the release does not exist yet to be inconsistent
# with.
#
# A draft is skipped entirely. Its download is not public, so the page would
# advertise a 404; a draft also creates no tag until it is published, so there
# is no ordering to preserve.
if [[ -n "$DRAFT" ]]; then
    echo "🔊 draft — leaving the web page pointing at the previous release"
    echo "   once published: scripts/web-set-version.sh $VERSION && make deploy-web"
else
    scripts/web-set-version.sh "$VERSION"
    WEB_FILES=(Assets/Web/index.html Assets/Web/_redirects)
    if [[ -n "$(git status --porcelain -- "${WEB_FILES[@]}")" ]]; then
        git commit -q -m "web: point the download at v$VERSION" -- "${WEB_FILES[@]}" || {
            echo "error: could not commit the web page update — nothing has been published" >&2
            exit 1
        }
        git push -q origin HEAD || {
            echo "error: could not push the web page update — the tag would dangle." >&2
            echo "       Nothing has been published. Push, then re-run." >&2
            exit 1
        }
        echo "🔊 web page repointed and pushed — the release will tag it"
    fi
fi

# Authoritative only now that HEAD has stopped moving.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
        && [[ "$(git rev-parse "refs/tags/$TAG^{commit}")" != "$(git rev-parse HEAD)" ]]; then
    echo "error: tag $TAG exists and does not point at HEAD" >&2
    exit 1
fi

echo "🔊 releasing $TAG (build $BUILD) at $(git rev-parse --short HEAD)"
gh release create "$TAG" \
    "$ASSET_UNIVERSAL_DMG#Vibe $VERSION (macOS Universal, notarized disk image)" \
    "$ASSET_UNIVERSAL_ZIP#Vibe $VERSION (macOS Universal, notarized zip)" \
    "$ASSET_ARM64_DMG#Vibe $VERSION (Apple silicon, notarized disk image)" \
    "$ASSET_ARM64_ZIP#Vibe $VERSION (Apple silicon, notarized zip)" \
    --title "Vibe $VERSION" \
    --notes-file "$NOTES" \
    --target "$(git rev-parse HEAD)" \
    ${DRAFT:+"$DRAFT"}

echo "🔊 done"
gh release view "$TAG" --json url -q .url
[[ -n "$DRAFT" ]] || echo "🔊 next: make deploy-web    (publishes the page to Cloudflare)"
