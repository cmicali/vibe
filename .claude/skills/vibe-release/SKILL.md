---
name: vibe-release
description: Build, sign, notarize, and ship Vibe on both platforms — the macOS Developer ID (make release) and App Store (make appstore-build) paths, the iOS App Store path (make appstore-build-ios), the GitHub release publish (make github-release), the Homebrew tap bump (make brew-set-version), the localized product-page metadata upload (make appstore-upload-metadata), the shared App Store Connect API key and its Admin-role requirement, and the signing traps each script preflights. Use when cutting a release, distributing a build, shipping or TestFlighting the iOS app, updating App Store copy or screenshots, or debugging a signing/notarization/upload failure.
---

# Releasing Vibe

`make release`, or `scripts/release.sh`, builds two Release archives: universal (`arm64` + `x86_64`) under `build/release/`, and arm64-only under `build/release/arm64/`. Each is independently exported with Developer ID, notarized and stapled, then packaged in its own plain drag-to-`Applications` DMG which is itself signed, notarized and stapled. Architecture is a build input; never thin the signed universal app, because changing its executable invalidates both the signature and notarization. Every archive runs under the hardened runtime, which a local build leaves off (Updates, below). Each final zip is signed for Sparkle into `<zip>.sig`.

`make github-release` (`scripts/github-release.sh`; `ARGS="--draft"` for a review pass, `ARGS="--prerelease"` for a beta) re-verifies every exported app, DMG, mounted app and zipped app, including its exact architecture and matching version/build, then tags HEAD as `v<MARKETING_VERSION>`. It attaches four artifacts: universal `Vibe-macOS-universal-<version>.dmg` and `.zip`, plus arm64-only `Vibe-macOS-arm64-<version>.dmg` and `.zip`. Release notes come from the same `Assets/app-store/copy/en/macos/whats-new.txt` the Mac App Store upload requires. Publishing needs `gh` authenticated (`gh auth login`; `brew bundle` installs it) and a pushed HEAD, and refuses an existing release for the same version.

**Why a disk image and not the zip.** The zip remains available as the bare-bundle alternate and is also what notarytool accepts for each app submission, but the DMG is the default download. A zip expands wherever the browser drops it, and a quarantined app launched from `~/Downloads` runs *translocated*, from a read-only random mount point that vanishes on quit. For this app that is not cosmetic: Settings > General > Default music player registers with Launch Services from the path it is running at, so a click from a translocated copy registers a path that ceases to exist — and `DefaultAppRegistration` already has to reason about several copies of the app. Dragging out of a disk image is what clears translocation, and the `/Applications` alias is what makes that the obvious gesture. **The window is deliberately plain**: no background image, no icon placement. Those need Finder driven over AppleScript to write a `.DS_Store`, which wants Automation permission and is the flakiest step in any DMG script, and two icons side by side carry the whole point. Four notarization submissions are required — each architecture's app before packaging and its image after — and every staple is checked at publish because a missing one makes Gatekeeper re-check online.

There are three release paths and they are not interchangeable. Each uses a different certificate, a different container and a different verification:

| | `make release` | `make appstore-build` | `make appstore-build-ios` |
|---|---|---|---|
| platform | macOS | macOS | iOS |
| script | `scripts/release.sh` | `scripts/release-appstore.sh` | the same, `--platform ios` |
| scheme | `Vibe` | `Vibe` | `VibeiOS` |
| configuration | `Release` | `AppStore` (no updater) | `Release` |
| certificate | Developer ID Application | Apple Distribution (+ Mac Installer) | Apple Distribution |
| architecture | universal plus arm64-only | universal (`arm64` + `x86_64`) | `arm64` |
| output | two stapled `.dmg`s plus zipped apps | universal `.pkg` to App Store Connect | `.ipa` to App Store Connect |
| verification | notarize + staple + `spctl`, app and image both | App Store Connect validation | App Store Connect validation |

Each App Store pair works the same way: `appstore-build[-ios]` stops after validation, `appstore-upload-signed-build[-ios]` submits.

