#!/usr/bin/env bash
#
# Run clang's static analyzer over BOTH app targets and fail on any finding in
# our own sources.
#
# Both, because "the analyzer is a gate" was macOS-only for as long as there
# has been an iOS target: Vibe/iOS and the iOS halves of the shared subsystems
# — a few thousand lines — were never analyzed at all, and CI's build-ios job
# compiles them without analyzing.
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

mkdir -p build

# The analyzer's own findings go to stdout as warnings; CLANG_ANALYZER_OUTPUT
# text keeps them there rather than writing .plist files nothing reads. The
# build must still be allowed to fail on its own terms, hence the tee and the
# PIPESTATUS check rather than `set -o pipefail` swallowing the status.
#
# The iOS leg needs a destination (there is no default device) and no signing;
# a generic simulator destination analyzes without booting anything.
analyze_scheme() {   # analyze_scheme <scheme> <log-suffix> [extra xcodebuild args...]
    local scheme="$1" suffix="$2"
    shift 2
    local log="build/analyze-$suffix-$CONFIGURATION.log"

    echo "🔊 xcodebuild analyze ($scheme, $CONFIGURATION)"
    set +e
    xcodebuild analyze \
        -project Vibe.xcodeproj \
        -scheme "$scheme" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath build/AnalyzeDD \
        "$@" \
        CLANG_ANALYZER_OUTPUT=text 2>&1 | tee "$log"
    local build_status="${PIPESTATUS[0]}"
    set -e

    if [[ "$build_status" -ne 0 ]]; then
        echo "❌ analyze failed to build $scheme (see $log)" >&2
        exit "$build_status"
    fi

    # grep returns 1 on no match under set -e, so it is guarded either way.
    local findings
    findings="$(grep -E '^/.*: (warning|error): .*\[[a-zA-Z]' "$log" | grep -v '/ThirdParty/' || true)"
    if [[ -n "$findings" ]]; then
        local count
        count="$(printf '%s\n' "$findings" | wc -l | tr -d ' ')"
        echo >&2
        echo "❌ static analyzer ($scheme): $count finding(s)" >&2
        printf '%s\n' "$findings" >&2
        exit 1
    fi
}

analyze_scheme Vibe macos
analyze_scheme VibeiOS ios \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO

echo "✅ static analyzer: clean (Vibe, VibeiOS)"
