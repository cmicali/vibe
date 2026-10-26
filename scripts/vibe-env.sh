#!/bin/bash
# The build slot. Each agent's Debug build gets its own executable, bundle id,
# sandbox container and debug channel. No agent can then see, quit or drive
# another's instance. The build and debug tooling source this file. Another
# language runs `vibe-env.sh --print <name>`.
#
# The slot, first match wins:
#   1. VIBE_NO_SLOT=1 means no slot.
#   2. Else VIBE_SLOT, 1 to 11 letters and digits. Anything else is an error.
#   3. Else the first 8 characters of a UUID-shaped CLAUDE_CODE_SESSION_ID.
#      Subagents inherit it. Never the worktree, since agents may share one.
# Without a slot every name is the stock one.
#
# TRAP: 11 is the limit. pgrep -x matches a process name, and macOS keeps 16
# characters of it. "Vibe-" takes 5.
#
# Exports VIBE_SLOT (empty for none), VIBE_PRODUCT, VIBE_BUNDLE_ID,
# VIBE_DERIVED_DATA, VIBE_APP, VIBE_BIN and VIBE_CONTAINER. Only a Debug build
# is slotted (scripts/build/build.sh), so VIBE_APP is the Debug app. A VIBE_APP
# set beforehand wins, and its ids are read from its Info.plist.
#
# Sourcing sets those names and defines the functions below, and does nothing
# else. The release scripts source it for vibe_assert_stock_bundle alone.
# bash 3.2.

_vibe_stock_id=com.commonwealthrecordings.Vibe

_vibe_resolve() {
    local slot="" sid="${CLAUDE_CODE_SESSION_ID:-}" h='[0-9A-Fa-f]' h4 plist home=~
    h4="$h$h$h$h"
    if [ "${VIBE_NO_SLOT:-}" = 1 ]; then
        slot=""
    elif [ -n "${VIBE_SLOT:-}" ]; then
        slot="$VIBE_SLOT"
        case "$slot" in
            *[!A-Za-z0-9]*) slot="" ;;
        esac
        if [ -z "$slot" ] || [ "${#slot}" -gt 11 ]; then
            echo "vibe-env: VIBE_SLOT must be 1 to 11 letters and digits, not '$VIBE_SLOT'" >&2
            return 1
        fi
    else
        case "$sid" in
            $h4$h4-$h4-$h4-$h4-$h4$h4$h4) slot="${sid:0:8}" ;;
        esac
    fi

    VIBE_SLOT="$slot"
    VIBE_PRODUCT="Vibe${slot:+-$slot}"
    # A hyphen, not a dot: a hex slot can start with a digit, which a
    # reverse-DNS component should not.
    VIBE_BUNDLE_ID="$_vibe_stock_id${slot:+-$slot}"
    VIBE_DERIVED_DATA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/build/DerivedData${slot:+-$slot}"
    if [ -z "${VIBE_APP:-}" ]; then
        VIBE_APP="$VIBE_DERIVED_DATA/Build/Products/Debug/$VIBE_PRODUCT.app"
    elif [ -d "$VIBE_APP" ]; then
        # Physical, as ps reports a running executable.
        VIBE_APP="$(cd "$VIBE_APP" && pwd -P)"
        plist="$VIBE_APP/Contents/Info.plist"
        if [ -f "$plist" ]; then
            VIBE_PRODUCT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" || return 1
            VIBE_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" || return 1
        fi
    fi
    VIBE_BIN="$VIBE_APP/Contents/MacOS/$VIBE_PRODUCT"
    VIBE_CONTAINER="$home/Library/Containers/$VIBE_BUNDLE_ID"
    export VIBE_SLOT VIBE_PRODUCT VIBE_BUNDLE_ID VIBE_DERIVED_DATA VIBE_APP VIBE_BIN VIBE_CONTAINER
}

