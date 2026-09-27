#!/usr/bin/env bash
#
# Build Vibe for the App Store and validate it; --upload also submits it.
#   --platform macos   universal (arm64 + x86_64) .pkg   Mac App Store (default)
#   --platform ios     arm64 .ipa, widget embedded       iOS App Store
#
# Both platforms ship bundle id com.commonwealthrecordings.Vibe: one app record
# (Universal Purchase), a version train per platform. project.yml declares one
# version for both; the uploaded platform's ASC version record must carry it.
#
# Not scripts/release.sh (Developer ID, direct download, macOS only). Nothing
# here is notarized — the store does that — or signed with Developer ID.
#
# Prerequisites (checked, not created):
#   1. Apple Developer Program membership on team $TEAM_ID.
#   2. An App Store Connect API key with the ADMIN role (Users and Access ->
#      Integrations -> App Store Connect API -> Team Keys -> (+) -> Admin).
#      Its AuthKey_<KEYID>.p8 downloads once; keep it in
#      ~/.appstoreconnect/private_keys/. An App Manager key uploads, but the
#      export dies with 403 FORBIDDEN_ERROR: cloud-managed distribution
#      certificates are Admin-gated, and a key's role cannot be edited.
#   3. An app record for the bundle id, with the uploaded platform added to it.
#   Certificates, App ID and profile are not made by hand: the key plus
#   -allowProvisioningUpdates creates them on first run.
#
# Usage: scripts/release-appstore.sh [--platform macos|ios] [--upload]
#   ASC_KEY_ID      API key id (required)
#   ASC_ISSUER_ID   API issuer id (required)
#   ASC_KEY_PATH    the .p8 (default:
#                   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
#   TEAM_ID         team id (default: 4UEV752JH4)
# from the environment or the repo root's gitignored .release-env.
set -euo pipefail

cd "$(dirname "$0")/.."

UPLOAD=0
PLATFORM=macos
while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload) UPLOAD=1 ;;
        --platform) shift; PLATFORM="${1:-}" ;;
        --platform=*) PLATFORM="${1#*=}" ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "error: unknown argument '$1' (expected --upload or --platform <macos|ios>)" >&2; exit 1 ;;
    esac
    shift
done

# shellcheck source=scripts/asc-auth-lib.sh
source scripts/asc-auth-lib.sh
# shellcheck source=scripts/asc-build-lib.sh
source scripts/asc-build-lib.sh

PRODUCT=Vibe
TEAM_ID="${TEAM_ID:-4UEV752JH4}"

# Every platform difference is decided here. APP_SUBPATH: a macOS bundle keeps
# Info.plist and the executable under Contents/, an iOS bundle at its root.
case "$PLATFORM" in
    macos)
        SCHEME=Vibe
        BUILD_DIR="build/appstore"
        ARCHIVE_ARGS=("ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
        EXPECTED_ARCHS=(arm64 x86_64)
        APP_SUBPATH="Contents/"
        EXECUTABLE_SUBPATH="Contents/MacOS/$PRODUCT"
        UPLOAD_EXT=pkg
        ALTOOL_TYPE=macos
        ;;
    ios)
        SCHEME=VibeiOS
        BUILD_DIR="build/appstore-ios"
        # Without a destination xcodebuild may resolve a simulator.
        ARCHIVE_ARGS=(-destination 'generic/platform=iOS')
        # Asserted: a simulator-SDK archive could carry x86_64, which the
        # upload rejects with a far less obvious message.
        EXPECTED_ARCHS=(arm64)
        APP_SUBPATH=""
        EXECUTABLE_SUBPATH="$PRODUCT"
        UPLOAD_EXT=ipa
        ALTOOL_TYPE=ios
        ;;
    *)
        echo "error: --platform must be 'macos' or 'ios', not '$PLATFORM'" >&2
        exit 1
        ;;
esac

ARCHIVE="$BUILD_DIR/$PRODUCT.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

asc_require_xcodegen

asc_require_translations

asc_resolve_credentials

echo "🔊 platform    : $PLATFORM (scheme $SCHEME)"
echo "🔊 team id     : $TEAM_ID"
echo "🔊 api key     : $ASC_KEY_ID (issuer $ASC_ISSUER_ID)"
echo "🔊 upload      : $([[ $UPLOAD == 1 ]] && echo yes || echo 'no (validate only)')"

asc_generate_and_archive "${ARCHIVE_ARGS[@]}"

