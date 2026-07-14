#!/usr/bin/env bash
#
# Generate Vibe.xcodeproj from project.yml (via XcodeGen) and build the app.
#
# Usage: scripts/build.sh [Debug|Release]
#   configuration defaults to Release.
#
# Output: build/DerivedData/Build/Products/<configuration>/Vibe.app
set -euo pipefail

CONFIGURATION="${1:-Release}"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "error: configuration must be Debug or Release (got '$CONFIGURATION')" >&2; exit 1 ;;
esac

# Run from the repo root regardless of the caller's working directory.
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found — install with: brew install xcodegen" >&2
    exit 1
fi

# SKIP_GENERATE=1 skips regeneration (the Makefile's `build` target sets this
# because its `project` prerequisite has already run `xcodegen generate`).
if [[ "${SKIP_GENERATE:-}" == "1" ]]; then
    echo "==> skipping xcodegen generate (SKIP_GENERATE=1)"
else
    echo "==> xcodegen generate"
    xcodegen generate
fi

echo "==> xcodebuild ($CONFIGURATION)"
xcodebuild \
    -project Vibe.xcodeproj \
    -scheme Vibe \
    -configuration "$CONFIGURATION" \
    -parallelizeTargets \
    -derivedDataPath build/DerivedData build

echo "==> built build/DerivedData/Build/Products/$CONFIGURATION/Vibe.app"
