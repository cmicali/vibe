#!/usr/bin/env bash
#
# Build a distributable, notarized Vibe.app: generate -> archive (Release) ->
# export signed with Developer ID -> notarize -> staple -> zip.
#
# This is NOT scripts/release-appstore.sh. The two release paths are different
# products:
#
#   release.sh           Developer ID + notarize + staple  -> a .zip you host
#                        yourself. Anyone can download and run it.
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

BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/$PRODUCT.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$PRODUCT.app"
ZIP="$BUILD_DIR/$PRODUCT.zip"

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
# documents why the archive carries no signing overrides.
# ---------------------------------------------------------------------------
asc_generate_and_archive

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
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

asc_export_archive "Developer ID" developer-id

# ---------------------------------------------------------------------------
# Notarize + staple.
# ---------------------------------------------------------------------------
echo "🔊 zip for submission"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "🔊 notarize (waits for Apple's verdict)"
xcrun notarytool submit "$ZIP" \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

echo "🔊 staple + validate"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
# The real test: what Gatekeeper says about the app a recipient would download.
spctl -a -vvv --type exec "$APP"

# Repackage the now-stapled app for distribution.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "🔊 done"
echo "    app: $APP"
echo "    zip: $ZIP  (notarized + stapled)"