**Both apps ship under one bundle id**, `com.commonwealthrecordings.Vibe` — Universal Purchase, so one app record with the name, subtitle, category, age rating and privacy answers shared, and a separate version train per platform. `project.yml` declares the version once for both targets, so a release cuts the same number on each, but **each platform needs its own version record open in ASC carrying that string**, or the build has nothing to attach to. A platform freshly added to the record does not start at your number — a new iOS platform opened at `1.0` against a `1.12` build is the shape of it.

**iOS has no direct-download path.** `make release` is macOS-only, so for iOS the store is the only channel and a beta is TestFlight rather than a GitHub prerelease. Internal testing needs no beta review and lands minutes after processing; external testing needs Beta App Review for the first build of each version train, plus a beta description, a feedback email and Beta App Review Information.

**Two postflights run on the exported `.ipa`**, because neither thing exists until the archive has been re-signed for distribution: the widget executable must be present in `PlugIns/VibeWidget.appex/`, and the embedded profile must grant `group.com.commonwealthrecordings.Vibe`. The widget draws nothing but what it reads from that container, so a distribution profile that quietly dropped the entitlement would ship a permanently blank widget to every user, and no earlier step would have said so. On failure the decoded profile is left at `build/appstore-ios/embedded.mobileprovision.plist`.

**TRAP: `.release-env` is gitignored, so it exists only in the checkout that created it.** Every release script fails its credential preflight from a git worktree. Release from the main checkout, or pass `ASC_KEY_ID` / `ASC_ISSUER_ID` in the environment.

Both preflight `asc_require_translations` before the archive: a key missing any catalog language fails the release outright, because nothing else catches it — `make check-strings` compares the catalog to the source and the build compiles a partial key without complaint, so it would ship English in that locale alone. Fix by translating, not by skipping; the **vibe-strings** skill has the conventions. This is separate from the product-page copy below — that's ASC metadata, this is the in-app catalog.

## The release commit

A release commit bumps `project.yml`'s `vibe-version` lines and rewrites `whats-new.txt`. **A stable release also sets `VIBE_BETA_DEBUG: 0` in that same commit; a beta keeps 1.** It sets `VIBE_VERBOSE_LOGGING` and the mac's Beta updates default (`AppSettings receiveBetaUpdates`). `VIBE_VERBOSE_LOGGING` compiles in the beta instrumentation — every log level persisted at Default, the `Timeline:`, `Callback:`, `Signal:` and `Stall:` lines, the stall watchers and the signal probe (`Vibe/Audio/AGENTS.md`) — and those lines put the user's file paths in the unified log as public text. Cost is not the reason: on 1.14, turning it off moved playback CPU and power only within noise. **No script flips `VIBE_BETA_DEBUG`.** That is how 1.13 and 1.14 shipped with verbose logging on. The commit that opens the next version on `main` sets it back to 1, so betas and everyday builds keep the instrumentation.

The commit is `release: <ver>`, on an up-to-date `main` in the main checkout (`.release-env`, below), bumping both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. **The build number never restarts with a new marketing version**, even when a request reads like "1.14 (114)": confirm rather than go backwards. When the notes are still under review, push the version bump alone and build from it, commit the notes as `release: <ver> notes`, wait for CI on that commit, and publish from it. TRAP: **`github-release.sh` tags the main checkout's HEAD at publish time, not the commit `make release` built.** Another session committing in that checkout between the two put `v1.14-beta2` one commit past its release commit; check `git log -1` there just before publishing.

Before publishing a stable release, `strings -a build/release/export/Vibe.app/Contents/MacOS/Vibe | grep -c 'Timeline: play'` must print 0 (a verbose build prints about 20). The flag is a compile-time setting, so it governs the App Store builds too.

## The marketing page

`Assets/Web/` is a static site with no build step, served from two hosts: Cloudflare Pages at **vibeplayer.app** (canonical) and GitHub Pages at cmicali.github.io/vibe. Its own `README.md` has the detail.

The page's Download button links the **universal** direct-DMG asset, `Vibe-macOS-universal-<version>.dmg`, and shows the version beside it, so the two must agree. The architecture-qualified name makes the site's “Apple silicon and Intel” default explicit; the arm64-only DMG is the alternate on GitHub. GitHub's `latest/download` shortcut cannot supply the default — it only redirects for an asset name that never changes — so `scripts/web-set-version.sh <version>` rewrites both, keyed on the `dmg-link` and `dmg-version` element ids rather than the markup around them; a pattern that stops matching is an error, never a silent no-op.

