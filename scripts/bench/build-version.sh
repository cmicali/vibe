#!/bin/bash
# Build one released version of the macOS app for the performance benchmark.
#
# Usage: scripts/bench/build-version.sh <label> <git ref>
# Output: build/bench/apps/<label>/Vibe.app
#
# Release with the debug channel enabled and verbose logging disabled.
# VIBE_SIGNPOSTS=1 links the work tally the debug verbs call. In an older
# version DEBUG switched on the signposts and the tally, so every version
# builds the same way.
# A separate bundle id protects preferences. The separate executable name
# keeps Vibe launchers from killing the benchmark. CFFIXED_USER_HOME isolates
# caches but does not isolate cfprefsd's preferences.
# Sources are a detached worktree. Version patches add required debug verbs.
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
    # A version with vibe-libs needs its submodule, or its pieces drop out.
    if [ -f "$SRC/.gitmodules" ]; then
        git -C "$SRC" submodule update --init --recursive >/dev/null
    fi
    if [ -f "$PATCH" ]; then
        git -C "$SRC" apply "$PATCH"
    fi
fi

mkdir -p "$(dirname "$DD")"
cd "$SRC"

# Isolate channel files to keep unrelated temp-directory entries out of its scan.
# The transport is vibe-libs' dev/DebugChannel in a version that has it.
CHANNEL_DIRS=(Vibe/Debug)
[ ! -d vibe-libs/dev/DebugChannel ] || CHANNEL_DIRS+=(vibe-libs/dev/DebugChannel)
grep -rl 'NSTemporaryDirectory()' "${CHANNEL_DIRS[@]}" | xargs perl -pi -e \
    's/(?<!\?: )NSTemporaryDirectory\(\)/(NSProcessInfo.processInfo.environment[\@"VIBE_DEBUG_TMPDIR"] ?: NSTemporaryDirectory())/g'

xcodegen generate >/dev/null
xcodebuild \
    -project Vibe.xcodeproj \
    -scheme Vibe \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DD" \
    GCC_PREPROCESSOR_DEFINITIONS='NDEBUG=1 DEBUG=1 VIBE_SIGNPOSTS=1 VIBE_ENABLE_EXCLUSIVE_OUTPUT=1 VIBE_VERBOSE_LOGGING=0' \
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
