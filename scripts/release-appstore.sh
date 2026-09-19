#!/usr/bin/env bash
#
# Build and submit Vibe to the App Store, either platform:
#   generate -> archive (Release) -> export signed for App Store -> validate
#   -> (with --upload) upload to App Store Connect.
#
#   --platform macos   universal (arm64 + x86_64) .pkg   Mac App Store
#   --platform ios     arm64 .ipa, widget embedded       iOS App Store
#
# ONE app record, because both targets ship bundle id
# com.commonwealthrecordings.Vibe — that is Universal Purchase, and the two
# platforms are separate version trains under it. project.yml declares
# MARKETING_VERSION / CURRENT_PROJECT_VERSION once for both, so a release cuts
# the same number on each; the ASC version record for the platform being
# uploaded must already carry that version string.
#
# This is NOT scripts/release.sh. The two release paths are different products:
#
#   release.sh           Developer ID + notarize + staple  -> universal and
#                        arm64-only DMG/zip direct-download products. macOS
#                        only: there is no direct download for iOS.
#   release-appstore.sh  Apple Distribution + App Store profile -> a .pkg or
#                        .ipa uploaded to App Store Connect. NOT notarized (the
#                        store notarizes on its side); the Developer ID cert
#                        is not used and would be rejected here.
#
# ---------------------------------------------------------------------------
# One-time prerequisites (this script checks for them, it cannot create them):
#
#   1. An active Apple Developer Program membership on team $TEAM_ID.
#
#   2. An App Store Connect API key with the ADMIN role:
#        App Store Connect -> Users and Access -> Integrations
#          -> App Store Connect API -> Team Keys -> (+) -> Access: Admin
#      Download the AuthKey_<KEYID>.p8 ONCE (Apple never offers it again) and
#      put it in ~/.appstoreconnect/private_keys/. Note the Key ID and the
#      Issuer ID shown on that page.
#
#      Admin is REQUIRED, not merely preferred: cloud-managed distribution
#      certificates are Admin-gated. An App Manager key authenticates fine and
#      can upload, but the export dies with 403 FORBIDDEN_ERROR / "You haven't
#      been given access to cloud-managed distribution certificates". A key's
#      role cannot be edited after creation — generate a new key instead.
#
#   3. An app record in App Store Connect for bundle id
#      com.commonwealthrecordings.Vibe (Apps -> (+) -> New macOS App), with the
#      platform being uploaded added to it. Uploads for a bundle id with no app
#      record — or for a platform not on that record — are rejected.
#
#   Signing certificates and the provisioning profile do NOT need to be made by
#   hand: the API key plus -allowProvisioningUpdates lets xcodebuild create and
#   install the Apple Distribution cert, the Mac Installer cert, the App ID and
#   the App Store profile on first run.
#
# ---------------------------------------------------------------------------
# Usage:
#   scripts/release-appstore.sh                        # macOS, build + validate
#   scripts/release-appstore.sh --upload               # macOS, + submit
#   scripts/release-appstore.sh --platform ios         # iOS, build + validate
#   scripts/release-appstore.sh --platform ios --upload
#
# Credentials come from the environment, or from a gitignored .release-env at
# the repo root (sourced automatically if present):
#   ASC_KEY_ID      App Store Connect API key id      (required)
#   ASC_ISSUER_ID   App Store Connect API issuer id   (required)
#   ASC_KEY_PATH    path to AuthKey_<ASC_KEY_ID>.p8   (default: the standard
#                   ~/.appstoreconnect/private_keys location)
#   TEAM_ID         developer team id (default: 4UEV752JH4)
set -euo pipefail

cd "$(dirname "$0")/.."

UPLOAD=0
PLATFORM=macos
while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload) UPLOAD=1 ;;
        --platform) shift; PLATFORM="${1:-}" ;;
        --platform=*) PLATFORM="${1#*=}" ;;
        -h|--help) sed -n '2,68p' "$0"; exit 0 ;;
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

# Everything that differs between the two platforms, decided once. The rest of
# the script reads these and branches nowhere else.
#
# APP_SUBPATH is the trap: a macOS bundle nests its payload under Contents/,
# an iOS one does not, so the same Products/Applications/Vibe.app holds its
# Info.plist and executable at different depths.
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
        # A flag, not a build setting: the scheme builds for iOS only, and
        # without a destination xcodebuild is free to resolve a simulator.
        ARCHIVE_ARGS=(-destination 'generic/platform=iOS')
        # Devices are arm64 only. Asserting it still matters: an archive that
        # somehow resolved the simulator SDK would carry x86_64 and be rejected
        # by the upload with a far less obvious message.
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

# ---------------------------------------------------------------------------
# Preflight — fail early with actionable messages.
# ---------------------------------------------------------------------------
asc_require_xcodegen

asc_require_translations

asc_resolve_credentials

