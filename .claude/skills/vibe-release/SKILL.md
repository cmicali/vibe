---
name: vibe-release
description: Build, sign, notarize, and ship Vibe — the Developer ID (make release) and App Store (make appstore-build) paths, the GitHub release publish (make github-release), the localized product-page metadata upload (make appstore-upload-metadata), the shared App Store Connect API key and its Admin-role requirement, and the signing traps each script preflights. Use when cutting a release, distributing a build, updating App Store copy or screenshots, or debugging a signing/notarization/upload failure.
---

# Releasing Vibe

`make release`, or `scripts/release.sh`, builds Release, signs it with Developer ID, notarizes and staples the app, then packages it as `build/release/Vibe.dmg` — a plain drag-to-`Applications` window, signed, notarized and stapled in its own right. `make github-release` (`scripts/github-release.sh`, `--draft` for a review pass) then publishes that image as a GitHub release: it mounts the image and re-verifies **every** staple — the image, the app inside it, and the app inside the zip — tags HEAD as `v<MARKETING_VERSION>` (read from the app inside the image, never from git), attaches **both** `Vibe-macOS-<version>.dmg` and `Vibe-macOS-<arch>-<version>.zip` (the arch read from the binary via `lipo`; only the zip carries it, since the bare bundle is the one whose machines need naming), and takes the release notes from the same `Assets/app-store/copy/en/whats-new.txt` the App Store upload requires — publishing needs `gh` authenticated (`gh auth login`; `brew bundle` installs it) and a pushed HEAD, and it refuses an existing release for the same version.

**Why a disk image and not the zip.** The zip still exists — notarytool needs an archive to submit — but it is not what anyone downloads. A zip expands wherever the browser drops it, and a quarantined app launched from `~/Downloads` runs *translocated*, from a read-only random mount point that vanishes on quit. For this app that is not cosmetic: Settings > Set Vibe as Default Music Player registers with Launch Services from the path it is running at, so a click from a translocated copy registers a path that ceases to exist — and `DefaultAppRegistration` already has to reason about several copies of the app. Dragging out of a disk image is what clears translocation, and the `/Applications` alias is what makes that the obvious gesture. **The window is deliberately plain**: no background image, no icon placement. Those need Finder driven over AppleScript to write a `.DS_Store`, which wants Automation permission and is the flakiest step in any DMG script, and two icons side by side carry the whole point. Two notarization round trips is the price — the app before packaging, the image after — and both staples are checked at publish because either one missing means a download Gatekeeper re-checks online.

There are two release paths and they are not interchangeable. Each uses a different certificate, a different container and a different verification:

| | `make release` | `make appstore-build` / `make appstore-upload-signed-build` |
|---|---|---|
| script | `scripts/release.sh` | `scripts/release-appstore.sh` |
| certificate | Developer ID Application | Apple Distribution (+ Mac Installer) |
| output | stapled `.dmg` you host yourself | `.pkg` uploaded to App Store Connect |
| verification | notarize + staple + `spctl`, app and image both | App Store Connect validation |

Both preflight `asc_require_translations` before the archive: a key missing any catalog language fails the release outright, because nothing else catches it — `make check-strings` compares the catalog to the source and the build compiles a partial key without complaint, so it would ship English in that locale alone. Fix by translating, not by skipping; the **vibe-strings** skill has the conventions. This is separate from the product-page copy below — that's ASC metadata, this is the in-app catalog.

## The marketing page

`Assets/Web/` is a static site with no build step, served from two hosts: Cloudflare Pages at **vibe.commonwealthrecordings.com** (canonical) and GitHub Pages at cmicali.github.io/vibe. Its own `README.md` has the detail.

The page's Download button links a **direct** `.dmg` URL and shows the version beside it, so the two must agree. GitHub's `latest/download` shortcut cannot supply that — it only redirects for an asset name that never changes, and the assets are `Vibe-macOS-<version>.dmg`. So `scripts/web-set-version.sh <version>` rewrites both, keyed on the `dmg-link` and `dmg-version` element ids rather than the markup around them; a pattern that stops matching is an error, never a silent no-op.

**`github-release.sh` runs it before creating the release, not after, and the ordering is the point.** The page update is committed — that one file, by explicit pathspec, so a dirty tree cannot ride along — and pushed, and only then is `gh release create` called with `--target HEAD`. The tag therefore names a tree whose website already advertises that release: checking out `v<version>` gets the page that goes with it. This is the one step that moves `main`, and it happens while everything is still reversible, which is why a failed commit or push here is **fatal** rather than a warning — nothing has been published yet, and a tag on an unpushed commit would dangle. The tag-points-at-HEAD preflight moved down with it, since it is only authoritative once HEAD has stopped moving.

`--draft` skips all of it: a draft's download is not public, and a draft creates no tag until published, so there is no ordering to preserve. Repoint by hand once it goes out (`scripts/web-set-version.sh <version> && make deploy-web`).

`make deploy-web` then carries the same page to Cloudflare. It refuses to upload a page whose Download button does not return 200 — the check that the rewrite and the release happened in that order — and `ARGS="--dry-run"` runs that check and lists the files without credentials.

**It is local-only, and enforced as such.** `deploy-web.sh` exits if `CI`, `GITHUB_ACTIONS`, `GITLAB_CI` or `BUILDKITE` is set. The Cloudflare token stays in the gitignored `.release-env` beside the ASC keys, out of CI secrets, so a later "just add it to a workflow" has to be deliberate. The token needs exactly **Account | Cloudflare Pages | Edit**. GitHub Pages is the copy CI is allowed to publish, precisely because `.github/workflows/pages.yml` needs no credential — it deploys with the workflow's own OIDC token.

So the full sequence, all from a machine with `.release-env`: `make release`, `make github-release`, `make deploy-web`.

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