**<https://vibeplayer.app/download/latest> is the URL to hand anyone outside this repo** (`/download` and `/download/` too). It is a Cloudflare `_redirects` rule that the same `web-set-version.sh` run points at the same file as the button, so the branded link and the button cannot come to name different builds. **302, never 301** — the target moves every release, and a cached permanent redirect would pin a browser to one version forever. Cloudflare only: GitHub Pages ignores `_redirects`, as with `/support`.

**`github-release.sh` runs it before creating the release, not after, and the ordering is the point.** The page update is committed — `index.html` and `_redirects`, by explicit pathspec, so a dirty tree cannot ride along — and pushed, and only then is `gh release create` called with `--target HEAD`. The tag therefore names a tree whose website already advertises that release: checking out `v<version>` gets the page that goes with it. This is the one step that moves `main`, and it happens while everything is still reversible, which is why a failed commit or push here is **fatal** rather than a warning — nothing has been published yet, and a tag on an unpushed commit would dangle. The tag-points-at-HEAD preflight runs after that push, since it is only authoritative once HEAD has stopped moving.

The same commit adds the release's items to the update feeds (Updates, below). `--draft` skips all of it, and the Homebrew tap below. A draft's download is not public and it creates no tag until published, so there is no ordering to preserve; repoint by hand once it goes out (`scripts/web-set-version.sh <version> && make deploy-web`, then `scripts/brew-set-version.sh <version>`). A draft writes no feed item, so updates never offer it. `--prerelease` skips the page and the tap: a beta must never become `vibeplayer.app/download/latest`, so the page stays on the last stable release. It still commits its feed items, under the beta channel.

**Once the release exists, `github-release.sh` runs `deploy-web.sh` itself**, since the page and the feed items name its assets. A draft deploys nothing. The release is already out when the deploy runs, so a deploy failure is a warning that names the retry, `make deploy-web`.

`make deploy-web` carries the same page to Cloudflare. It refuses to upload a page whose Download button does not return 200 — the check that the rewrite and the release happened in that order — or whose `/download` rules name a different file or a status other than 302, which is checked even under `--skip-link-check` because no page displays where that link lands. `ARGS="--dry-run"` runs both checks and lists the files without credentials.

**It is local-only, and enforced as such.** `deploy-web.sh` exits if `CI`, `GITHUB_ACTIONS`, `GITLAB_CI` or `BUILDKITE` is set. The Cloudflare token stays in the gitignored `.release-env` beside the ASC keys, out of CI secrets, so a later "just add it to a workflow" has to be deliberate. The token needs exactly **Account | Cloudflare Pages | Edit**. GitHub Pages is the copy CI is allowed to publish, precisely because `.github/workflows/pages.yml` needs no credential — it deploys with the workflow's own OIDC token.

**The page's images are derived, and staleness is silent.** `scripts/web-build-images.sh` re-derives `Assets/Web/img/` from the screenshots already in the repo, and `--check` fails when a derivative no longer matches its source. It exists because nothing used to do that: the 1.12 screenshot rework replaced every `Assets/screenshot-*.png` and the site served the previous month's copies straight through a release deploy. Run it after any screenshot change. It covers the screenshots only, the App Store ones the carousel shows included — the icons and Apple's App Store badge are outside it, so a passing `--check` does not mean every file in `img/` is current.

**Every asset URL is content-hashed, images included.** `scripts/web-stamp-assets.sh` writes each file's hash into its `?v=`, and `deploy-web.sh` runs it with `--check`. **An unstamped image is not merely a stale picture**: the CDN serves the new bytes at once (`cf-cache-status: REVALIDATED`), while a browser that visited before keeps drawing the old one for the rest of the four-hour TTL — which reads as a deploy that silently failed, and invites a pointless re-deploy that confirms the wrong diagnosis.

## The Homebrew tap

