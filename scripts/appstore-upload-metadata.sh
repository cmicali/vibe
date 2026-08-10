#!/bin/bash
# Upload the localized App Store product-page metadata — promotional text,
# description, keywords, and screenshots from Assets/app-store/ — to App Store
# Connect, via the Swift tool in scripts/asc-upload (Bagbutik). No build is
# involved; this edits the one editable macOS version's product page.
#
#   scripts/appstore-upload-metadata.sh [--dry-run] [--locales de,fr]
#                                        [--skip-screenshots] [--skip-text]
#
# Uses the same App Store Connect API key as the release scripts (.release-env,
# resolved by asc-auth-lib.sh). Metadata editing needs App Manager or above;
# the shared key is Admin, so it covers this too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=asc-auth-lib.sh
source "$ROOT/scripts/asc-auth-lib.sh"
asc_resolve_credentials

exec swift run -c release --package-path "$ROOT/scripts/asc-upload" asc-upload \
    --key-id "$ASC_KEY_ID" \
    --issuer-id "$ASC_ISSUER_ID" \
    --key-path "$ASC_KEY_PATH" \
    --bundle-id com.commonwealthrecordings.Vibe \
    --root "$ROOT/Assets/app-store" \
    "$@"
