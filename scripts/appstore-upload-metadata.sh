#!/bin/bash
# Upload the localized App Store product page (copy and screenshots from
# Assets/app-store/) to the one editable version of one platform, through
# scripts/asc-upload. No build is involved.
#
#   scripts/appstore-upload-metadata.sh [--platform macos|ios] [--dry-run]
#       [--locales de,fr] [--skip-screenshots] [--skip-text]
#       [--create-version <version>]
#
# Uses the release scripts' API key (asc-auth-lib.sh); editing metadata needs
# App Manager or above, which its Admin role covers.
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
