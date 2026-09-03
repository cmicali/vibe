#!/usr/bin/env bash
#
# Build universal and arm64-only distributable Vibe apps and disk images:
# generate -> archive (Release) -> export signed with Developer ID -> notarize
# -> staple -> disk image -> notarize -> staple. Each architecture gets its own
# archive and trust chain; scripts/github-release.sh publishes all four DMG/zip
# carriers, with each published DMG named for its architecture.
#
# This is NOT scripts/release-appstore.sh. The two release paths are different
# products:
#
#   release.sh           Developer ID + notarize + staple  -> universal and
#                        arm64-only .dmgs you host yourself. Anyone can
#                        download and run the matching build.
#   release-appstore.sh  Apple Distribution + App Store profile -> a .pkg
#                        uploaded to App Store Connect. An App Store-signed app
#                        is rejected by Gatekeeper if handed out directly, so
#                        that pipeline cannot produce a shareable build.
#
# The app embeds no frameworks/helpers (see the empty Embed Frameworks phase),
# so there is no nested code to sign — the archive/export handles everything.
#
# ---------------------------------------------------------------------------
# One-time prerequisites (this script only checks for them, it can't create them):
#
#   1. An active Apple Developer Program membership on team $TEAM_ID.
#
#   2. An App Store Connect API key with the ADMIN role, in .release-env.
#      See scripts/asc-auth-lib.sh — the same key signs, notarizes and uploads
#      for both release paths.
#
#   3. A "Developer ID Application" certificate in the keychain. Unlike the
#      App Store path, this one MUST be made by hand — Apple gates
#      DEVELOPER_ID_APPLICATION_MANAGED to the team's Account Holder, a person
#      role no API key can hold, so -allowProvisioningUpdates cannot mint it
#      (an Admin key that signs App Store builds still gets 403).
#        Xcode -> Settings -> Accounts -> (sign in) -> select the team ->
#        Manage Certificates -> (+) -> Developer ID Application
#      Apple caps these at 5 per account, so keep the one you make.
#      (An "Apple Development" cert is NOT accepted for notarization.)
#
# ---------------------------------------------------------------------------
# Usage: scripts/release.sh
# Environment overrides:
#   DEVELOPER_ID    signing identity (default: the sole "Developer ID
#                   Application" in the keychain)
#   TEAM_ID         team id used for the Developer ID export (default: 4UEV752JH4)
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/asc-auth-lib.sh
source scripts/asc-auth-lib.sh
# shellcheck source=scripts/asc-build-lib.sh
source scripts/asc-build-lib.sh

SCHEME=Vibe
PRODUCT=Vibe
TEAM_ID="${TEAM_ID:-4UEV752JH4}"

RELEASE_DIR="build/release"
BUILD_DIR="$RELEASE_DIR"
ARCHIVE="$BUILD_DIR/$PRODUCT.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
UNIVERSAL_APP="$EXPORT_DIR/$PRODUCT.app"
UNIVERSAL_ZIP="$BUILD_DIR/$PRODUCT.zip"
UNIVERSAL_DMG="$BUILD_DIR/$PRODUCT-universal.dmg"
UNIVERSAL_DMG_STAGE="$BUILD_DIR/dmg"

ARM64_BUILD_DIR="$RELEASE_DIR/arm64"
ARM64_ARCHIVE="$ARM64_BUILD_DIR/$PRODUCT.xcarchive"
ARM64_EXPORT_DIR="$ARM64_BUILD_DIR/export"
ARM64_APP="$ARM64_EXPORT_DIR/$PRODUCT.app"
ARM64_ZIP="$ARM64_BUILD_DIR/$PRODUCT.zip"
ARM64_DMG="$ARM64_BUILD_DIR/$PRODUCT.dmg"
ARM64_DMG_STAGE="$ARM64_BUILD_DIR/dmg"
VOLNAME="$PRODUCT"

# ---------------------------------------------------------------------------
# Preflight — fail early with actionable messages.
# ---------------------------------------------------------------------------
asc_require_xcodegen

asc_require_translations

asc_resolve_credentials

# The certificate must already be in the keychain — cloud signing cannot supply
# a Developer ID cert (see prerequisite 3), so checking here turns a failure
# that would otherwise surface after a full archive into an instant one.
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
fi
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    cat >&2 <<'MSG'
error: no 'Developer ID Application' certificate found in the keychain.

  This one cannot be automated. Apple gates Developer ID certificates to the
  team's Account Holder — a person role no App Store Connect API key can hold —
  so -allowProvisioningUpdates gets a 403 even with an Admin key.

  Create it once, signed in as the Account Holder:
    Xcode -> Settings -> Accounts -> (sign in) -> select the team ->
    Manage Certificates -> (+) -> Developer ID Application
  Apple caps these at 5 per account, so keep the one you make.

  Then re-run, or set DEVELOPER_ID to the exact identity name.
MSG
    exit 1
fi

