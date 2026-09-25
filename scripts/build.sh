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
    echo "🔊 skipping xcodegen generate (SKIP_GENERATE=1)"
else
    echo "🔊 xcodegen generate"
    xcodegen generate
fi

# VIBE_SIGN_MAC=1 signs with the Apple Development certificate instead of
# ad-hoc — the only way to exercise the desktop widget locally (the Makefile's
# signing TRAP says why). No profile: the team-prefixed app group needs none.
SIGN_ARGS=()
if [[ "${VIBE_SIGN_MAC:-}" == "1" ]]; then
    SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development")
fi

echo "🔊 xcodebuild ($CONFIGURATION)"
xcodebuild \
    -project Vibe.xcodeproj \
    -scheme Vibe \
    -configuration "$CONFIGURATION" \
    -parallelizeTargets \
    -derivedDataPath build/DerivedData ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build

echo "🔊 built build/DerivedData/Build/Products/$CONFIGURATION/Vibe.app"