echo "🔊 platform    : $PLATFORM (scheme $SCHEME)"
echo "🔊 team id     : $TEAM_ID"
echo "🔊 api key     : $ASC_KEY_ID (issuer $ASC_ISSUER_ID)"
echo "🔊 upload      : $([[ $UPLOAD == 1 ]] && echo yes || echo 'no (validate only)')"

# ---------------------------------------------------------------------------
# Generate + archive + export — shared mechanics in asc-build-lib.sh, which
# documents why the archive carries no signing overrides.
# ---------------------------------------------------------------------------
asc_generate_and_archive "${ARCHIVE_ARGS[@]}"

# The version comes from the archived app's Info.plist, the same way
# github-release.sh takes it from the built app, so the number this run reports
# is the number it actually uploads.
#
# It used to be scraped out of project.yml with `sed … | head -1`, and
# project.yml declares MARKETING_VERSION twice — once per app target. That
# worked only because the macOS block happens to sit above the iOS one: moving
# the targets, or adding a third, would have silently reported (and logged) the
# wrong release, since the guard only checked the scrape was non-empty. The
# built bundle cannot be ambiguous about which target it came from — and with
# both platforms shipping from this script, a scrape could not even be made
# unambiguous.
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
    <!-- Defaults to YES, which lets Xcode silently bump the build number at
         upload — the shipped number would then disagree with project.yml.
         MARKETING_VERSION / CURRENT_PROJECT_VERSION stay the source of truth. -->
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

# Produces a signed installer package (macOS) or .ipa (iOS). The export also
# strips get-task-allow from the entitlements — an App Store build must not
# carry it.
asc_export_archive "App Store package" ""

# Globbed, not named: the exported file takes its name from the product on one
# platform and can take it from the scheme on the other, and the two disagree
# here (product Vibe, scheme VibeiOS).
shopt -s nullglob
EXPORTED=("$EXPORT_DIR"/*."$UPLOAD_EXT")
shopt -u nullglob
[[ ${#EXPORTED[@]} == 1 ]] || {
    echo "error: expected exactly one .$UPLOAD_EXT in $EXPORT_DIR, found ${#EXPORTED[@]}:" >&2
    ls -la "$EXPORT_DIR" >&2
    exit 1; }
UPLOAD_FILE="${EXPORTED[0]}"

# ---------------------------------------------------------------------------
# The iOS payload carries a second bundle and a shared container, and neither
# is visible until the archive has been re-signed for distribution. The widget
# reads everything it draws out of the app group, so a distribution profile
# that silently dropped the entitlement ships a permanently blank widget to
# every user — and nothing before this point would have said so.
# ---------------------------------------------------------------------------
if [[ "$PLATFORM" == ios ]]; then
    IPA_APP="Payload/$PRODUCT.app"

    # TRAP: the listing is captured, never piped into `grep -q`. The widget's
    # line sits a third of the way into it, so grep stops reading there and the
    # unread remainder leaves unzip with a SIGPIPE that `set -o pipefail` then
    # reports as a missing widget. It passes whenever unzip finishes writing
    # before grep exits, so the bogus failure only appears on a cold, busy run
    # — which is to say, during a real release.
    IPA_LISTING="$(unzip -l "$UPLOAD_FILE")"
    grep -q "$IPA_APP/PlugIns/VibeWidget.appex/VibeWidget" <<<"$IPA_LISTING" || {
        echo "error: $UPLOAD_FILE carries no VibeWidget.appex executable" >&2
        exit 1; }

    # TRAP: PlistBuddy seeks its input, so it cannot read a pipe — /dev/stdin
    # fails with "Error Reading File". Both forms land in $BUILD_DIR, where
    # they stay readable if the check below fails. PROFILE_GROUPS, not GROUPS:
    # bash owns that name and silently discards the assignment.
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

# ---------------------------------------------------------------------------
# Validate — the same checks the upload runs, without submitting anything.
# ---------------------------------------------------------------------------
echo "🔊 validate with App Store Connect"
xcrun altool --validate-app -f "$UPLOAD_FILE" -t "$ALTOOL_TYPE" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

if [[ $UPLOAD == 0 ]]; then
    echo "🔊 done (validated, NOT uploaded)"
    echo "    $UPLOAD_EXT: $UPLOAD_FILE"
    echo "    submit it with: scripts/release-appstore.sh --platform $PLATFORM --upload"
    exit 0
fi

# ---------------------------------------------------------------------------
# Upload.
# ---------------------------------------------------------------------------
echo "🔊 upload to App Store Connect"
xcrun altool --upload-app -f "$UPLOAD_FILE" -t "$ALTOOL_TYPE" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

echo "🔊 done — $PLATFORM $VERSION ($BUILD_NUM) uploaded"
echo "    Processing takes a few minutes. The build then appears under"
echo "    App Store Connect -> Vibe -> TestFlight / the version's Build section."
