# Shared App Store Connect credential resolution — sourced, never run:
#
#   release.sh            Developer ID + notarize (direct download)
#   release-appstore.sh   Apple Distribution + upload (Mac App Store)
#
# ONE App Store Connect API key covers both pipelines. It authenticates three
# separate things, which is why neither script wants a second credential:
#   * cloud signing      xcodebuild -allowProvisioningUpdates creates and uses
#                        the distribution certificates and profiles
#   * notarization       notarytool --key/--key-id/--issuer (no app-specific
#                        password, no `notarytool store-credentials` profile)
#   * upload             altool --api-key/--api-issuer
#
# The key must carry the ADMIN role. Cloud-managed distribution certificates
# are Admin-gated: an App Manager key authenticates fine and can upload, but
# signing dies with 403 FORBIDDEN_ERROR / "You haven't been given access to
# cloud-managed distribution certificates". A key's role cannot be edited after
# creation — generate a new key instead.
#
# Callers own policy (which certificate, which destination); this file owns
# only credential discovery. Assumes `set -euo pipefail` in the caller.

# shellcheck shell=bash

# Resolves ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH, and exports the
# xcodebuild provisioning flags as the array ASC_XCODEBUILD_AUTH.
# Reads a gitignored .release-env at the repo root if present, so a normal run
# needs no environment fiddling. Exits with guidance if anything is missing.
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
    # notarytool and altool both reject a relative path once the cwd moves.
    ASC_KEY_PATH="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"

    ASC_XCODEBUILD_AUTH=(
        -allowProvisioningUpdates
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
}

# Explains xcodebuild's uselessly terse "Cloud signing permission error", which
# hides Apple's real 403 in a temp .xcdistributionlogs bundle. Pass the export
# log and the export method; prints nothing if that is not what went wrong.
#
# The same 403 means two different things depending on the certificate type:
# App Store certificates are Admin-gated (fixable by upgrading the key), while
# Developer ID certificates are Account-Holder-gated and NO api key can reach
# them — that one is only fixable in Xcode's GUI.
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