`brew install cmicali/tap/vibe` installs from [cmicali/homebrew-tap](https://github.com/cmicali/homebrew-tap), and **every stable release must move it**, or `brew upgrade` keeps handing out the previous version with nothing to say so. `make github-release` does it as its last step, so a normal release needs no extra command, but its success line, `🔊 Homebrew tap pointed at <version>`, is a release check like any other. Its failure is a **warning, not fatal**, because the release is already out by then — so a missed warning is a stale tap. The warning prints the retry: `make brew-set-version V=<version>`.

**It runs after the release rather than before, the reverse of the page.** The tap's one file, `Casks/vibe.rb`, is written whole by `scripts/brew-set-version.sh` from its own template and committed through the GitHub contents API — the tap holds nothing edited by hand, so a cask change (the `zap` paths are the sandbox's containers) is made in that template. The two `sha256`s are the digests GitHub computed for the published arm64 and universal DMGs, which is why it cannot run before `gh release create`, and why it can be re-run for any stable release with nothing on disk; a re-run with nothing to change says so and commits nothing. `ARGS="--dry-run"` prints the cask. A beta or a draft is refused, so a published draft is repointed by hand (above).

Validate a template change with `brew tap cmicali/tap <local clone>` and `brew audit --cask --strict --online cmicali/tap/vibe`; `brew install --cask --appdir=<scratch dir>` installs without touching `/Applications`, and `brew untap cmicali/tap` puts the machine back. Homebrew's own homebrew/cask would bump itself, but refuses self-submitted apps below its notability bar (about 225 stars), so the tap is the channel until then.

## The full sequence

All from the main checkout, which has `.release-env`:

1. The release commit (above), pushed.
2. `make release`.
3. `make github-release` — adds the feed items, tags, publishes, repoints the page, deploys the site, and points the tap. Installed copies see the update once the deploy lands; on its warning, `make deploy-web`. Confirm `🔊 Homebrew tap pointed at <version>`; on its warning, `make brew-set-version V=<version>`.
4. Check the tap as a user gets it: `brew update && brew info --cask cmicali/tap/vibe` names the new version.

A beta is `make release`, then `make github-release ARGS="--prerelease"`, which deploys its feed items too. The page and the tap stay on the last stable release.

**Then the performance charts.** Once the tag exists, `make bench-releases VERSIONS="<version>"` builds that tag, runs the app and component benchmarks and redraws `docs/performance.md`, replacing any `<version> pre-release` point measured before the tag; commit it and `docs/performance/`. It must run on the machine every earlier version was measured on, or the report leaves the new version out and says so ([docs/performance.md](../../../docs/performance.md)). The chart has one point per version, so measuring a version again replaces its point: a final `v1.14` supersedes the beta build that stood in for it (`VERSIONS="1.14=v1.14"`).

## Updates (Sparkle)

The direct download updates itself through Sparkle 2, vendored at `Vibe/ThirdParty/Sparkle/` with its `sign_update` and `generate_keys` tools. The Mac App Store build has none of it: `release-appstore.sh` archives the `AppStore` configuration and fails if the archived app carries any Sparkle file, link, `SU*` Info.plist key, or the direct download's entitlements (`asc_require_no_updater`). CI builds `AppStore` and runs the same check.

**The signing key is permanent.** `generate_keys` makes an EdDSA key pair once and keeps the private half in the login keychain. The public half is `VIBE_SPARKLE_PUBLIC_KEY` in `project.yml`, and every shipped build trusts only it. Back the private half up offline beside the Developer ID certificate (`generate_keys -x <file>`; `-f <file>` imports it on another Mac). Losing it strands every installed build: none would accept an update signed by a new key. `release.sh` preflights the key before archiving, then checks that each exported app trusts it and checks its own feed.

**Two feeds, by architecture.** `vibeplayer.app/appcast.xml` offers the universal zip and `appcast-arm64.xml` the arm64-only one, so an arm64-only install stays one. The arm64-only archive passes `VIBE_SPARKLE_FEED_URL`. The feed URLs are baked into every build too, so they never move.

**The feeds live in `Assets/Web/` and are written only by `github-release.sh`.** It verifies each `<zip>.sig` against its zip, refuses a build number not above a feed's newest item, and prepends one item per feed: version, build, minimum macOS, the GitHub asset URL, length, signature, and `whats-new.txt` as Markdown. A `--prerelease` item carries `<sparkle:channel>beta</sparkle:channel>`, which only a build with Settings > General > Beta updates on accepts; that setting defaults on in a beta build. **The deploy must come after `gh release create`**: an item names assets that 404 until the release exists. That is why `github-release.sh` deploys last, and why a feed served straight from the repo would be wrong.

