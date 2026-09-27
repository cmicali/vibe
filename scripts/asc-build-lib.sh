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

# Archive Release into $ARCHIVE.
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
    xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$SCHEME" -configuration Release \
        -archivePath "$ARCHIVE" "${ASC_XCODEBUILD_AUTH[@]}" "$@" \
        archive
}

# Wipe $BUILD_DIR, regenerate the project, then asc_archive "Release" "$@".
asc_generate_and_archive() {
    rm -rf "$BUILD_DIR"

    echo "🔊 xcodegen generate"
    xcodegen generate

    asc_archive "Release" "$@"
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
