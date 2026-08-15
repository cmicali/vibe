#!/usr/bin/env bash
#
# Run clang's static analyzer over the app target and fail on any finding in
# our own sources.
#
# Usage: scripts/analyze.sh [Debug|Release]
#   configuration defaults to Debug, which is what the Vibe scheme's analyze
#   action uses and what CI runs.
#
# The analyzer's checks are turned on in project.yml (CLANG_ANALYZER_NONNULL,
# CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION: YES_AGGRESSIVE). Without this script
# nothing ran them, so they were a setting rather than a gate.
#
# ThirdParty/ is excluded: vendored TagLib, PINCache and PINOperation are other
# authors' code, which the repo does not restyle and cannot fix. Every other
# check here draws the same line.
set -euo pipefail

CONFIGURATION="${1:-Debug}"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) echo "error: configuration must be Debug or Release (got '$CONFIGURATION')" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found — install with: brew install xcodegen" >&2
    exit 1
fi

if [[ "${SKIP_GENERATE:-}" == "1" ]]; then
    echo "🔊 skipping xcodegen generate (SKIP_GENERATE=1)"
else
    echo "🔊 xcodegen generate"
    xcodegen generate
fi

LOG="build/analyze-$CONFIGURATION.log"
mkdir -p build

echo "🔊 xcodebuild analyze ($CONFIGURATION)"
# The analyzer's own findings go to stdout as warnings; CLANG_ANALYZER_OUTPUT
# text keeps them there rather than writing .plist files nothing reads. The
# build must still be allowed to fail on its own terms, hence the tee and the
# PIPESTATUS check rather than `set -o pipefail` swallowing the status.
set +e
xcodebuild analyze \
    -project Vibe.xcodeproj \
    -scheme Vibe \
    -configuration "$CONFIGURATION" \
    -derivedDataPath build/AnalyzeDD \
    CLANG_ANALYZER_OUTPUT=text 2>&1 | tee "$LOG"
BUILD_STATUS="${PIPESTATUS[0]}"
set -e

if [[ "$BUILD_STATUS" -ne 0 ]]; then
    echo "❌ analyze failed to build (see $LOG)" >&2
    exit "$BUILD_STATUS"
fi

# grep -c returns 1 on no match under set -e, so it is guarded either way.
FINDINGS="$(grep -E '^/.*: (warning|error): .*\[[a-zA-Z]' "$LOG" | grep -v '/ThirdParty/' || true)"

if [[ -n "$FINDINGS" ]]; then
    COUNT="$(printf '%s\n' "$FINDINGS" | wc -l | tr -d ' ')"
    echo >&2
    echo "❌ static analyzer: $COUNT finding(s)" >&2
    printf '%s\n' "$FINDINGS" >&2
    exit 1
fi

echo "✅ static analyzer: clean"
