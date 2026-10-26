#!/usr/bin/env bash
#
# Generate Vibe.xcodeproj from project.yml (via XcodeGen) and build the app.
#
# Usage: scripts/build/build.sh [Debug|Release|AppStore] [xcodebuild args ...]
#   configuration defaults to Release; the rest pass through to xcodebuild.
#
# Output: <slot's DerivedData>/Build/Products/<configuration>/<product>.app
# (scripts/vibe-env.sh). A slotted Debug build is Vibe-<slot>.app, with its own
# bundle id. Every other build is the stock Vibe.app.
set -euo pipefail

CONFIGURATION="${1:-Release}"
shift || true
case "$CONFIGURATION" in
    Debug|Release|AppStore) ;;
    *) echo "error: configuration must be Debug, Release or AppStore (got '$CONFIGURATION')" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/../.."

# The product is named from the slot, never from a VIBE_APP set elsewhere.
unset VIBE_APP
. scripts/vibe-env.sh

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found — install with: brew install xcodegen" >&2
    exit 1
fi

# SKIP_GENERATE=1: the caller has already generated (the Makefile's `build`).
if [[ "${SKIP_GENERATE:-}" == "1" ]]; then
    echo "🔊 skipping xcodegen generate (SKIP_GENERATE=1)"
else
    echo "🔊 xcodegen generate"
    scripts/build/build-lock.sh xcodegen generate
fi

# Argv overrides, never project.yml. No release path can then inherit a slot.
PRODUCT=Vibe
SLOT_SETTINGS=()
if [[ "$CONFIGURATION" == Debug && -n "$VIBE_SLOT" ]]; then
    PRODUCT="$VIBE_PRODUCT"
    SLOT_SETTINGS=("PRODUCT_NAME=$VIBE_PRODUCT" "PRODUCT_BUNDLE_IDENTIFIER=$VIBE_BUNDLE_ID")
fi

echo "🔊 xcodebuild ($CONFIGURATION${VIBE_SLOT:+, slot $VIBE_SLOT})"
xcodebuild \
    -project Vibe.xcodeproj \
    -scheme Vibe \
    -configuration "$CONFIGURATION" \
    -parallelizeTargets \
    -showBuildTimingSummary \
    -derivedDataPath "$VIBE_DERIVED_DATA" ${SLOT_SETTINGS[@]+"${SLOT_SETTINGS[@]}"} ${@+"$@"} build

APP="$VIBE_DERIVED_DATA/Build/Products/$CONFIGURATION/$PRODUCT.app"
[[ -x "$APP/Contents/MacOS/$PRODUCT" ]] || { echo "error: the build left no $APP" >&2; exit 1; }
echo "🔊 built $APP"
