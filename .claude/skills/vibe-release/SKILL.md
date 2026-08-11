---
name: vibe-release
description: Build, sign, notarize, and ship Vibe — the Developer ID (make release) and App Store (make appstore-build) paths, the GitHub release publish (make github-release), the localized product-page metadata upload (make appstore-upload-metadata), the shared App Store Connect API key and its Admin-role requirement, and the signing traps each script preflights. Use when cutting a release, distributing a build, updating App Store copy or screenshots, or debugging a signing/notarization/upload failure.
---

# Releasing Vibe

`make release`, or `scripts/release.sh`, builds Release, then signs it with Developer ID, notarizes it and staples a distributable app. `make github-release` (`scripts/github-release.sh`, `--draft` for a review pass) then publishes that artifact as a GitHub release: it re-verifies the staple on the zip's contents, tags HEAD as `v<MARKETING_VERSION>` (read from the built app, never from git), attaches `vibe-macos-<arch>-<version>.zip` (arch read from the binary via `lipo`), and takes the release notes from the same `Assets/app-store/copy/en/whats-new.txt` the App Store upload requires — publishing needs `gh` authenticated (`gh auth login`; `brew bundle` installs it) and a pushed HEAD, and it refuses an existing release for the same version.

There are two release paths and they are not interchangeable. Each uses a different certificate, a different container and a different verification:

| | `make release` | `make appstore-build` / `make appstore-upload-signed-build` |
|---|---|---|
| script | `scripts/release.sh` | `scripts/release-appstore.sh` |
| certificate | Developer ID Application | Apple Distribution (+ Mac Installer) |
| output | stapled `.zip` you host yourself | `.pkg` uploaded to App Store Connect |
| verification | notarize + staple + `spctl` | App Store Connect validation |

## Product-page metadata

The build upload carries no product-page content. Localized copy and screenshots live in `Assets/app-store/` (per-locale format: its README) and upload separately with `make appstore-upload-metadata` — `scripts/appstore-upload-metadata.sh` driving the Swift/Bagbutik tool in `scripts/asc-upload/`, authenticated by the same shared key (metadata itself needs only App Manager, so the Admin key more than covers it).

The loop:

1. Edit `Assets/app-store/copy/<lang>/` — every catalog language, not just `en`; nothing auto-translates. **`whats-new.txt` must be rewritten for every release** — ASC blocks submission when any locale lacks release notes, and stale notes upload silently. The shared `copy/support-url.txt` and `copy/marketing-url.txt` upload to every locale too.
2. `make appstore-validate-copy` — ASC character limits, markdown that would upload verbatim, captions that overflow the screenshot layout. (`appstore-upload-metadata` runs this first anyway.)
3. `make appstore-generate-store-screenshots-all` — only if `screenshots.json` captions or the window captures changed.
4. `make appstore-upload-metadata ARGS="--dry-run"`, then without.

Flags via `ARGS`: `--locales de,fr`, `--skip-screenshots`, `--skip-text`, `--create-version <v>`.

Traps and semantics:

- **It targets the one *editable* macOS version.** After a release goes live there is none — the tool errors, listing every version's state. `--create-version <next>` opens the next version's page (the same version record a later `make appstore-upload-signed-build` build attaches to, so metadata-first is the normal order).
- **Text is diffed, screenshots are not.** Unchanged text fields are skipped; each locale's `APP_DESKTOP` screenshot set is deleted and re-uploaded wholesale, ordered by file name. Don't read "uploaded 4 screenshots" as "they changed".
- **`bg` is skipped by design** — the App Store has no Bulgarian product page; the translation ships in-app only. Catalog `nb` maps to ASC `no`. A new catalog language fails loudly until added to `ascLocale` in `ASCUpload.swift`.
- **Out of scope, on purpose:** app name and subtitle (`appInfoLocalizations`, rarely change — edit in ASC by hand).
- `description.txt` uploads *verbatim* — plain text only; `appstore-validate-copy` rejects leftover markdown markers.

## The shared API key

Both scripts share one App Store Connect API key, `ASC_KEY_ID` and `ASC_ISSUER_ID`, read from a gitignored `.release-env` at the repo root. Resolution lives in `scripts/asc-auth-lib.sh`, which both scripts source. That single key covers cloud signing, notarization — `notarytool --key/--key-id/--issuer`, so no app-specific password and no `store-credentials` profile — and upload.

The key must carry the **Admin** role. Cloud-managed *App Store* certificates are Admin-gated, so an App Manager key authenticates and uploads fine but fails the export with a 403. A key's role cannot be edited after creation.

## Three signing traps

Each was learned the hard way, and each is now guarded by a preflight or an error explainer.

- **Neither archive passes signing overrides.** Both keep `CODE_SIGN_IDENTITY: "-"` and let the export re-sign, mirroring Xcode's Archive → Distribute App flow. Pinning `CODE_SIGN_IDENTITY` under automatic signing fails the archive outright with "conflicting provisioning settings".
- **The Developer ID certificate cannot be automated.** Apple gates `DEVELOPER_ID_APPLICATION_MANAGED` to the team's *Account Holder*, a person role no API key can hold, so `-allowProvisioningUpdates` gets a 403 even with an Admin key that signs App Store builds fine. Create it once in Xcode → Settings → Accounts → Manage Certificates, where the cap is five per account. `release.sh` preflights for it, so this fails instantly rather than after a full archive.
- **xcodebuild hides the reason.** A cloud-signing denial surfaces only as "Cloud signing permission error", with Apple's real 403 buried in a temporary `.xcdistributionlogs` bundle. `asc_explain_export_failure` reprints it, with different guidance per certificate type.

`make appstore-build` stops after validation; only `make appstore-upload-signed-build` submits. Both signing identities are applied on the xcodebuild command line, because `project.yml` deliberately keeps `CODE_SIGN_IDENTITY: "-"` so that everyday builds need no credentials at all.
