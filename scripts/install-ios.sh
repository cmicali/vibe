#!/usr/bin/env bash
#
# Build the iOS app for a paired physical device and install it over the
# CoreDevice tunnel. Signed, so it needs a development certificate and a
# provisioning profile for com.commonwealthrecordings.Vibe.
#
# Usage: scripts/install-ios.sh [Debug|Release]   (default: Release)
#   DEVICE=<name, identifier or UDID>  pick a phone when more than one is paired.
#   Simulators are never candidates: devicectl lists them as paired too.
#
# Output: build/DerivedData/Build/Products/<configuration>-iphoneos/Vibe.app
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "error: configuration must be Debug or Release (got '$CONFIGURATION')" >&2; exit 1 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq not found — install with: brew install jq" >&2
    exit 1
fi

DEVICES_JSON="$(mktemp -t vibe-devices)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null

# tunnelState is NOT a filter: it reads "disconnected" for a paired device
# devicectl will happily open a tunnel to on demand.
MATCHES="$(jq -r --arg want "${DEVICE:-}" '
    .result.devices[]
    | select(.hardwareProperties.platform == "iOS")
    | select(.hardwareProperties.reality == "physical")
    | select(.connectionProperties.pairingState == "paired")
    | select($want == "" or .identifier == $want or .hardwareProperties.udid == $want
             or .deviceProperties.name == $want)
    | "\(.identifier)\t\(.deviceProperties.name)"
' "$DEVICES_JSON")"

COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
if [[ "$COUNT" -eq 0 ]]; then
    echo "error: no paired iOS device${DEVICE:+ matching '$DEVICE'}. Connect and trust the device, then: xcrun devicectl list devices" >&2
    exit 1
fi
if [[ "$COUNT" -gt 1 ]]; then
    echo "error: $COUNT paired iOS devices — pick one with DEVICE=<name or identifier>:" >&2
    printf '%s\n' "$MATCHES" | sed 's/^/  /' >&2
    exit 1
fi

DEVICE_ID="${MATCHES%%$'\t'*}"
DEVICE_NAME="${MATCHES#*$'\t'}"

# SKIP_GENERATE=1: the caller has already generated (the Makefile's `install-ios`).
if [[ "${SKIP_GENERATE:-}" == "1" ]]; then
    echo "🔊 skipping xcodegen generate (SKIP_GENERATE=1)"
else
    echo "🔊 xcodegen generate"
    xcodegen generate
fi

echo "🔊 xcodebuild VibeiOS ($CONFIGURATION) for $DEVICE_NAME"
xcodebuild \
    -project Vibe.xcodeproj \
    -scheme VibeiOS \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates build

APP="build/DerivedData/Build/Products/$CONFIGURATION-iphoneos/Vibe.app"
echo "🔊 installing $APP to $DEVICE_NAME"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
