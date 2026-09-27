# App Store Connect credential resolution for release.sh, release-appstore.sh
# and appstore-upload-metadata.sh — sourced, never run. Assumes
# `set -euo pipefail`.
#
# One API key covers cloud signing (xcodebuild -allowProvisioningUpdates),
# notarization (notarytool --key, so no app-specific password) and upload
# (altool --api-key --p8-file-path). Every consumer passes ASC_KEY_PATH itself:
# altool's own search only finds AuthKey_<id>.p8 in fixed directories. It must
# carry the ADMIN role: cloud-managed distribution certificates are
# Admin-gated, so an App Manager key uploads but signing dies with 403
# FORBIDDEN_ERROR. A key's role cannot be edited; make a new key.

# shellcheck shell=bash

# Sets ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH and the xcodebuild flag array
# ASC_XCODEBUILD_AUTH, sourcing the repo root's gitignored .release-env if
# present. Exits with guidance when anything is missing.
asc_resolve_credentials() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # shellcheck disable=SC1091
    [[ -f "$root/.release-env" ]] && source "$root/.release-env"

    if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
        cat >&2 <<'MSG'
error: App Store Connect API credentials not configured.

  Create a key at App Store Connect -> Users and Access -> Integrations ->
  App Store Connect API -> Team Keys -> (+), with the ADMIN role (App Manager
  is not enough — distribution certificates are Admin-gated).
  Download AuthKey_<KEYID>.p8 (offered exactly once) to
  ~/.appstoreconnect/private_keys/, then write a .release-env in the repo root:

      ASC_KEY_ID=XXXXXXXXXX
      ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  (.release-env is gitignored — it is a pointer to the key, not the key.)
MSG
        exit 1
    fi

    ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
    if [[ ! -f "$ASC_KEY_PATH" ]]; then
        echo "error: API private key not found at: $ASC_KEY_PATH" >&2
        echo "       Put AuthKey_${ASC_KEY_ID}.p8 there, or set ASC_KEY_PATH." >&2
        exit 1
    fi
    # Absolute, so the path survives a later cd.
    ASC_KEY_PATH="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"

    ASC_XCODEBUILD_AUTH=(
        -allowProvisioningUpdates
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
}

# Explains xcodebuild's bare "Cloud signing permission error" (Apple's real 403
# sits in a temp .xcdistributionlogs bundle). $1 the export log, $2 the export
# method; prints nothing for any other failure. The 403 means two things: App
# Store certificates are Admin-gated (make an Admin key), Developer ID ones are
# Account-Holder-gated (no API key can reach them; Xcode's GUI only).
asc_explain_export_failure() {
    grep -q "Cloud signing permission error" "$1" 2>/dev/null || return 0

    if [[ "${2:-}" == "developer-id" ]]; then
        cat >&2 <<'MSG'

error: cloud signing cannot create a Developer ID certificate. Apple gates
       DEVELOPER_ID_APPLICATION_MANAGED to the team's Account Holder, which is
       a person role — no App Store Connect API key can hold it, not even an
       Admin key that signs App Store builds fine.

       Create the certificate once, by hand, as the Account Holder:
         Xcode -> Settings -> Accounts -> (sign in) -> select the team ->
         Manage Certificates -> (+) -> Developer ID Application
       Apple caps these at 5 per account, so keep the one you make.

       Then re-run: this script picks up any Developer ID Application identity
       in the keychain automatically, or set DEVELOPER_ID to name one.
MSG
        return 0
    fi

    cat >&2 <<'MSG'

error: the App Store Connect API key lacks permission for cloud-managed
       distribution certificates. Apple's underlying response is:

         403 FORBIDDEN_ERROR — "You haven't been given access to cloud-managed
         distribution certificates."

       The key needs the ADMIN role. A key's role cannot be changed after it
       is created, so generate a new one (Users and Access -> Integrations ->
       App Store Connect API -> Team Keys -> (+) -> Access: Admin), download
       its .p8 to ~/.appstoreconnect/private_keys/, and point ASC_KEY_ID in
       .release-env at the new key id.
MSG
}