**The export must sign Sparkle's helpers.** `release.sh` checks that the app, the framework, `Autoupdate`, `Updater.app` and both XPC services carry the Developer ID, the hardened runtime and a timestamp. **TRAP: a local build runs without the hardened runtime** (`project.yml`). Under it, library validation refuses an ad-hoc-signed Sparkle in an ad-hoc-signed app, and the app dies at launch with "different Team IDs". `asc_archive` turns it back on for every archive, and notarization rejects a build without it.

## Product-page metadata

**One run writes ONE platform's page.** ASC localizations hang off a version and versions are per platform, so macOS and iOS each have their own description, keywords, promotional text, what's-new, captions and screenshots; `--platform macos` (the default) or `--platform ios` picks which. The iOS text is not the macOS text reworded — the macOS page sells key analysis, the pitch fader and bit-perfect output, all macOS-only. A page describing features the app does not have is a review rejection.

The build upload carries no product-page content. Localized copy and screenshots live in `Assets/app-store/` (per-locale format: its README) and upload separately with `make appstore-upload-metadata` — `scripts/appstore-upload-metadata.sh` driving the Swift/Bagbutik tool in `scripts/asc-upload/`, authenticated by the same shared key (metadata itself needs only App Manager, so the Admin key more than covers it).

The loop:

1. Edit `Assets/app-store/copy/<lang>/<platform>/` — every catalog language, not just `en`, and `macos` or `ios`; nothing auto-translates. Every file under `<lang>/` is an ASC version field and versions are per platform, which is what the platform directory is for; the three URL files are not version fields and stay shared at `copy/`. **`whats-new.txt` must be rewritten for every release** — ASC blocks submission when any locale lacks release notes, and stale notes upload silently. The shared `copy/support-url.txt`, `copy/marketing-url.txt` and `copy/privacy-url.txt` upload to every locale too.
2. `make appstore-validate-copy` — ASC character limits, markdown that would upload verbatim, captions that overflow the screenshot layout. (`appstore-upload-metadata` runs this first anyway.)
3. `make appstore-generate-store-screenshots-all` — only if `screenshots.json` captions or the window captures changed.
4. `make appstore-upload-metadata ARGS="--dry-run"`, then without.

Flags via `ARGS`: `--locales de,fr`, `--skip-screenshots`, `--skip-text`, `--create-version <v>`.

Traps and semantics:

- **It targets the one *editable* version on the chosen platform.** After a release goes live there is none — the tool errors, listing every version's state. `--create-version <next>` opens the next version's page (the same version record a later `make appstore-upload-signed-build[-ios]` build attaches to, so metadata-first is the normal order).
- **Text is diffed, screenshots are not.** Unchanged text fields are skipped; each screenshot set is deleted and re-uploaded wholesale, ordered by file name. Don't read "uploaded 4 screenshots" as "they changed".
- **macOS has one screenshot set per locale, iOS has two.** `APP_DESKTOP` against `APP_IPHONE_67` and `APP_IPAD_PRO_3GEN_129` — iPhone and iPad are separate sets, not two sizes of one, and the iPad set is required because `TARGETED_DEVICE_FAMILY` is `1,2`. **`APP_IPHONE_69` does not exist**; ASC's own enumeration of valid values tops out at 6.7", and bumping Bagbutik will not add it.
- **`bg` is skipped by design** — the App Store has no Bulgarian product page; the translation ships in-app only. Catalog `nb` maps to ASC `no`. A new catalog language fails loudly until added to `ascLocale` in `ASCUpload.swift`.
- **The privacy policy URL is not a version field.** It lives on `appInfoLocalizations`, per locale, beside the app name and subtitle — so setting it by hand is the same edit 29 times. `copy/privacy-url.txt` uploads it: the tool finds the one editable `AppInfo`, then patches each locale whose URL differs. It only *patches*; creating an `appInfoLocalization` requires a `name`, and inventing an app name per locale is the mistake the out-of-scope rule below exists to prevent, so a locale with no localization is reported rather than created.
- **Out of scope, on purpose:** app name and subtitle (the other `appInfoLocalizations` fields, rarely change — edit in ASC by hand).
- `description.txt` uploads *verbatim* — plain text only; `appstore-validate-copy` rejects leftover markdown markers.

