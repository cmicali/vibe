---
name: vibe-release
description: Build, sign, notarize, and ship Vibe — the Developer ID (make release) and App Store (make appstore) paths, the shared App Store Connect API key and its Admin-role requirement, and the signing traps each script preflights. Use when cutting a release, distributing a build, or debugging a signing/notarization/upload failure.
---

# Releasing Vibe

`make release`, or `scripts/release.sh`, builds Release, then signs it with Developer ID, notarizes it and staples a distributable app.

There are two release paths and they are not interchangeable. Each uses a different certificate, a different container and a different verification:

| | `make release` | `make appstore` / `make appstore-upload` |
|---|---|---|
| script | `scripts/release.sh` | `scripts/release-appstore.sh` |
| certificate | Developer ID Application | Apple Distribution (+ Mac Installer) |
| output | stapled `.zip` you host yourself | `.pkg` uploaded to App Store Connect |
| verification | notarize + staple + `spctl` | App Store Connect validation |

## The shared API key

Both scripts share one App Store Connect API key, `ASC_KEY_ID` and `ASC_ISSUER_ID`, read from a gitignored `.release-env` at the repo root. Resolution lives in `scripts/asc-auth-lib.sh`, which both scripts source. That single key covers cloud signing, notarization — `notarytool --key/--key-id/--issuer`, so no app-specific password and no `store-credentials` profile — and upload.

The key must carry the **Admin** role. Cloud-managed *App Store* certificates are Admin-gated, so an App Manager key authenticates and uploads fine but fails the export with a 403. A key's role cannot be edited after creation.

## Three signing traps

Each was learned the hard way, and each is now guarded by a preflight or an error explainer.

- **Neither archive passes signing overrides.** Both keep `CODE_SIGN_IDENTITY: "-"` and let the export re-sign, mirroring Xcode's Archive → Distribute App flow. Pinning `CODE_SIGN_IDENTITY` under automatic signing fails the archive outright with "conflicting provisioning settings".
- **The Developer ID certificate cannot be automated.** Apple gates `DEVELOPER_ID_APPLICATION_MANAGED` to the team's *Account Holder*, a person role no API key can hold, so `-allowProvisioningUpdates` gets a 403 even with an Admin key that signs App Store builds fine. Create it once in Xcode → Settings → Accounts → Manage Certificates, where the cap is five per account. `release.sh` preflights for it, so this fails instantly rather than after a full archive.
- **xcodebuild hides the reason.** A cloud-signing denial surfaces only as "Cloud signing permission error", with Apple's real 403 buried in a temporary `.xcdistributionlogs` bundle. `asc_explain_export_failure` reprints it, with different guidance per certificate type.

`make appstore` stops after validation; only `make appstore-upload` submits. Both signing identities are applied on the xcodebuild command line, because `project.yml` deliberately keeps `CODE_SIGN_IDENTITY: "-"` so that everyday builds need no credentials at all.
