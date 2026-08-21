#!/usr/bin/env bash
#
# Wipe Vibe's persisted state so the next launch is a first launch: settings,
# the sandbox folder grants, the metadata and waveform disk caches, saved
# window state, lifetime stats, the last playlist.
#
# macOS: everything lives inside the app sandbox container, because the app is
# sandboxed in every configuration (project.yml sets ENABLE_APP_SANDBOX: YES on
# the target, not per-config). Removing the container is therefore the whole
# reset; the non-container paths below are only swept in case an older or
# unsandboxed build left something behind.
#
# TRAP: cfprefsd holds the preference domain in memory and rewrites the plist
# on its own schedule, so deleting the container while the app — or cfprefsd's
# cache of it — is live silently resurrects every setting. The app is quit
# first and cfprefsd is restarted after the delete, in that order.
#
# iOS: the simulator app container is the whole state, and `simctl uninstall`
# is the supported way to drop it. launch-ios.sh reinstalls on its next run.
#
# Usage: reset-state.sh [--mac] [--ios] [--both] [-n|--dry-run] [-y|--yes]
#   --mac       the macOS container (default)
#   --ios       this checkout's simulator (sim-udid.sh; VIBE_SIM_UDID pins one)
#   --both      both
#   -n          list what would be removed and exit
#   -y          skip the confirmation prompt (required when stdin is not a tty)
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="com.commonwealthrecordings.Vibe"
SIM_UDID_SCRIPT=".claude/skills/vibe-debug/scripts/sim-udid.sh"

DO_MAC=0
DO_IOS=0
DRY_RUN=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac)           DO_MAC=1 ;;
        --ios)           DO_IOS=1 ;;
        --both|--all)    DO_MAC=1; DO_IOS=1 ;;
        -n|--dry-run)    DRY_RUN=1 ;;
        -y|--yes)        ASSUME_YES=1 ;;
        -h|--help)       sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               echo "reset-state: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
[[ $DO_MAC -eq 1 || $DO_IOS -eq 1 ]] || DO_MAC=1

# Every place a macOS build could have written. Only the container is expected
# to exist; the rest are swept so a pre-sandbox or test-harness leftover cannot
# survive a "reset to defaults".
MAC_PATHS=(
    "$HOME/Library/Containers/$BUNDLE_ID"
    "$HOME/Library/Application Scripts/$BUNDLE_ID"
    "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    "$HOME/Library/Caches/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"
    "$HOME/Library/WebKit/$BUNDLE_ID"
)

present_mac_paths() {
    local path
    # ByHost prefs are per-machine-UUID, so they can only be found by glob;
    # nullglob keeps an unmatched pattern from reaching the -e test as itself.
    shopt -s nullglob
    for path in "${MAC_PATHS[@]}" "$HOME/Library/Preferences/ByHost/$BUNDLE_ID."*.plist; do
        [[ -e "$path" ]] && printf '%s\n' "$path"
    done
    shopt -u nullglob
    return 0
}

# The simulator this checkout's debug tooling uses. Never `booted`: a wipe must
# name its device.
sim_udid() {
    if [[ -n "${VIBE_SIM_UDID:-}" && "$VIBE_SIM_UDID" != "booted" ]]; then
        printf '%s\n' "$VIBE_SIM_UDID"
        return 0
    fi
    [[ -x "$SIM_UDID_SCRIPT" ]] || { echo "reset-state: no $SIM_UDID_SCRIPT" >&2; return 1; }
    VIBE_SIM_UDID="" "$SIM_UDID_SCRIPT"
}

# --- plan -------------------------------------------------------------------

PLAN=()
if [[ $DO_MAC -eq 1 ]]; then
    while IFS= read -r path; do
        size="$(du -sh "$path" 2>/dev/null | cut -f1)" || size="?"
        PLAN+=("macOS  ${size:-?}  $path")
    done < <(present_mac_paths)
fi

UDID=""
if [[ $DO_IOS -eq 1 ]]; then
    # No device means no state: a reset with nothing to reset is not a failure.
    if ! UDID="$(sim_udid)"; then
        DO_IOS=0
    elif xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app >/dev/null 2>&1; then
        PLAN+=("iOS    app+data  $BUNDLE_ID on $UDID")
    else
        # get_app_container also fails on a shut-down device, so this is not
        # proof the app is absent — run the uninstall either way.
        PLAN+=("iOS    app+data  $BUNDLE_ID on $UDID (not installed, or device shut down)")
    fi
fi

if [[ ${#PLAN[@]} -eq 0 ]]; then
    echo "🔊 nothing to reset — no Vibe state found"
    exit 0
fi

echo "Will remove:"
printf '  %s\n' "${PLAN[@]}"
[[ $DRY_RUN -eq 1 ]] && exit 0

if [[ $ASSUME_YES -ne 1 ]]; then
    [[ -t 0 ]] || { echo "reset-state: not a tty — pass -y to confirm" >&2; exit 1; }
    read -r -p "Reset Vibe to defaults? [y/N] " reply
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || { echo "aborted"; exit 1; }
fi

# --- macOS ------------------------------------------------------------------

if [[ $DO_MAC -eq 1 ]]; then
    if pgrep -x Vibe >/dev/null; then
        echo "quitting Vibe"
        osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            pgrep -x Vibe >/dev/null || break
            sleep 0.25
        done
        if pgrep -x Vibe >/dev/null; then
            pkill -x Vibe || true
            sleep 0.5
        fi
    fi

    while IFS= read -r path; do
        rm -rf "$path"
        echo "🔊 removed $path"
    done < <(present_mac_paths)

    # Drop cfprefsd's in-memory copy of the domain so it cannot write the old
    # settings back out. It is relaunched on demand.
    killall -u "$USER" cfprefsd 2>/dev/null || true
fi

# --- iOS --------------------------------------------------------------------

if [[ $DO_IOS -eq 1 ]]; then
    # simctl refuses most container operations on a shut-down device, so a
    # first failure earns one boot and a retry rather than a silent no-op.
    if ! xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null; then
        xcrun simctl bootstatus "$UDID" -b >/dev/null
        xcrun simctl uninstall "$UDID" "$BUNDLE_ID"
    fi
    echo "🔊 uninstalled $BUNDLE_ID from $UDID (launch-ios.sh reinstalls)"
fi

echo "🔊 Vibe reset to defaults"
