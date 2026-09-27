#!/bin/bash
# The checkout-wide build lock. Source it for the two functions, or run it as
# `build-lock.sh <command> [args ...]` to hold the lock for one command.
#
# Each session has its own simulator (sim-udid.sh), but the build tree is
# shared by every session in the checkout: Vibe.xcodeproj, build/DerivedData
# and the products every session installs from. Unserialized, xcodegen rewrites
# the project under a live xcodebuild, two xcodebuilds clobber one products dir
# (a 1-2 minute start measured at twelve, compiling nothing), and `simctl
# install` copies a bundle another session is still linking. Only the build is
# serialized; gestures, screenshots and the channel stay concurrent.
#
# Sourced use, from a script that has ROOT set:
#     . "$ROOT/scripts/build-lock.sh"
#     vibe_build_lock_acquire     # blocks; installs its own exit trap
#     ...                         # xcodegen / xcodebuild / simctl install
#
# Overrides: VIBE_BUILD_LOCK_TIMEOUT (seconds to wait, default 1800),
# VIBE_BUILD_LOCK_DIR (the lock path).

VIBE_BUILD_LOCK_DIR="${VIBE_BUILD_LOCK_DIR:-${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/build/.build-lock}"

vibe_build_lock_acquire() {
    # Already ours — this process, or an ancestor that exported it. Taking it
    # again would deadlock (drive-ios.sh start calls install-ios.sh under it).
    if [ -n "${VIBE_BUILD_LOCK_HELD:-}" ]; then
        return 0
    fi

    local timeout="${VIBE_BUILD_LOCK_TIMEOUT:-1800}"
    local deadline=$(( $(date +%s) + timeout ))
    local unaccounted=0
    local owner=""

    mkdir -p "$(dirname "$VIBE_BUILD_LOCK_DIR")"
    until mkdir "$VIBE_BUILD_LOCK_DIR" 2>/dev/null; do
        owner="$(cat "$VIBE_BUILD_LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$owner" ]; then
            unaccounted=0
            # A named holder that is gone left the lock behind: break it now.
            if ! kill -0 "$owner" 2>/dev/null; then
                rm -rf "$VIBE_BUILD_LOCK_DIR"
            fi
        else
            # TRAP: the pid file is written just AFTER the mkdir that takes the
            # lock, so a missing pid may be a holder milliseconds old. Only
            # this case waits out a grace period before breaking the lock.
            unaccounted=$(( unaccounted + 1 ))
            if [ "$unaccounted" -ge 20 ]; then
                rm -rf "$VIBE_BUILD_LOCK_DIR"
                unaccounted=0
            fi
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "build lock still held by pid ${owner:-?} after ${timeout}s: $VIBE_BUILD_LOCK_DIR" >&2
            return 1
        fi
        sleep 0.25
    done

    printf '%s\n' "$$" > "$VIBE_BUILD_LOCK_DIR/pid"
    export VIBE_BUILD_LOCK_HELD="$$"
    trap vibe_build_lock_release EXIT
    trap 'vibe_build_lock_release; exit 130' INT TERM
}

vibe_build_lock_release() {
    # Only the taker gives it back: a child that inherited VIBE_BUILD_LOCK_HELD
    # must not release its parent's lock when it exits.
    if [ "${VIBE_BUILD_LOCK_HELD:-}" != "$$" ]; then
        return 0
    fi
    unset VIBE_BUILD_LOCK_HELD
    rm -rf "$VIBE_BUILD_LOCK_DIR"
}

# Wrapper form, for callers with no shell to source into (the Makefile).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    [ "$#" -ge 1 ] || { echo "usage: build-lock.sh <command> [args ...]" >&2; exit 64; }
    vibe_build_lock_acquire
    "$@"
fi
