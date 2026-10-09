# Generate/archive/export mechanics for release.sh and release-appstore.sh —
# sourced, never run. Callers own the export method and ExportOptions.plist.
# Assumes `set -euo pipefail`, cwd at the repo root, asc-auth-lib.sh sourced,
# and BUILD_DIR, ARCHIVE, EXPORT_DIR, PRODUCT and SCHEME set.

# shellcheck shell=bash

asc_require_xcodegen() {
    command -v xcodegen >/dev/null 2>&1 || {
        echo "error: xcodegen not found — install with: brew install xcodegen" >&2; exit 1; }
}

# Before the archive: an untranslated key found after archive and notarize
# costs the whole cycle.
asc_require_translations() {
    "$(dirname "${BASH_SOURCE[0]}")/check-translations.sh"
}

# Archive $ASC_CONFIGURATION (default Release, the direct download; the Mac
# App Store path sets AppStore) into $ARCHIVE.
#   $1   progress label
#   ...  xcodebuild arguments placed before `archive` (callers pin ARCHS and
#        the destination, so neither follows the host)
#
# No signing overrides: the archive keeps project.yml's automatic signing and
# the export re-signs for distribution, as Xcode's Archive -> Distribute App
# does. Pinning "Developer ID Application" or "Apple Distribution" here fails
# the archive with "conflicting provisioning settings".
asc_archive() {
    local label="$1"
    shift

    echo "🔊 archive ($label)"
    xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$SCHEME" \
        -configuration "${ASC_CONFIGURATION:-Release}" \
        -archivePath "$ARCHIVE" "${ASC_XCODEBUILD_AUTH[@]}" "$@" \
        archive
}

# Wipe $BUILD_DIR, regenerate the project, then asc_archive "$@".
asc_generate_and_archive() {
    rm -rf "$BUILD_DIR"

    echo "🔊 xcodegen generate"
    xcodegen generate

    asc_archive "${ASC_CONFIGURATION:-Release}" "$@"
}

# Fail unless the macOS app carries no updater: no Sparkle file, no link to
# it, no SU* Info.plist key, and none of the direct download's entitlements.
# App Review rejects a Mac App Store app that updates itself (guideline
# 2.4.5), and a linked but unused framework is enough.
asc_require_no_updater() {
    local app="$1"
    local found
    local entitlements

    found="$(find "$app" -iname '*sparkle*')"
    [[ -z "$found" ]] || {
        echo "error: $app carries Sparkle, beginning with:" >&2
        head -3 <<<"$found" >&2
        exit 1
    }
    found="$(otool -L "$app/Contents/MacOS/$PRODUCT")"
    if grep -qi sparkle <<<"$found"; then
        echo "error: $app links Sparkle" >&2
        exit 1
    fi
    found="$(plutil -convert xml1 -o - "$app/Contents/Info.plist")"
    if grep -q '<key>SU' <<<"$found"; then
        echo "error: $app's Info.plist carries Sparkle keys" >&2
        exit 1
    fi
    entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
    if grep -q 'network.client\|temporary-exception' <<<"$entitlements"; then
        echo "error: $app is signed with the direct download's entitlements" >&2
        exit 1
    fi
    echo "🔊 no updater  : $app"
}

# Require exactly the given architecture set. Not `lipo -verify_arch`, which
# accepts extra slices, so an arm64-only build carrying x86_64 would pass.
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

# Export $ARCHIVE into $EXPORT_DIR with the caller's
# $BUILD_DIR/ExportOptions.plist. The log is teed for asc_explain_export_failure.
#   $1  progress label
#   $2  "developer-id", or "" for the App Store path
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
