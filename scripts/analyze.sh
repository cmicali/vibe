#!/usr/bin/env bash
#
# Run clang's static analyzer over BOTH app targets and fail on any finding
# outside ThirdParty/ (vendored code is not restyled; project.yml turns the
# analyzer off for its sources, and the filter below drops what its headers
# still report through ours).
#
# Usage: scripts/analyze.sh [Debug|Release|AppStore] [macos|ios|all]
#   configuration defaults to Debug (the schemes' analyze action); the leg to
#   all. CI runs Release, one leg per matrix job, and the leg IS that
#   platform's Release build: `xcodebuild analyze` compiles, links and signs
#   the whole app first, into build/AnalyzeDD. arm64 only on both: analysis
#   reads one slice anyway, and CI compiles the mac's x86_64 slice in its
#   Debug job instead.
set -euo pipefail

CONFIGURATION="${1:-Debug}"
case "$CONFIGURATION" in
    Debug|Release|AppStore) ;;
    *) echo "error: configuration must be Debug, Release or AppStore (got '$CONFIGURATION')" >&2; exit 1 ;;
esac

LEG="${2:-all}"
case "$LEG" in
    macos|ios|all) ;;
    *) echo "error: leg must be macos, ios or all (got '$LEG')" >&2; exit 1 ;;
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

# CLANG_ANALYZER_OUTPUT=text keeps findings in the log rather than in .plist
# files nothing reads; PIPESTATUS keeps xcodebuild's own status through the tee.
# The iOS leg needs a destination; a generic simulator one boots nothing.
# Implicit modules: explicit ones add a dependency scan per file, about a
# twentieth of this build.
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
        ARCHS=arm64 CLANG_ENABLE_EXPLICIT_MODULES=NO \
        CLANG_ANALYZER_OUTPUT=text 2>&1 | tee "$log"
    local build_status="${PIPESTATUS[0]}"
    set -e

    if [[ "$build_status" -ne 0 ]]; then
        echo "❌ analyze failed to build $scheme (see $log)" >&2
        exit "$build_status"
    fi

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

if [[ "$LEG" == "macos" || "$LEG" == "all" ]]; then
    analyze_scheme Vibe macos
fi
if [[ "$LEG" == "ios" || "$LEG" == "all" ]]; then
    analyze_scheme VibeiOS ios \
        -destination 'generic/platform=iOS Simulator' \
        CODE_SIGNING_ALLOWED=NO
fi

case "$LEG" in
    all)   echo "✅ static analyzer: clean (Vibe, VibeiOS)" ;;
    macos) echo "✅ static analyzer: clean (Vibe)" ;;
    ios)   echo "✅ static analyzer: clean (VibeiOS)" ;;
esac
