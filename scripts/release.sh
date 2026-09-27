#!/usr/bin/env bash
#
# Developer ID release of the macOS app: a universal and an arm64-only build,
# each archived, exported, notarized and stapled, then shipped as a signed,
# notarized disk image. scripts/github-release.sh publishes the results.
#
# Not scripts/release-appstore.sh: an App Store-signed app is rejected by
# Gatekeeper when handed out directly, so only this path makes a shareable
# build. The app embeds no frameworks or helpers, so the export signs it whole.
#
# Prerequisites (checked, not created):
#   1. Apple Developer Program membership on team $TEAM_ID.
#   2. An App Store Connect API key with the ADMIN role, in .release-env
#      (scripts/asc-auth-lib.sh).
#   3. A "Developer ID Application" certificate in the keychain, made by hand:
#      Apple gates it to the Account Holder, a person role no API key can hold,
#      so -allowProvisioningUpdates gets 403 even with an Admin key.
#        Xcode -> Settings -> Accounts -> select the team ->
#        Manage Certificates -> (+) -> Developer ID Application
#      Apple caps these at 5 per account, so keep the one you make. An "Apple
#      Development" cert is not accepted for notarization.
#
# Usage: scripts/release.sh
#   DEVELOPER_ID  signing identity (default: the first "Developer ID
#                 Application" in the keychain)
#   TEAM_ID       team id for the export (default: 4UEV752JH4)
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

asc_require_xcodegen

asc_require_translations

asc_resolve_credentials

# Cloud signing cannot supply a Developer ID cert, so a missing one fails here
# rather than after a full archive.
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

# Architecture is an archive input, never a post-export thinning: thinning a
# signed app invalidates its signature and notarization.
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

# asc_generate_and_archive wipes BUILD_DIR, so the arm64 archive calls
# asc_archive directly, under its own BUILD_DIR so its export options and log do
# not overwrite the universal ones.
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

# A notarization ticket is bound to the submitted code, so each product is
# submitted on its own.
#
# The disk image is what people download. A quarantined app launched from where
# the browser unzipped it runs translocated, from a random read-only mount that
# vanishes on quit, and Settings > General > Default music player registers the
# running path with Launch Services. Dragging out of the image onto its
# /Applications alias clears translocation. No background or icon layout: that
# means scripting Finder over AppleScript, which needs Automation permission.
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
    spctl -a -vvv --type exec "$app"

    # The published zip must carry the staple added after the submission zip.
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"

    echo "🔊 $label: disk image"
    rm -rf "$dmg_stage" "$dmg"
    mkdir -p "$dmg_stage"
    # ditto keeps the staple (Contents/CodeResources), so the app dragged out
    # of the image verifies offline.
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
