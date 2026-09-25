# Shared generate/archive/export scaffolding for the two release pipelines —
# sourced, never run:
#
#   release.sh            Developer ID + notarize (direct download)
#   release-appstore.sh   Apple Distribution + upload (App Store, either platform)
#
# Callers own policy — the export method, the ExportOptions.plist contents and
# what happens to the exported product; this file owns the mechanics that are
# identical between `xcodegen generate` and the exported archive. Assumes
# `set -euo pipefail` in the caller, cwd at the repo root, asc-auth-lib.sh
# already sourced (for ASC_XCODEBUILD_AUTH and asc_explain_export_failure), and
# BUILD_DIR / ARCHIVE / EXPORT_DIR / PRODUCT / SCHEME set.

# shellcheck shell=bash

asc_require_xcodegen() {
    command -v xcodegen >/dev/null 2>&1 || {
        echo "error: xcodegen not found — install with: brew install xcodegen" >&2; exit 1; }
}

# Both release paths ship the same in-app catalog, so both gate on it. Runs
# before the archive: an untranslated key is a content problem, and finding it
# after a full archive+notarize costs the whole cycle.
asc_require_translations() {
    "$(dirname "${BASH_SOURCE[0]}")/check-translations.sh"
}

# Archive Release into $ARCHIVE. The optional arguments are spliced into the
# xcodebuild command line ahead of the `archive` action, so they may be build
# setting overrides or flags; release callers use them to pin the architecture
# set rather than inheriting whichever host runs them, and to pin the
# destination rather than letting a single-platform scheme resolve a simulator.
# Keeping this command here means every archive retains the same signing rule
# below, including a second architecture-specific archive in one release run.
#
#   $1  progress label
#   ... optional xcodebuild arguments (build-setting overrides or flags)
#
# No signing overrides on the archive, deliberately. It keeps project.yml's
# CODE_SIGN_IDENTITY "-" (sign to run locally); distribution signing happens at
# the export step, which re-signs the app outright. This mirrors Xcode's own
# Archive -> Distribute App flow. Pinning a distribution identity here instead
# ("Developer ID Application" / "Apple Distribution") fails the archive with
# "conflicting provisioning settings" — under automatic signing the identity is
# Xcode's to choose.
asc_archive() {
    local label="$1"
    shift

    echo "🔊 archive ($label)"
    xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$SCHEME" -configuration Release \
        -archivePath "$ARCHIVE" "${ASC_XCODEBUILD_AUTH[@]}" "$@" \
        archive
}

# Wipe $BUILD_DIR, regenerate the project and archive Release into $ARCHIVE.
# Optional arguments pass through to asc_archive.
asc_generate_and_archive() {
    rm -rf "$BUILD_DIR"

    echo "🔊 xcodegen generate"
    xcodegen generate

    asc_archive "Release" "$@"
}

# Require the executable to contain exactly the requested architecture set.
# `lipo -verify_arch` is insufficient here because it accepts extra slices: an
# arm64-only artifact carrying x86_64 would pass. Comparing sorted sets also
# makes the check independent of lipo's display order.
asc_require_binary_architectures() {
    local binary="$1"
    shift
    local requested="$*"
    local actual
    local requested_sorted
    local actual_sorted

    [[ -f "$binary" ]] || {
        echo "error: no executable at $binary" >&2
        exit 1
    }
    actual="$(lipo -archs "$binary")" || {
        echo "error: could not read architectures from $binary" >&2
        exit 1
    }
    requested_sorted="$(printf '%s\n' "$@" | LC_ALL=C sort)"
    # Word splitting is intentional: lipo prints one space-separated arch set.
    # shellcheck disable=SC2086
    actual_sorted="$(printf '%s\n' $actual | LC_ALL=C sort)"
    [[ "$actual_sorted" == "$requested_sorted" ]] || {
        echo "error: $binary has architectures '$actual'; expected exactly '$requested'" >&2
        exit 1
    }
}

# The exported mac app's widget pieces, which fail silently when wrong: the
# extension present and sandboxed (WidgetKit will not load it otherwise); it
# and the app both holding the team-prefixed app group (VibeWidgetState.m's
# TRAP), or the widget draws empty; the app's WidgetKit bridge bundle
# (VibeWidgetReloader.swift), or the widget is never told to redraw; and the
# app itself linking neither WidgetKit nor SwiftUI (System/CLAUDE.md's TRAP),
# or every launch pays for them. Further arguments are the slices both nested
# binaries must carry.
asc_require_mac_widget() {
    local app="$1"
    shift
    local appex="$app/Contents/PlugIns/VibeWidget.appex"
    local center="$app/Contents/PlugIns/VibeWidgetCenter.bundle"
    local group="$TEAM_ID.com.commonwealthrecordings.Vibe"
    local bundle

    [[ -d "$appex" ]] || {
        echo "error: $appex is missing — the widget did not embed" >&2
        exit 1
    }
    [[ -d "$center" ]] || {
        echo "error: $center is missing — the app could not reach WidgetKit" >&2
        exit 1
    }
    grep -q 'com.apple.security.app-sandbox' \
            <<<"$(codesign -d --entitlements - --xml "$appex" 2>/dev/null)" || {
        echo "error: $appex is not sandboxed — WidgetKit will not load it" >&2
        exit 1
    }
    for bundle in "$app" "$appex"; do
        grep -q "$group" <<<"$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null)" || {
            echo "error: $bundle lacks the app group $group — the widget would draw empty" >&2
            exit 1
        }
    done
    if otool -L "$app/Contents/MacOS/$(basename "$app" .app)" \
            | grep -qE '/(WidgetKit|SwiftUI)\.framework/'; then
        echo "error: $app links WidgetKit or SwiftUI — every launch would load them" >&2
        exit 1
    fi
    if (($#)); then
        asc_require_binary_architectures "$appex/Contents/MacOS/VibeWidget" "$@"
        asc_require_binary_architectures "$center/Contents/MacOS/VibeWidgetCenter" "$@"
    fi
}

# Export $ARCHIVE into $EXPORT_DIR using $BUILD_DIR/ExportOptions.plist, which
# the caller writes first — the plist is where the two pipelines differ.
#   $1  label for the progress line ("Developer ID", "App Store package")
#   $2  method hint for asc_explain_export_failure ("developer-id", or "" for
#       the App Store path)
#
# xcodebuild reports cloud-signing failures as a bare "Cloud signing permission
# error" and buries Apple's actual 403 in a temp .xcdistributionlogs bundle, so
# the log is teed and asc_explain_export_failure surfaces the real reason
# rather than making the next person go digging.
asc_export_archive() {
    echo "🔊 export ($1)"
    if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" \
            -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
            -exportPath "$EXPORT_DIR" "${ASC_XCODEBUILD_AUTH[@]}" \
            2>&1 | tee "$BUILD_DIR/export.log"; then
        asc_explain_export_failure "$BUILD_DIR/export.log" "${2:-}"
        exit 1
    fi
}
