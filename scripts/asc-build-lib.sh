# Shared generate/archive/export scaffolding for the two release pipelines —
# sourced, never run:
#
#   release.sh            Developer ID + notarize (direct download)
#   release-appstore.sh   Apple Distribution + upload (Mac App Store)
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

# Wipe $BUILD_DIR, regenerate the project and archive Release into $ARCHIVE.
#
# No signing overrides on the archive, deliberately. It keeps project.yml's
# CODE_SIGN_IDENTITY "-" (sign to run locally); distribution signing happens at
# the export step, which re-signs the app outright. This mirrors Xcode's own
# Archive -> Distribute App flow. Pinning a distribution identity here instead
# ("Developer ID Application" / "Apple Distribution") fails the archive with
# "conflicting provisioning settings" — under automatic signing the identity is
# Xcode's to choose.
asc_generate_and_archive() {
    rm -rf "$BUILD_DIR"

    echo "🔊 xcodegen generate"
    xcodegen generate

    echo "🔊 archive (Release)"
    xcodebuild -project "$PRODUCT.xcodeproj" -scheme "$SCHEME" -configuration Release \
        -archivePath "$ARCHIVE" "${ASC_XCODEBUILD_AUTH[@]}" \
        archive
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