# Every running instance of $VIBE_PRODUCT, from any path. These are the
# instances in our container. The iOS Simulator's app is left out, since the
# stock name also matches it. A --debug-cmd client is left out too. It is the
# same binary.
vibe_own_pids() {
    local p cmd
    for p in $(pgrep -x "$VIBE_PRODUCT" 2>/dev/null); do
        cmd="$(ps -o command= -p "$p" 2>/dev/null)" || continue
        case "$cmd" in
            *CoreSimulator*|*--debug-cmd*) ;;
            *) echo "$p" ;;
        esac
    done
}

_vibe_own_gone_within() {   # <seconds>
    local i=0
    while [ -n "$(vibe_own_pids)" ]; do
        [ "$i" -lt "$(( $1 * 10 ))" ] || return 1
        sleep 0.1
        i=$(( i + 1 ))
    done
}

# Waits [grace] seconds for our instances to exit, then sends TERM, then KILL.
# TRAP: it never signals an instance under a debugger. The debugger traps
# SIGTERM and stops the process. The process keeps its pid and answers
# nothing, and every later --debug-cmd burns its timeout. ps prints p_flag in
# hex, and P_TRACED is 0x800 (sys/proc.h).
vibe_kill_own() {   # [grace seconds]
    local p flags
    _vibe_own_gone_within "${1:-0}" && return 0
    for p in $(vibe_own_pids); do
        flags="$(ps -o flags= -p "$p" 2>/dev/null | tr -d ' ')"
        if [ -n "$flags" ] && [ "$(( 0x$flags & 0x800 ))" -ne 0 ]; then
            echo "vibe: pid $p runs under a debugger. Stop the run in Xcode (⌘.), then retry." >&2
            return 1
        fi
        # A stopped process holds a TERM until it is continued.
        kill -CONT "$p" 2>/dev/null || true
    done
    kill $(vibe_own_pids) 2>/dev/null || true
    _vibe_own_gone_within 3 && return 0
    kill -9 $(vibe_own_pids) 2>/dev/null || true
    _vibe_own_gone_within 3 && return 0
    echo "vibe: $VIBE_PRODUCT survived SIGKILL: $(vibe_own_pids | tr '\n' ' ')" >&2
    return 1
}

# Quits our instances by bundle id. A build without the debug channel quits
# this way too, and it saves its window state. vibe_kill_own backs it.
vibe_quit_own() {
    [ -n "$(vibe_own_pids)" ] || return 0
    osascript -e 'ignoring application responses' \
        -e "tell application id \"$VIBE_BUNDLE_ID\" to quit" \
        -e 'end ignoring' >/dev/null 2>&1 || true
    vibe_kill_own 5
}

# Fails unless the bundle is the stock Vibe.app. A slotted build has its own
# executable and bundle id, and it must never ship.
vibe_assert_stock_bundle() {   # <app>
    local app="${1%/}" plist id exe
    plist="$app/Contents/Info.plist"
    [ -f "$plist" ] || plist="$app/Info.plist"
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" || id=""
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)" || exe=""
    if [ "${app##*/}" != Vibe.app ] || [ "$id" != "$_vibe_stock_id" ] || [ "$exe" != Vibe ]; then
        echo "error: $app is not the stock Vibe.app (bundle id '$id', executable '$exe')." >&2
        echo "       A slotted build never ships. Build with VIBE_NO_SLOT=1." >&2
        return 1
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}:${2:-}" in
        --print:VIBE_SLOT|--print:VIBE_PRODUCT|--print:VIBE_BUNDLE_ID|--print:VIBE_DERIVED_DATA) ;;
        --print:VIBE_APP|--print:VIBE_BIN|--print:VIBE_CONTAINER) ;;
        *)
            echo "usage: vibe-env.sh --print <VIBE_SLOT|VIBE_PRODUCT|VIBE_BUNDLE_ID|VIBE_DERIVED_DATA|VIBE_APP|VIBE_BIN|VIBE_CONTAINER>" >&2
            exit 64
            ;;
    esac
    _vibe_resolve || exit 1
    printf '%s\n' "${!2}"
else
    _vibe_resolve || return 1
fi
