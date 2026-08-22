#!/usr/bin/env bash
#
# Build and submit Vibe to the Mac App Store:
#   generate -> archive (Release) -> export signed for App Store -> validate
#   -> (with --upload) upload to App Store Connect.
#
# This is NOT scripts/release.sh. The two release paths are different products:
#
#   release.sh           Developer ID + notarize + staple  -> a .zip you host
#                        yourself. Gatekeeper-approved direct download.
#   release-appstore.sh  Apple Distribution + App Store profile -> a .pkg
#                        uploaded to App Store Connect. NOT notarized (the
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
#      com.commonwealthrecordings.Vibe (Apps -> (+) -> New macOS App).
#      Uploads for a bundle id with no app record are rejected.
#
#   Signing certificates and the provisioning profile do NOT need to be made by
#   hand: the API key plus -allowProvisioningUpdates lets xcodebuild create and
#   install the Apple Distribution cert, the Mac Installer cert, the App ID and
#   the App Store profile on first run.
#
# ---------------------------------------------------------------------------
# Usage:
#   scripts/release-appstore.sh              # build + validate, no upload
#   scripts/release-appstore.sh --upload     # build + validate + submit
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
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=1 ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "error: unknown argument '$arg' (expected --upload)" >&2; exit 1 ;;
    esac
done

# shellcheck source=scripts/asc-auth-lib.sh
source scripts/asc-auth-lib.sh
# shellcheck source=scripts/asc-build-lib.sh
source scripts/asc-build-lib.sh

SCHEME=Vibe
PRODUCT=Vibe
TEAM_ID="${TEAM_ID:-4UEV752JH4}"

BUILD_DIR="build/appstore"
ARCHIVE="$BUILD_DIR/$PRODUCT.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
PKG="$EXPORT_DIR/$PRODUCT.pkg"

# ---------------------------------------------------------------------------
# Preflight — fail early with actionable messages.
# ---------------------------------------------------------------------------
asc_require_xcodegen

asc_require_translations

asc_resolve_credentials

echo "🔊 team id     : $TEAM_ID"
echo "🔊 api key     : $ASC_KEY_ID (issuer $ASC_ISSUER_ID)"
echo "🔊 upload      : $([[ $UPLOAD == 1 ]] && echo yes || echo 'no (validate only)')"

# ---------------------------------------------------------------------------
# Generate + archive + export — shared mechanics in asc-build-lib.sh, which
# documents why the archive carries no signing overrides.
# ---------------------------------------------------------------------------
asc_generate_and_archive

# The version comes from the archived app's Info.plist, the same way
# github-release.sh takes it from the built app, so the number this run reports
# is the number it actually uploads.
#
# It used to be scraped out of project.yml with `sed … | head -1`, and
# project.yml declares MARKETING_VERSION twice — once per app target. That
# worked only because the macOS block happens to sit above the iOS one: moving
# the targets, or adding a third, would have silently reported (and logged) the
# wrong release, since the guard only checked the scrape was non-empty. The
# built bundle cannot be ambiguous about which target it came from.
ARCHIVED_APP="$ARCHIVE/Products/Applications/$PRODUCT.app"
[[ -f "$ARCHIVED_APP/Contents/Info.plist" ]] || {
    echo "error: no Info.plist at $ARCHIVED_APP — did the archive lay out somewhere else?" >&2
    exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$ARCHIVED_APP/Contents/Info.plist")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' \
    "$ARCHIVED_APP/Contents/Info.plist")"
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

# Produces a signed installer package. The export also strips
# get-task-allow from the entitlements — an App Store build must not carry it.
asc_export_archive "App Store package" ""

[[ -f "$PKG" ]] || {
    echo "error: expected $PKG, but the export produced:" >&2
    ls -la "$EXPORT_DIR" >&2
    exit 1; }

# ---------------------------------------------------------------------------
# Validate — the same checks the upload runs, without submitting anything.
# ---------------------------------------------------------------------------
echo "🔊 validate with App Store Connect"
xcrun altool --validate-app -f "$PKG" -t macos \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

if [[ $UPLOAD == 0 ]]; then
    echo "🔊 done (validated, NOT uploaded)"
    echo "    pkg: $PKG"
    echo "    submit it with: scripts/release-appstore.sh --upload"
    exit 0
fi

# ---------------------------------------------------------------------------
# Upload.
# ---------------------------------------------------------------------------
echo "🔊 upload to App Store Connect"
xcrun altool --upload-app -f "$PKG" -t macos \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

echo "🔊 done — $VERSION ($BUILD_NUM) uploaded"
echo "    Processing takes a few minutes. The build then appears under"
echo "    App Store Connect -> Vibe -> TestFlight / the version's Build section."