# The version is read from the archived app, not project.yml, so the number
# reported is the number uploaded.
ARCHIVED_APP="$ARCHIVE/Products/Applications/$PRODUCT.app"
ARCHIVED_PLIST="$ARCHIVED_APP/${APP_SUBPATH}Info.plist"
[[ -f "$ARCHIVED_PLIST" ]] || {
    echo "error: no Info.plist at $ARCHIVED_PLIST — did the archive lay out somewhere else?" >&2
    exit 1; }
asc_require_binary_architectures "$ARCHIVED_APP/$EXECUTABLE_SUBPATH" "${EXPECTED_ARCHS[@]}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ARCHIVED_PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ARCHIVED_PLIST")"
[[ -n "$VERSION" && -n "$BUILD_NUM" ]] || {
    echo "error: the archived app carries no version" >&2
    exit 1; }

echo "🔊 version     : $VERSION ($BUILD_NUM)"

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <!-- YES lets Xcode bump the build number at upload, away from project.yml. -->
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

asc_export_archive "App Store package" ""

# Globbed: the export may name the file for the product (Vibe) or the scheme
# (VibeiOS).
shopt -s nullglob
EXPORTED=("$EXPORT_DIR"/*."$UPLOAD_EXT")
shopt -u nullglob
[[ ${#EXPORTED[@]} == 1 ]] || {
    echo "error: expected exactly one .$UPLOAD_EXT in $EXPORT_DIR, found ${#EXPORTED[@]}:" >&2
    ls -la "$EXPORT_DIR" >&2
    exit 1; }
UPLOAD_FILE="${EXPORTED[0]}"

# The widget draws only from the app group, so a distribution profile that
# dropped the entitlement ships a blank widget; only the re-signed export shows
# it.
if [[ "$PLATFORM" == ios ]]; then
    IPA_APP="Payload/$PRODUCT.app"

    # TRAP: capture the listing, never pipe it into `grep -q`: grep exits at
    # the widget's line, unzip dies of SIGPIPE, and pipefail reports a missing
    # widget — only on a slow run, which is to say a real release.
    IPA_LISTING="$(unzip -l "$UPLOAD_FILE")"
    grep -q "$IPA_APP/PlugIns/VibeWidget.appex/VibeWidget" <<<"$IPA_LISTING" || {
        echo "error: $UPLOAD_FILE carries no VibeWidget.appex executable" >&2
        exit 1; }

    # TRAP: PlistBuddy seeks its input, so it cannot read a pipe (/dev/stdin
    # gives "Error Reading File"); both forms go to files in $BUILD_DIR, which
    # also keeps them for a failed check. PROFILE_GROUPS, not GROUPS: bash
    # silently discards assignments to GROUPS.
    PROFILE_DER="$BUILD_DIR/embedded.mobileprovision"
    PROFILE_PLIST="$BUILD_DIR/embedded.mobileprovision.plist"
    unzip -p "$UPLOAD_FILE" "$IPA_APP/embedded.mobileprovision" > "$PROFILE_DER"
    security cms -D -i "$PROFILE_DER" > "$PROFILE_PLIST"
    PROFILE_GROUPS="$(/usr/libexec/PlistBuddy \
        -c 'Print Entitlements:com.apple.security.application-groups' \
        "$PROFILE_PLIST" 2>/dev/null)" || true
    case "$PROFILE_GROUPS" in
        *group.com.commonwealthrecordings.Vibe*)
            echo "🔊 app group   : granted by the distribution profile" ;;
        *)
            echo "error: the embedded distribution profile does not grant" >&2
            echo "       group.com.commonwealthrecordings.Vibe — the widget would ship blank." >&2
            echo "       Enable App Groups on the App ID in the Developer portal, then re-run." >&2
            echo "       Decoded profile: $PROFILE_PLIST" >&2
            exit 1 ;;
    esac
fi

# The upload's own checks, without submitting.
echo "🔊 validate with App Store Connect"
xcrun altool --validate-app -f "$UPLOAD_FILE" -t "$ALTOOL_TYPE" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"

if [[ $UPLOAD == 0 ]]; then
    echo "🔊 done (validated, NOT uploaded)"
    echo "    $UPLOAD_EXT: $UPLOAD_FILE"
    echo "    submit it with: scripts/release-appstore.sh --platform $PLATFORM --upload"
    exit 0
fi

echo "🔊 upload to App Store Connect"
xcrun altool --upload-app -f "$UPLOAD_FILE" -t "$ALTOOL_TYPE" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH"

echo "🔊 done — $PLATFORM $VERSION ($BUILD_NUM) uploaded"
echo "    Processing takes a few minutes. The build then appears under"
echo "    App Store Connect -> Vibe -> TestFlight / the version's Build section."
