#!/usr/bin/env bash
#
# Build a distributable, notarized Vibe.app: generate -> archive (Release) ->
# export signed with Developer ID -> notarize -> staple -> zip.
#
# The app embeds no frameworks/helpers (see the empty Embed Frameworks phase),
# so there is no nested code to sign — the archive/export handles everything.
#
# ---------------------------------------------------------------------------
# One-time prerequisites (this script only checks for them, it can't create them):
#
#   1. A "Developer ID Application" certificate installed in your keychain.
#      Apple Developer account -> Certificates -> "Developer ID Application".
#      (An "Apple Development" cert is NOT accepted for notarization.)
#
#   2. A notarytool credential profile stored in the keychain:
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#            --apple-id "you@example.com" --team-id "$TEAM_ID" \
#            --password "<app-specific-password>"
#      (Or an App Store Connect API key: --key / --key-id / --issuer — if you
#      use that, swap the --keychain-profile flags below for --key* flags.)
#
# ---------------------------------------------------------------------------
# Usage: scripts/release.sh
# Environment overrides:
#   DEVELOPER_ID    signing identity (default: the sole "Developer ID Application" in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile name (default: vibe-notary)
#   TEAM_ID         team id used for the Developer ID export (default: 4UEV752JH4)
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME=Vibe
PRODUCT=Vibe
TEAM_ID="${TEAM_ID:-4UEV752JH4}"
NOTARY_PROFILE="${NOTARY_PROFILE:-vibe-notary}"

BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/$PRODUCT.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$PRODUCT.app"
ZIP="$BUILD_DIR/$PRODUCT.zip"

# ---------------------------------------------------------------------------
# Preflight — fail early with actionable messages.
# ---------------------------------------------------------------------------
command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen not found — install with: brew install xcodegen" >&2; exit 1; }

# Resolve the Developer ID Application signing identity.
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
fi
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "error: no 'Developer ID Application' certificate found in the keychain." >&2
    echo "       Create one at https://developer.apple.com (Certificates ->" >&2
    echo "       'Developer ID Application'), install it, then re-run — or set" >&2
    echo "       DEVELOPER_ID to the exact identity name." >&2
    exit 1
fi

# Verify the notarytool credential profile exists (hits the notary service).
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool profile '$NOTARY_PROFILE' not found or invalid." >&2
    echo "       Create it once with:" >&2
    echo "         xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
    echo "             --apple-id <you@example.com> --team-id $TEAM_ID --password <app-specific-pw>" >&2
    exit 1
fi

echo "==> signing identity : $DEVELOPER_ID"
echo "==> notary profile   : $NOTARY_PROFILE"
echo "==> team id          : $TEAM_ID"

# ---------------------------------------------------------------------------
# Generate + archive + export.
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"

echo "==> xcodegen generate"
xcodegen generate

echo "==> archive (Release)"
xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" archive

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "==> export (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR"

# ---------------------------------------------------------------------------
# Notarize + staple.
# ---------------------------------------------------------------------------
echo "==> zip for submission"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> notarize (waits for Apple's verdict)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> staple + validate"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP"

# Repackage the now-stapled app for distribution.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> done"
echo "    app: $APP"
echo "    zip: $ZIP  (notarized + stapled)"
