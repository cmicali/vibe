#!/bin/bash
# Make the simulator's installed app match the built one — the single home of
# that rule. A stale app is SILENT: it launches, answers and takes gestures
# exactly like a fresh one.
#
# Usage: install-ios.sh <udid> [--check]
#   (no flag)  install when nothing is installed or the bundles differ
#   --check    install nothing; exit 1 when the installed app is stale
#
# Staleness is decided by content, never by time: every file of both bundles is
# hashed, paths included (~80ms for 25MB, cheap enough for every
# `drive-ios.sh status`). An mtime rule fails because every xcodebuild run
# relinks the executable even when it compiles nothing, so one session's build
# made every other session's app "stale" and bounced it mid-test.
#
# Install only when the bundles differ: an unneeded install can bounce the
# running app a minute later (installcoordinationd), mid-test, while a needed
# one is a bounce both callers want, since they relaunch next.
#
# TRAP: the install runs under the checkout-wide build lock. The products
# directory is shared, and copying a bundle another session's linker is midway
# through writing installs a torn app that answers like a whole one.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: install-ios.sh <udid> [--check]" >&2; exit 64; }
UDID="$1"
MODE="${2:-install}"

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
APP="${VIBE_IOS_APP:-$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/Vibe.app}"
BUNDLE_ID="com.commonwealthrecordings.Vibe"
. "$ROOT/scripts/build-lock.sh"

[ -d "$APP" ] || { echo "no app at $APP — build the VibeiOS scheme first, or set VIBE_IOS_APP" >&2; exit 1; }

# Relative paths, so the built bundle and its installed copy hash identically.
# Depends on `simctl install` copying verbatim, which the re-check below proves.
bundle_hash() {
    ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 1 ) \
        | shasum -a 1 | cut -d' ' -f1
}

installed_container() {
    xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true
}

# Outside the lock: --check must not block behind another session's build. A
# bundle mid-write then reads as stale, which errs toward reinstalling, and the
# install path re-reads under the lock.
INSTALLED="$(installed_container)"
BUILT_HASH="$(bundle_hash "$APP")"

if [ -n "$INSTALLED" ] && [ -d "$INSTALLED" ] && [ "$(bundle_hash "$INSTALLED")" = "$BUILT_HASH" ]; then
    exit 0
fi

if [ "$MODE" = "--check" ]; then
    echo "STALE: the simulator is running a different build than $APP" >&2
    exit 1
fi

vibe_build_lock_acquire
# Re-read under the lock: the bundle hashed above may have been half-written.
BUILT_HASH="$(bundle_hash "$APP")"
INSTALLED="$(installed_container)"
if [ -n "$INSTALLED" ] && [ -d "$INSTALLED" ] && [ "$(bundle_hash "$INSTALLED")" = "$BUILT_HASH" ]; then
    exit 0
fi

xcrun simctl install "$UDID" "$APP"

# A mismatch means the install did not take, or `simctl install` stopped
# copying verbatim — which would make every check "stale", so fail loudly.
INSTALLED="$(installed_container)"
if [ -z "$INSTALLED" ] || [ ! -d "$INSTALLED" ] || [ "$(bundle_hash "$INSTALLED")" != "$BUILT_HASH" ]; then
    echo "install did not take: $UDID does not hold the bundle at $APP" >&2
    exit 1
fi