## The shared API key

Both scripts share one App Store Connect API key, `ASC_KEY_ID` and `ASC_ISSUER_ID`, read from a gitignored `.release-env` at the repo root. Resolution lives in `scripts/asc-auth-lib.sh`, which both scripts source. That single key covers cloud signing, notarization — `notarytool --key/--key-id/--issuer`, so no app-specific password and no `store-credentials` profile — and upload.

The key must carry the **Admin** role. Cloud-managed *App Store* certificates are Admin-gated, so an App Manager key authenticates and uploads fine but fails the export with a 403. A key's role cannot be edited after creation.

## Three signing traps

Each was learned the hard way, and each is now guarded by a preflight or an error explainer.

- **Neither archive passes signing overrides.** Both keep `CODE_SIGN_IDENTITY: "-"` and let the export re-sign, mirroring Xcode's Archive → Distribute App flow. Pinning `CODE_SIGN_IDENTITY` under automatic signing fails the archive outright with "conflicting provisioning settings".
- **The Developer ID certificate cannot be automated.** Apple gates `DEVELOPER_ID_APPLICATION_MANAGED` to the team's *Account Holder*, a person role no API key can hold, so `-allowProvisioningUpdates` gets a 403 even with an Admin key that signs App Store builds fine. Create it once in Xcode → Settings → Accounts → Manage Certificates, where the cap is five per account. `release.sh` preflights for it, so this fails instantly rather than after a full archive.
- **xcodebuild hides the reason.** A cloud-signing denial surfaces only as "Cloud signing permission error", with Apple's real 403 buried in a temporary `.xcdistributionlogs` bundle. `asc_explain_export_failure` reprints it, with different guidance per certificate type.

`make appstore-build[-ios]` stops after validation; only `make appstore-upload-signed-build[-ios]` submits. Every signing identity is applied on the xcodebuild command line, because `project.yml` deliberately keeps `CODE_SIGN_IDENTITY: "-"` so that everyday builds need no credentials at all.

## A Debug build for someone else's Mac

`make release` is Release-only. To put a diagnosable build (the debug channel, `--log-stderr`) on a tester's Mac: build Debug, copy the app, dump its entitlements (`codesign -d --entitlements - --xml`), delete `com.apple.security.get-task-allow` (notarization rejects it), re-sign with `--options runtime --timestamp --entitlements <edited plist> -s "Developer ID Application: …"`, then `notarytool submit --wait` and `stapler staple`, resolving the key through `asc-auth-lib.sh`'s `asc_resolve_credentials`. TRAP: **`asc-auth-lib.sh` finds the repo root through `BASH_SOURCE`**, so sourced from zsh it answers "credentials not configured" against a valid `.release-env`; run that step under `bash -c`.

## What "upload succeeded" does not mean

`UPLOAD SUCCEEDED` is about **bytes, not registration**. A build takes minutes to appear in App Store Connect and the API, and a run can end with `buildUploadFiles` timing out and "Skipping validation" among its warnings and still register perfectly well. Never read an absent build as a failed delivery and re-upload: that burns the build number, and recovering means bumping `CURRENT_PROJECT_VERSION` and archiving again. Wait, or poll `/v1/builds`.

Two things that mislead while checking, both of which produced a confident wrong answer on the 1.12 release:

- **`curl` eats `filter[app]=…`.** `[` and `]` are its own URL-glob syntax, so the query returns an EMPTY body with exit 0 — no error, no warning. Pass `-g`/`--globoff`. A poll built on one reports "not there yet" forever whatever the truth.
- **Never pipe JSON through zsh's `echo`.** It rewrites the escapes inside the response into literal control characters, and `jq` then reports that Apple returned malformed JSON. Use `printf '%s'`, or write to a file and read that.

An App Review **attachment** can also stick: ASC reserves a slot, then wants the bytes and a commit with a checksum, and a browser that only completes the first leaves `assetDeliveryState.state = AWAITING_UPLOAD`. Submission is then blocked by "There are still attachment uploads in progress" forever. `docs/app-store-releasing.md` has the detail.
