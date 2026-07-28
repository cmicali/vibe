---
name: vibe-release
description: Build, sign, notarize, and ship Vibe — the Developer ID (make release) and App Store (make appstore) paths, the shared App Store Connect API key and its Admin-role requirement, and the signing traps each script preflights. Use when cutting a release, distributing a build, or debugging a signing/notarization/upload failure.
---

# Releasing Vibe

`make release` (or `scripts/release.sh`) builds Release then signs with Developer ID, notarizes, and staples a distributable app.

There are two distinct release paths and they are not interchangeable — different certificate, different container, different verification:

| | `make release` | `make appstore` / `make appstore-upload` |
|---|---|---|
| script | `scripts/release.sh` | `scripts/release-appstore.sh` |
| certificate | Developer ID Application | Apple Distribution (+ Mac Installer) |
| output | stapled `.zip` you host yourself | `.pkg` uploaded to App Store Connect |
| verification | notarize + staple + `spctl` | App Store Connect validation |

Both scripts share one App Store Connect API key (`ASC_KEY_ID` / `ASC_ISSUER_ID`, read from a gitignored `.release-env` at the repo root; resolution lives in `scripts/asc-auth-lib.sh`, sourced by both). That single key covers cloud signing, notarization (`notarytool --key/--key-id/--issuer` — no app-specific password or `store-credentials` profile) and upload. It must carry the **Admin** role: cloud-managed *App Store* certificates are Admin-gated, and an App Manager key authenticates and uploads fine but fails the export with a 403. A key's role can't be edited after creation.

Three signing facts, each learned the hard way and each guarded by a preflight or an error explainer:

- **Neither archive passes signing overrides.** Both keep `CODE_SIGN_IDENTITY: "-"` and let the export re-sign, mirroring Xcode's Archive → Distribute App flow. Pinning `CODE_SIGN_IDENTITY` under automatic signing fails the archive outright with "conflicting provisioning settings".
- **The Developer ID certificate cannot be automated.** Apple gates `DEVELOPER_ID_APPLICATION_MANAGED` to the team's *Account Holder* — a person role no API key can hold — so `-allowProvisioningUpdates` gets a 403 even with an Admin key that signs App Store builds fine. It has to be made once in Xcode → Settings → Accounts → Manage Certificates (capped at 5 per account). `release.sh` preflights for it so this fails instantly rather than after a full archive.
- **xcodebuild hides the reason.** Cloud-signing denials surface only as "Cloud signing permission error", with Apple's real 403 buried in a temp `.xcdistributionlogs` bundle; `asc_explain_export_failure` reprints it, with different guidance per certificate type. `make appstore` stops after validation; only `make appstore-upload` submits. Both signing identities are applied on the xcodebuild command line — `project.yml` deliberately keeps `CODE_SIGN_IDENTITY: "-"` so everyday builds need no credentials at all.
