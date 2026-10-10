#!/usr/bin/env bash
#
# Publish the notarized Developer ID build as a GitHub release.
#
#   scripts/github-release.sh [--draft|--prerelease]
#
# Verifies every staple and exact architecture set in `make release`'s
# products, tags HEAD as v<version> and attaches:
#   Vibe-macOS-universal-<version>.dmg/.zip   the website's download
#   Vibe-macOS-arm64-<version>.dmg/.zip       Apple silicon only
#
# Separate from release.sh because publishing is irreversible: a deleted
# release leaves its tag and download links behind.
#
# A stable release then points the Homebrew tap at itself (brew-set-version.sh).
#
# Every published release also adds an item to Sparkle's feeds,
# Assets/Web/appcast.xml (the universal zip) and appcast-arm64.xml, with the
# signature release.sh made. The feeds are committed and pushed before the
# tag, like the web page. Then, once the release exists, this deploys the site
# (deploy-web.sh), since the feed items and the page name its assets.
#
# The version is the built app's, never git's, so the tag names what the image
# contains. Notes are Assets/app-store/copy/en/macos/whats-new.txt, which the
# Mac App Store upload also takes, so the two channels cannot drift.
#
#   --draft        create it unpublished; the web page, the feeds, the deploy
#                  and the tap are left alone.
#   --prerelease   publish a beta: not marked Latest, and neither the web page
#                  nor the Homebrew tap is repointed, so neither hands out a
#                  test build. Its feed items carry the beta channel, which
#                  only a build with Settings > General > Beta updates on
#                  accepts.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="build/release"
UNIVERSAL_APP="$BUILD_DIR/export/Vibe.app"
UNIVERSAL_DMG="$BUILD_DIR/Vibe-universal.dmg"
UNIVERSAL_ZIP="$BUILD_DIR/Vibe.zip"
ARM64_APP="$BUILD_DIR/arm64/export/Vibe.app"
ARM64_DMG="$BUILD_DIR/arm64/Vibe.dmg"
ARM64_ZIP="$BUILD_DIR/arm64/Vibe.zip"
NOTES="Assets/app-store/copy/en/macos/whats-new.txt"
UNIVERSAL_FEED="Assets/Web/appcast.xml"
ARM64_FEED="Assets/Web/appcast-arm64.xml"
SPARKLE_BIN="Vibe/ThirdParty/Sparkle/bin"

# shellcheck source=scripts/asc-build-lib.sh
source scripts/asc-build-lib.sh

DRAFT=""
PRERELEASE=""
case "${1:-}" in
    --draft) DRAFT="--draft" ;;
    --prerelease) PRERELEASE="--prerelease" ;;
    "") ;;
    *) echo "usage: scripts/github-release.sh [--draft|--prerelease]" >&2; exit 64 ;;
esac

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
if grep -q ']]>' "$NOTES"; then
    echo "error: $NOTES contains ']]>', which would end the feed's CDATA" >&2
    exit 1
fi

# The signature must be over the zip as it is now: sign_update --verify checks
# it against the keychain's key, which release.sh checked the app trusts.
for zip in "$UNIVERSAL_ZIP" "$ARM64_ZIP"; do
    [[ -s "$zip.sig" ]] || {
        echo "error: $zip.sig is missing — re-run 'make release'" >&2
        exit 1
    }
    "$SPARKLE_BIN/sign_update" --verify "$zip" "$(cat "$zip.sig")" >/dev/null || {
        echo "error: $zip.sig does not verify against $zip — re-run 'make release'" >&2
        exit 1
    }
done

# Verify each variant as a recipient gets it. The app and the image are
# notarized separately and either missing staple forces an online Gatekeeper
# check; the zip is its own copy, made after stapling, so it is checked too.
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
            echo "error: $label app assets do not have one version/build" >&2
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

# Sparkle offers an item only when its build number is higher than the running
# app's, and the feeds list newest first. An item for this very build is a run
# that failed after writing it, so a re-run keeps it rather than refusing.
newest_feed_build() {
    awk -F '</?sparkle:version>' 'NF == 3 { print $2; exit }' "$1"
}
if [[ -z "$DRAFT" ]]; then
    for feed in "$UNIVERSAL_FEED" "$ARM64_FEED"; do
        newest="$(newest_feed_build "$feed")"
        if [[ -n "$newest" ]] && (( BUILD < newest )); then
            echo "error: build $BUILD is older than $feed's newest item, build $newest" >&2
            echo "       bump CURRENT_PROJECT_VERSION in project.yml and rebuild" >&2
            exit 1
        fi
    done
fi

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
# The universal DMG's name must match the URL web-set-version.sh writes.
ASSET_UNIVERSAL_DMG="$BUILD_DIR/Vibe-macOS-universal-$VERSION.dmg"
ASSET_UNIVERSAL_ZIP="$BUILD_DIR/Vibe-macOS-universal-$VERSION.zip"
ASSET_ARM64_DMG="$BUILD_DIR/Vibe-macOS-arm64-$VERSION.dmg"
ASSET_ARM64_ZIP="$BUILD_DIR/Vibe-macOS-arm64-$VERSION.zip"
cp "$UNIVERSAL_DMG" "$ASSET_UNIVERSAL_DMG"
cp "$UNIVERSAL_ZIP" "$ASSET_UNIVERSAL_ZIP"
cp "$ARM64_DMG" "$ASSET_ARM64_DMG"
cp "$ARM64_ZIP" "$ASSET_ARM64_ZIP"

