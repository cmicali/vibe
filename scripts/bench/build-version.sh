#!/bin/bash
# Build one released version of the macOS app for the performance benchmark.
#
# Usage: scripts/bench/build-version.sh <label> <git ref>
# Output: build/bench/apps/<label>/Vibe.app
#
# Every version is built the same way, whatever its own project.yml says, so
# the suite compares code and not build settings: Release optimization (-Os,
# NDEBUG, no NSAssert) with DEBUG=1 added back so the debug command channel
# the suite drives is compiled in; VIBE_VERBOSE_LOGGING=0, the stable-release
# logging, since betas turn on instrumentation a release does not carry; no
# App Sandbox, so the app reads the corpus by path and keeps its caches under
# the HOME the runner hands it; and its own bundle ID, since an unsandboxed
# app's preferences are cfprefsd's, in the real home, whatever that HOME says,
# and the runner resets that domain before every scenario; and its own process
# name, VibeBenchApp, since other sessions' tooling (vibe-debug's launch.sh) does
# `pkill -x Vibe` and would kill a measurement mid-run.
#
# The source is a detached worktree under build/bench/src/<label>, patched
# with scripts/bench/patches/<label>.patch when one exists: the backports that
# give old versions the channel verbs the suite needs.
set -euo pipefail

LABEL="$1"
REF="$2"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/build/bench/src/$LABEL"
DD="$ROOT/build/bench/dd/$LABEL"
OUT="$ROOT/build/bench/apps/$LABEL"
PATCH="$ROOT/scripts/bench/patches/$LABEL.patch"

if [ ! -d "$SRC" ]; then
    git -C "$ROOT" worktree prune # `make clean` deletes build/ out from under earlier ones
    git -C "$ROOT" worktree add --detach "$SRC" "$REF" >/dev/null
    if [ -f "$PATCH" ]; then
        git -C "$SRC" apply "$PATCH"
    fi
fi

mkdir -p "$(dirname "$DD")"
cd "$SRC"

# The channel's files live in NSTemporaryDirectory(), which an unsandboxed app
# cannot move (it ignores TMPDIR): the per-user temp dir, thousands of entries
# the app lists on every command, ~20 ms each. Point the channel alone at
# VIBE_DEBUG_TMPDIR. Vibe/Debug/ only, never shipping code; idempotent.
grep -rl 'NSTemporaryDirectory()' Vibe/Debug | xargs perl -pi -e \
    's/(?<!\?: )NSTemporaryDirectory\(\)/(NSProcessInfo.processInfo.environment[\@"VIBE_DEBUG_TMPDIR"] ?: NSTemporaryDirectory())/g'

xcodegen generate >/dev/null
xcodebuild \
    -project Vibe.xcodeproj \
    -scheme Vibe \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DD" \
    GCC_PREPROCESSOR_DEFINITIONS='NDEBUG=1 DEBUG=1 VIBE_ENABLE_EXCLUSIVE_OUTPUT=1 VIBE_VERBOSE_LOGGING=0' \
    VIBE_VERBOSE_LOGGING=0 \
    ENABLE_APP_SANDBOX=NO \
    PRODUCT_BUNDLE_IDENTIFIER=com.commonwealthrecordings.Vibe.bench \
    EXECUTABLE_NAME=VibeBenchApp \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    DEBUG_INFORMATION_FORMAT=dwarf \
    CODE_SIGN_IDENTITY=- \
    build >"$DD.log" 2>&1 || { tail -40 "$DD.log" >&2; echo "build failed: $DD.log" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$DD/Build/Products/Release/Vibe.app" "$OUT/"
git -C "$SRC" rev-parse HEAD >"$OUT/commit"
echo "$OUT/Vibe.app"