echo "🔊 signing identity : $DEVELOPER_ID"
echo "🔊 api key          : $ASC_KEY_ID (issuer $ASC_ISSUER_ID)"
echo "🔊 team id          : $TEAM_ID"

# ---------------------------------------------------------------------------
# Generate + archive + export — shared mechanics in asc-build-lib.sh, which
# documents why the archives carry no signing overrides. Architecture is an
# explicit archive input: thinning an exported app would invalidate its code
# signature and notarization, and a second archive keeps the arm64 product a
# first-class signed build.
# ---------------------------------------------------------------------------
write_developer_id_export_options() {
    local path="$1"
    cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
}

asc_generate_and_archive "ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO
asc_require_binary_architectures \
    "$ARCHIVE/Products/Applications/$PRODUCT.app/Contents/MacOS/$PRODUCT" \
    arm64 x86_64
write_developer_id_export_options "$BUILD_DIR/ExportOptions.plist"
asc_export_archive "Developer ID, universal" developer-id
asc_require_binary_architectures \
    "$UNIVERSAL_APP/Contents/MacOS/$PRODUCT" arm64 x86_64

# asc_generate_and_archive deliberately wipes BUILD_DIR, so the second archive
# uses asc_archive directly and lives under the already-clean release tree.
# Give it its own BUILD_DIR during export too: that keeps its options and export
# log beside the archive without disturbing the universal products above.
mkdir -p "$ARM64_BUILD_DIR"
BUILD_DIR="$ARM64_BUILD_DIR"
ARCHIVE="$ARM64_ARCHIVE"
EXPORT_DIR="$ARM64_EXPORT_DIR"
asc_archive "Release, arm64-only" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
asc_require_binary_architectures \
    "$ARCHIVE/Products/Applications/$PRODUCT.app/Contents/MacOS/$PRODUCT" arm64
write_developer_id_export_options "$BUILD_DIR/ExportOptions.plist"
asc_export_archive "Developer ID, arm64-only" developer-id
asc_require_binary_architectures "$ARM64_APP/Contents/MacOS/$PRODUCT" arm64

# ---------------------------------------------------------------------------
# Notarize + staple each app, then package, sign and notarize its disk image.
# A notarization ticket is bound to the submitted code, so the universal and
# arm64-only products cannot share either the app or image submission.
# ---------------------------------------------------------------------------
# The disk images are what humans should download. A zip expands wherever the
# browser drops it, which for Safari is ~/Downloads, and a quarantined app
# launched from there runs TRANSLOCATED — a read-only random mount point that
# vanishes on quit. That is not cosmetic for this app: Settings > Set Vibe as
# Default Music Player registers with Launch Services from its running path, so
# a translocated registration points somewhere that ceases to exist. Dragging
# out of a disk image onto its /Applications alias clears translocation.
#
# Deliberately plain: no background or icon placement. Those require driving
# Finder over AppleScript to write a .DS_Store, which needs Automation
# permission and is the flakiest step in a DMG build; two icons carry the point.
notarize_and_package() {
    local label="$1"
    local app="$2"
    local zip="$3"
    local dmg="$4"
    local dmg_stage="$5"

    echo "🔊 $label: zip for submission"
    ditto -c -k --keepParent "$app" "$zip"

    echo "🔊 $label: notarize app (waits for Apple's verdict)"
    xcrun notarytool submit "$zip" \
        --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

    echo "🔊 $label: staple + validate app"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    # The real test: what Gatekeeper says about the app a recipient receives.
    spctl -a -vvv --type exec "$app"

    # The published zip must carry the staple added after the submission zip.
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"

    echo "🔊 $label: disk image"
    rm -rf "$dmg_stage" "$dmg"
    mkdir -p "$dmg_stage"
    # ditto reproduces the signed bundle exactly. The staple rides along in
    # Contents/CodeResources, so the app dragged from the image verifies offline.
    ditto "$app" "$dmg_stage/$PRODUCT.app"
    ln -s /Applications "$dmg_stage/Applications"
    hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$dmg_stage" \
        -fs HFS+ -format UDZO -ov "$dmg"
    rm -rf "$dmg_stage"

    echo "🔊 $label: sign image"
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg"

    echo "🔊 $label: notarize image (waits for Apple's verdict)"
    xcrun notarytool submit "$dmg" \
        --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

    echo "🔊 $label: staple + validate image"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl -a -vvv -t open --context context:primary-signature "$dmg"
}

notarize_and_package universal "$UNIVERSAL_APP" "$UNIVERSAL_ZIP" \
    "$UNIVERSAL_DMG" "$UNIVERSAL_DMG_STAGE"
notarize_and_package arm64-only "$ARM64_APP" "$ARM64_ZIP" \
    "$ARM64_DMG" "$ARM64_DMG_STAGE"

echo "🔊 done"
echo "    universal app: $UNIVERSAL_APP"
echo "    universal dmg: $UNIVERSAL_DMG"
echo "    arm64 app:     $ARM64_APP"
echo "    arm64 dmg:     $ARM64_DMG"
echo "    both disk images are notarized + stapled, drag-to-Applications"