# Prepends one item to a feed, before its first <item> or, in an empty feed,
# before </channel>. Markdown notes need macOS 12, below the app's minimum.
#   $1 feed   $2 zip asset   $3 the zip release.sh signed
add_feed_item() {
    local feed="$1"
    local asset="$2"
    local zip="$3"
    local url="https://github.com/cmicali/vibe/releases/download/$TAG/$(basename "$asset")"
    local channel=""
    local minimum
    local item

    if [[ "$(newest_feed_build "$feed")" == "$BUILD" ]]; then
        echo "🔊 $feed already offers build $BUILD — keeping it"
        return
    fi

    if [[ -n "$PRERELEASE" ]]; then
        channel="<sparkle:channel>beta</sparkle:channel>"
    fi
    minimum="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' \
        "$UNIVERSAL_APP/Contents/Info.plist")"
    item="$(mktemp)"
    cat > "$item" <<XML
<item>
<title>Vibe $VERSION</title>
<pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
<sparkle:version>$BUILD</sparkle:version>
<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
$channel
<description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
<enclosure url="$url" length="$(stat -f%z "$zip")" type="application/octet-stream" sparkle:edSignature="$(cat "$zip.sig")"/>
</item>
XML
    awk -v item="$item" '
        !done && (/^<item>/ || /^<\/channel>/) {
            while ((getline line < item) > 0) print line
            done = 1
        }
        { print }
    ' "$feed" > "$feed.new"
    mv "$feed.new" "$feed"
    rm -f "$item"
    xmllint --noout "$feed" || {
        echo "error: $feed is no longer valid XML — nothing has been published" >&2
        git checkout -- "$UNIVERSAL_FEED" "$ARM64_FEED"
        exit 1
    }
}

# Repoint the web page, add the feed items, and push BEFORE the tag, so
# v<version> names a tree whose page and feeds name that release. Only these
# files are committed, so a dirty tree cannot ride along, and a failed commit
# or push is fatal: the tag would dangle. A draft is skipped: its download is
# not public, and it creates no tag until published.
if [[ -n "$DRAFT" ]]; then
    echo "🔊 draft — leaving the web page and the update feeds on the previous release"
    echo "   once published: scripts/web-set-version.sh $VERSION && make deploy-web"
    echo "                   scripts/brew-set-version.sh $VERSION"
    echo "   a draft writes no feed item, so updates will not offer it"
else
    WEB_FILES=("$UNIVERSAL_FEED" "$ARM64_FEED")
    add_feed_item "$UNIVERSAL_FEED" "$ASSET_UNIVERSAL_ZIP" "$UNIVERSAL_ZIP"
    add_feed_item "$ARM64_FEED" "$ASSET_ARM64_ZIP" "$ARM64_ZIP"
    if [[ -n "$PRERELEASE" ]]; then
        echo "🔊 prerelease — leaving the web page on the last stable release"
        echo "   a beta must not become vibeplayer.app/download/latest"
        MESSAGE="web: offer v$VERSION to beta updates"
    else
        scripts/web-set-version.sh "$VERSION"
        WEB_FILES+=(Assets/Web/index.html Assets/Web/_redirects)
        MESSAGE="web: point the download and updates at v$VERSION"
    fi
    # Nothing to commit on a re-run whose first attempt committed already.
    if [[ -n "$(git status --porcelain -- "${WEB_FILES[@]}")" ]]; then
        git commit -q -m "$MESSAGE" -- "${WEB_FILES[@]}" || {
            echo "error: could not commit the web update — nothing has been published" >&2
            exit 1
        }
    fi
    git push -q origin HEAD || {
        echo "error: could not push the web update — the tag would dangle." >&2
        echo "       Nothing has been published. Push, then re-run." >&2
        exit 1
    }
    echo "🔊 web update pushed — the release will tag it"
fi

# Checked only now that HEAD has stopped moving.
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
    ${DRAFT:+"$DRAFT"} ${PRERELEASE:+"$PRERELEASE"}

# After the release, since the page and the feed items name its assets. The
# release is already out, so a failure here is a warning with its retry.
if [[ -z "$DRAFT" ]]; then
    scripts/deploy-web.sh || {
        echo "warning: the site and the update feeds are not deployed" >&2
        echo "         installed copies will not see v$VERSION until: make deploy-web" >&2
    }
fi

# After the release, since the cask's sha256s are the published assets' digests.
# A failure here is a warning with its retry, for the same reason.
if [[ -z "$DRAFT$PRERELEASE" ]]; then
    scripts/brew-set-version.sh "$VERSION" || {
        echo "warning: the Homebrew tap still points at the previous release" >&2
        echo "         retry: scripts/brew-set-version.sh $VERSION" >&2
    }
fi

echo "🔊 done"
gh release view "$TAG" --json url -q .url
