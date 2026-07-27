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

# Optional credential file, so a normal run needs no environment fiddling.
[[ -f .release-env ]] && source .release-env

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
command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen not found — install with: brew install xcodegen" >&2; exit 1; }

missing_key() {
    cat >&2 <<MSG
error: App Store Connect API credentials not configured.

  Create a key at App Store Connect -> Users and Access -> Integrations ->
  App Store Connect API -> Team Keys -> (+), with the ADMIN role (App Manager
  is not enough — distribution certificates are Admin-gated).
  Download AuthKey_<KEYID>.p8 (offered exactly once) to
  ~/.appstoreconnect/private_keys/, then write a .release-env in the repo root:

      ASC_KEY_ID=XXXXXXXXXX
      ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  (.release-env is gitignored — it is a pointer to the key, not the key.)
MSG
    exit 1
}

[[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || missing_key

ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "error: API private key not found at: $ASC_KEY_PATH" >&2
    echo "       Put AuthKey_${ASC_KEY_ID}.p8 there, or set ASC_KEY_PATH." >&2
    exit 1
fi

# xcodebuild's provisioning flags. -allowProvisioningUpdates lets it create the
# distribution cert / App ID / profile on this machine the first time.
AUTH=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
BUILD_NUM=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\(.*\)$/\1/p' project.yml | head -1)

echo "🔊 team id     : $TEAM_ID"
echo "🔊 api key     : $ASC_KEY_ID (issuer $ASC_ISSUER_ID)"
echo "🔊 version     : $VERSION ($BUILD_NUM)"
echo "🔊 upload      : $([[ $UPLOAD == 1 ]] && echo yes || echo 'no (validate only)')"

# ---------------------------------------------------------------------------
# Generate + archive + export.
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"

echo "🔊 xcodegen generate"
xcodegen generate

# No signing overrides here, deliberately. The archive keeps project.yml's
# CODE_SIGN_IDENTITY "-" (sign to run locally); distribution signing happens at
# the export step below, which re-signs the app outright. This mirrors Xcode's
# own Archive -> Distribute App flow. Pinning CODE_SIGN_IDENTITY="Apple
# Distribution" here instead fails the archive with "conflicting provisioning
# settings" — under automatic signing the identity is Xcode's to choose.
echo "🔊 archive (Release)"
xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" "${AUTH[@]}" \
    archive

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
# xcodebuild reports cloud-signing failures as a bare "Cloud signing permission
# error" and buries Apple's actual 403 in a temp .xcdistributionlogs bundle, so
# surface the real reason here rather than making the next person go digging.
echo "🔊 export (App Store package)"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
        -exportPath "$EXPORT_DIR" "${AUTH[@]}" 2>&1 | tee "$BUILD_DIR/export.log"; then
    if grep -q "Cloud signing permission error" "$BUILD_DIR/export.log"; then
        cat >&2 <<'MSG'

error: the App Store Connect API key lacks permission for cloud-managed
       distribution certificates. Apple's underlying response is:

         403 FORBIDDEN_ERROR — "You haven't been given access to cloud-managed
         distribution certificates."

       The key needs the ADMIN role. A key's role cannot be changed after it
       is created, so generate a new one (Users and Access -> Integrations ->
       App Store Connect API -> Team Keys -> (+) -> Access: Admin), download
       its .p8 to ~/.appstoreconnect/private_keys/, and point ASC_KEY_ID in
       .release-env at the new key id.
MSG
    fi
    exit 1
fi

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
