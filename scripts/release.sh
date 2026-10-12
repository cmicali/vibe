#!/usr/bin/env bash
#
# Developer ID release of the macOS app: a universal and an arm64-only build,
# each archived, exported, notarized and stapled, then shipped as a signed,
# notarized disk image. scripts/github-release.sh publishes the results.
#
# Not scripts/release-appstore.sh: an App Store-signed app is rejected by
# Gatekeeper when handed out directly, so only this path makes a shareable
# build. The export re-signs the embedded Sparkle framework and its helpers
# with the Developer ID, and each export is checked for it.
#
# Each final zip is signed for Sparkle (<zip>.sig), which github-release.sh
# writes into the appcast. The universal build checks appcast.xml, the
# arm64-only build appcast-arm64.xml, so an arm64-only install stays one.
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
#   4. Sparkle's EdDSA signing key in the login keychain, made once with
#      Vibe/ThirdParty/Sparkle/bin/generate_keys. Its public half is
#      VIBE_SPARKLE_PUBLIC_KEY in project.yml. Back the private half up offline
#      (generate_keys -x <file>): losing it strands every installed build.
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

SPARKLE_BIN="Vibe/ThirdParty/Sparkle/bin"
UNIVERSAL_FEED="https://vibeplayer.app/appcast.xml"
ARM64_FEED="https://vibeplayer.app/appcast-arm64.xml"

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

# Before the archive, like the certificate: an update signed with no key, or
# another key, is refused by every installed build.
SPARKLE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" || SPARKLE_PUBLIC_KEY=""
if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    cat >&2 <<'MSG'
error: no Sparkle signing key in the login keychain.

  Make it once (this prints the public key):
    Vibe/ThirdParty/Sparkle/bin/generate_keys
  Put the public key in project.yml as VIBE_SPARKLE_PUBLIC_KEY, and back up
  the private key offline beside the Developer ID certificate:
    Vibe/ThirdParty/Sparkle/bin/generate_keys -x <file>
  Losing it strands every installed build. On another Mac, import it with
  generate_keys -f <file>.
MSG
    exit 1
fi

echo "🔊 signing identity : $DEVELOPER_ID"
echo "🔊 api key          : $ASC_KEY_ID (issuer $ASC_ISSUER_ID)"
echo "🔊 team id          : $TEAM_ID"

# The exported app must trust this keychain's key and its own feed, and the
# export must have signed every piece of Sparkle with the Developer ID, under
# the hardened runtime, with a timestamp. A failure here would otherwise show
# only when a user's update is refused, or at notarization.
require_updater() {
    local label="$1"
    local app="$2"
    local feed="$3"
    local plist="$app/Contents/Info.plist"
    local framework="$app/Contents/Frameworks/Sparkle.framework"
    local key
    local info

    key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$plist" 2>/dev/null)" || key=""
    [[ "$key" == "$SPARKLE_PUBLIC_KEY" ]] || {
        echo "error: $label app trusts Sparkle key '$key', not the keychain's." >&2
        echo "       Set VIBE_SPARKLE_PUBLIC_KEY in project.yml to: $SPARKLE_PUBLIC_KEY" >&2
        exit 1
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$plist")" == "$feed" ]] || {
        echo "error: $label app does not check $feed" >&2
        exit 1
    }
    for code in "$app" "$framework" "$framework/Versions/B/Autoupdate" \
            "$framework/Versions/B/Updater.app" \
            "$framework/Versions/B/XPCServices/Installer.xpc" \
            "$framework/Versions/B/XPCServices/Downloader.xpc"; do
        info="$(codesign -dvv "$code" 2>&1)"
        grep -q '^Authority=Developer ID Application' <<<"$info" \
            && grep -q '^Timestamp=' <<<"$info" \
            && grep -q '^CodeDirectory.*flags=.*runtime' <<<"$info" || {
            echo "error: $code is not signed with the Developer ID, hardened, and timestamped." >&2
            echo "       If the export stopped re-signing Sparkle, sign its helpers inside out" >&2
            echo "       before the app: https://sparkle-project.org/documentation/sandboxing/" >&2
            exit 1
        }
    done
    codesign --verify --deep --strict "$app"
}

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
require_updater universal "$UNIVERSAL_APP" "$UNIVERSAL_FEED"

# asc_generate_and_archive wipes BUILD_DIR, so the arm64 archive calls
# asc_archive directly, under its own BUILD_DIR so its export options and log do
# not overwrite the universal ones.
mkdir -p "$ARM64_BUILD_DIR"
BUILD_DIR="$ARM64_BUILD_DIR"
ARCHIVE="$ARM64_ARCHIVE"
EXPORT_DIR="$ARM64_EXPORT_DIR"
asc_archive "Release, arm64-only" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    "VIBE_SPARKLE_FEED_URL=$ARM64_FEED"
asc_require_binary_architectures \
    "$ARCHIVE/Products/Applications/$PRODUCT.app/Contents/MacOS/$PRODUCT" arm64
write_developer_id_export_options "$BUILD_DIR/ExportOptions.plist"
asc_export_archive "Developer ID, arm64-only" developer-id
asc_require_binary_architectures "$ARM64_APP/Contents/MacOS/$PRODUCT" arm64
require_updater arm64-only "$ARM64_APP" "$ARM64_FEED"

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
    # It is also the update Sparkle downloads, so it is signed only now.
    rm -f "$zip" "$zip.sig"
    ditto -c -k --keepParent "$app" "$zip"
    "$SPARKLE_BIN/sign_update" -p "$zip" > "$zip.sig"

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
echo "    both zips are signed for Sparkle (<zip>.sig)"
