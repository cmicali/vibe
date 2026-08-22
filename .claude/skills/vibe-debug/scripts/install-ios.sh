#!/bin/bash
# Make the simulator's installed app match the built one. This is the single
# home of that rule, and it exists because getting it wrong is SILENT: the app
# launches, the debug channel answers, gestures land, screenshots render — all
# against the previous binary, so every conclusion drawn from them is wrong
# about the code that is actually checked out.
#
# Usage: install-ios.sh <udid> [--check]
#   (no flag)  install when the device's bundle differs from the built one, or
#              when nothing is installed; a no-op otherwise
#   --check    report only, install nothing; exit 1 when the app is stale
#
# STALENESS IS DECIDED BY CONTENT, never by time. The two bundles are compared
# by hashing every file in each — paths included, so a rename counts, and
# resources included, so a `make strings` run that leaves the executable
# untouched still counts. ~80ms for the 25MB bundle, which is why --check can
# afford to run per `drive-ios.sh status`.
#
# It used to compare the mtime of the executable, and that broke every session
# but the one doing the building. Every xcodebuild run relinks
# Vibe.app/Vibe even when it compiles nothing (measured across three sessions'
# driver logs: zero CompileC, one Ld each), so ANY session's build made every
# OTHER session's app "stale" with no source change between them. The agent is
# told that appStale invalidates its gesture results, so it dutifully threw
# away good work and reran launch-ios.sh — bouncing a live app mid-session,
# losing its playlist and playback state, and paying the driver's ~60s
# accessibility re-attach on the next gesture. Content hashing reports what the
# device is actually running, so a relink that changed nothing changes nothing.
#
# INSTALLING ONLY WHEN THE BUNDLE GENUINELY DIFFERS is what makes this safe to
# call with a drive-ios.sh session live. An unnecessary install is the thing to
# avoid — installcoordinationd serializes it and can bounce the running app a
# minute later, mid-test — while a necessary one is a bounce the caller wanted
# anyway, since both callers relaunch the app immediately after.
#
# TRAP: the install runs under the checkout-wide build lock, because the
# products directory is shared by every session and `simctl install` copying a
# bundle that another session's linker is midway through writing installs a
# torn app that launches and answers exactly like a whole one.
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

# Contents and layout, nothing about time. Relative paths, so the built bundle
# and the installed copy of it hash identically — `simctl install` copies the
# files verbatim, which is the one property this depends on and the reason the
# post-install re-check below proves rather than assumes it.
bundle_hash() {
    ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 1 ) \
        | shasum -a 1 | cut -d' ' -f1
}

installed_container() {
    xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true
}

# Deliberately outside the lock: --check is on drive-ios.sh status's path and
# must not block behind somebody else's two-minute build. The cost is that a
# bundle being written right now can read as stale — which errs toward
# reinstalling, and the install path below re-reads it under the lock anyway.
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
# Re-read under the lock: the bundle compared above may have been another
# session's half-written build, and is now whole.
BUILT_HASH="$(bundle_hash "$APP")"
INSTALLED="$(installed_container)"
if [ -n "$INSTALLED" ] && [ -d "$INSTALLED" ] && [ "$(bundle_hash "$INSTALLED")" = "$BUILT_HASH" ]; then
    exit 0
fi

xcrun simctl install "$UDID" "$APP"

# Prove it landed rather than assume it. A mismatch here means either the
# install did not take, or `simctl install` stopped copying verbatim — and the
# second would turn the comparison above into "always stale", reinstalling on
# every call, so it must be loud rather than silent.
INSTALLED="$(installed_container)"
if [ -z "$INSTALLED" ] || [ ! -d "$INSTALLED" ] || [ "$(bundle_hash "$INSTALLED")" != "$BUILT_HASH" ]; then
    echo "install did not take: $UDID does not hold the bundle at $APP" >&2
    exit 1
fi
