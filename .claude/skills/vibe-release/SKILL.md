---
name: vibe-release
description: Build, sign, notarize, and ship Vibe on both platforms — the macOS Developer ID (make release) and App Store (make appstore-build) paths, the iOS App Store path (make appstore-build-ios), the GitHub release publish (make github-release), the Homebrew tap bump (make brew-set-version), the localized product-page metadata upload (make appstore-upload-metadata), the shared App Store Connect API key and its Admin-role requirement, and the signing traps each script preflights. Use when cutting a release, distributing a build, shipping or TestFlighting the iOS app, updating App Store copy or screenshots, or debugging a signing/notarization/upload failure.
---

# Releasing Vibe

There are three release paths, and they are not interchangeable. Each uses a different certificate, container and verification:

| | `make release` | `make appstore-build` | `make appstore-build-ios` |
|---|---|---|---|
| platform | macOS | macOS | iOS |
| script | `scripts/release/release.sh` | `scripts/appstore/release-appstore.sh` | the same, `--platform ios` |
| scheme | `Vibe` | `Vibe` | `VibeiOS` |
| configuration | `Release` | `AppStore` (no updater) | `Release` |
| certificate | Developer ID Application | Apple Distribution (+ Mac Installer) | Apple Distribution |
| architecture | universal plus arm64-only | universal (`arm64` + `x86_64`) | `arm64` |
| output | two stapled `.dmg`s plus zipped apps | universal `.pkg` to App Store Connect | `.ipa` to App Store Connect |
| verification | notarize + staple + `spctl`, app and image both | App Store Connect validation | App Store Connect validation |

Each App Store pair works the same way: `appstore-build[-ios]` stops after validation, and `appstore-upload-signed-build[-ios]` submits. One-time setup, reviewer notes and the App Store runbook are in `docs/app-store-releasing.md`.

**TRAP: `.release-env` is gitignored, so it exists only in the checkout that created it.** A worktree needs its own file or credentials in the environment. Release from the main checkout, or pass `ASC_KEY_ID` and `ASC_ISSUER_ID` in the environment.

**Both archive scripts preflight `asc_require_translations`** before the archive. A key missing any catalog language fails the release, because nothing else catches it: `make check-strings` compares the catalog to the source, and the build compiles a partial key silently, so that locale would show English. Fix it by translating, never by skipping (the **vibe-strings** skill). This is the in-app catalog, separate from the product-page copy below.

**A release is never a build slot** (the **vibe-debug** skill, Slots). Every agent shell has a session id, so both archive scripts set `VIBE_NO_SLOT=1` and clear the slot's names rather than refuse. `asc_export_archive` and `github-release.sh` refuse any app that is not the stock `Vibe.app` (`vibe_assert_stock_bundle`, in `scripts/vibe-env.sh`).

## The Developer ID path

`make release` builds two Release archives: universal under `build/release/` and arm64-only under `build/release/arm64/`. Each is exported with Developer ID, notarized and stapled, then packaged in its own plain drag-to-`Applications` DMG, which is itself signed, notarized and stapled. Architecture is a build input. Never thin the signed universal app, since changing its executable invalidates the signature and notarization. Each final zip is signed for Sparkle into `<zip>.sig`.

**The DMG is the default download.** A zip expands wherever the browser drops it, and a quarantined app launched from `~/Downloads` runs translocated, from a random read-only mount that vanishes on quit. Settings > General > Default music player registers the path the app runs at, so a translocated copy would register a path that ceases to exist. Dragging out of a disk image clears translocation. The window is deliberately plain, since a background image needs Finder driven over AppleScript, the flakiest step in any DMG script. Four notarization submissions are needed, and every staple is checked at publish.

`make github-release` (`scripts/release/github-release.sh`; `ARGS="--draft"` for a review pass, `ARGS="--prerelease"` for a beta) re-verifies every exported app, DMG, mounted app and zipped app, including architecture and version, then tags HEAD as `v<MARKETING_VERSION>`. It attaches `Vibe-macOS-universal-<version>.dmg` and `.zip` and `Vibe-macOS-arm64-<version>.dmg` and `.zip`. Release notes come from `Assets/app-store/copy/en/macos/whats-new.txt`. It needs `gh` authenticated and a pushed HEAD, and refuses an existing release for the same version.

## The release commit

A release commit bumps `project.yml`'s `vibe-version` lines (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`) and rewrites `whats-new.txt`. Make it as `release: <ver>`, on an up-to-date `main` in the main checkout. **The build number never restarts with a new marketing version.** Confirm rather than go backwards when a request reads like "1.14 (114)". When the notes are still under review, push the version bump alone and build from it. Then commit the notes as `release: <ver> notes`, wait for CI, and publish from that commit.

**The notes name every cache archive version bump since the last release**, since the new build then reads each file again. Two are pending after v1.17. The metadata archive's v8 (#400) parses every file's tags once. The waveform archive's format 7 (#355) decodes each waveform again when it is next shown.

**A stable release sets `VIBE_BETA_DEBUG: 0` in the same commit; a beta keeps 1.** It controls `VIBE_VERBOSE_LOGGING` and the mac's Include beta versions default (`receiveBetaUpdates`). Verbose logging compiles in the beta instrumentation (`Vibe/Audio/AGENTS.md`, Diagnostics), which writes the user's file paths into the unified log as public text. **No script flips `VIBE_BETA_DEBUG`, so a stable release ships verbose logging unless this commit turns it off.** The commit that opens the next version on `main` sets it back to 1. Before publishing a stable release, `strings -a build/release/export/Vibe.app/Contents/MacOS/Vibe | grep -c 'Timeline: play'` must print 0. The flag is compile-time, so it governs the App Store builds too.

TRAP: **`github-release.sh` tags the main checkout's HEAD at publish time, not the commit `make release` built.** Another session committing in that checkout between the two moves the tag. Check `git log -1` there just before publishing.

## The full sequence

All from the main checkout, which has `.release-env`:

1. The release commit, pushed.
2. `make release`.
3. `make github-release`. It repoints the web page, adds the feed items, tags, publishes, deploys the site and points the Homebrew tap. On the deploy's warning, run `make deploy-web`. Confirm `🔊 Homebrew tap pointed at <version>`. On its warning, run `make brew-set-version V=<version>`.
4. Check the tap as a user gets it: `brew update && brew info --cask cmicali/tap/vibe` names the new version.
5. Once the tag exists, chart it: `make bench-releases VERSIONS="<version>"` on the machine every earlier version was measured on, then commit `docs/performance.md` and `docs/performance/` (the **vibe-perf** skill). It replaces any pre-release point for that version.

A beta is `make release`, then `make github-release ARGS="--prerelease"`. The page and the tap stay on the last stable release, and its feed items go out under the beta channel.

### What `github-release.sh` does in order

The web site's mechanics (the Download button's version, the `/download/latest` 302 link, the local-only Cloudflare deploy, derived images and content-hashed assets) are in `Assets/Web/README.md`. The release ordering is here:

1. **Before the release**, it runs `scripts/web/web-set-version.sh <version>` and adds the feed items. It commits `index.html`, `_redirects` and the feeds by explicit pathspec and pushes. A failed commit or push is **fatal**, since nothing is published yet and a tag on an unpushed commit would dangle. The tag-points-at-HEAD preflight runs after that push.
2. It calls `gh release create --target HEAD`, so the tag names a tree whose page already advertises the release.
3. **After the release exists**, it runs `deploy-web.sh`, since the page and the feed items name the release's assets, which 404 until then. A deploy failure is a warning naming the retry, `make deploy-web`.
4. Last, it runs `brew-set-version.sh` (below). Its failure is a warning, so a missed warning is a stale tap.

`--draft` skips the page, the feeds, the deploy and the tap. A draft creates no tag until published and writes no feed item. Once a draft is published, repoint by hand: `scripts/web/web-set-version.sh <version> && make deploy-web`, then `scripts/release/brew-set-version.sh <version>`. `--prerelease` skips the page and the tap, since a beta must never become `vibeplayer.app/download/latest`, but still commits its feed items.

## The Homebrew tap

`brew install cmicali/tap/vibe` installs from [cmicali/homebrew-tap](https://github.com/cmicali/homebrew-tap). **Every stable release must move it**, or `brew upgrade` keeps handing out the previous version. `scripts/release/brew-set-version.sh` writes the tap's one file, `Casks/vibe.rb`, whole from its own template and commits it through the GitHub contents API. Make cask changes (the `zap` paths are the sandbox's containers) in that template. The two `sha256`s are the digests GitHub computed for the published DMGs, so it cannot run before `gh release create`. It can be re-run for any stable release, and a re-run with nothing to change commits nothing. `ARGS="--dry-run"` prints the cask. A beta or a draft is refused.

Validate a template change with `brew tap cmicali/tap <local clone>` and `brew audit --cask --strict --online cmicali/tap/vibe`. `brew install --cask --appdir=<scratch dir>` installs without touching `/Applications`, and `brew untap cmicali/tap` puts the machine back. homebrew/cask refuses self-submitted apps below its notability bar, so the tap is the channel.

## Updates (Sparkle)

The direct download updates itself through Sparkle 2, vendored at vibe-libs' `third_party/Sparkle/` with its `sign_update` and `generate_keys` tools. The Mac App Store build has none of it. `release-appstore.sh` archives the `AppStore` configuration and fails if the archive carries any Sparkle file, link, `SU*` Info.plist key or the direct download's entitlements (`asc_require_no_updater`). CI builds `AppStore` and runs the same check.

**The signing key is permanent.** `generate_keys` makes an EdDSA key pair once and keeps the private half in the login keychain. The public half is `VIBE_SPARKLE_PUBLIC_KEY` in `project.yml`, and every shipped build trusts only it. Back the private half up offline beside the Developer ID certificate (`generate_keys -x <file>`; `-f <file>` imports it on another Mac). Losing it strands every installed build. `release.sh` preflights the key, then checks that each exported app trusts it.

**Two feeds, by architecture.** `vibeplayer.app/appcast.xml` offers the universal zip and `appcast-arm64.xml` the arm64-only one, so an arm64-only install stays one. The arm64-only archive passes `VIBE_SPARKLE_FEED_URL`. The feed URLs are baked into every build, so they never move.

**The feeds live in `Assets/Web/` and only `github-release.sh` writes them.** It verifies each `<zip>.sig`, refuses a build number below a feed's newest item, and prepends one item per feed with `whats-new.txt` as Markdown. A `--prerelease` item carries `<sparkle:channel>beta</sparkle:channel>`, which only a build with Settings > General > Include beta versions on accepts. That setting defaults on in a beta build.

**The export must sign Sparkle's helpers.** `release.sh` checks that the app, the framework, `Autoupdate`, `Updater.app` and both XPC services carry the Developer ID, the hardened runtime and a timestamp. **TRAP: a local build runs without the hardened runtime** (`project.yml`). Under it, library validation refuses an ad-hoc-signed Sparkle in an ad-hoc-signed app, which dies at launch with "different Team IDs". `asc_archive` turns it on for every archive, and notarization rejects a build without it. A Debug build starts no updater unless launched with `--update-feed <url>`.

## The App Store paths

**Both apps ship under one bundle id**, `com.commonwealthrecordings.Vibe`: Universal Purchase, one app record with shared name, subtitle, category, age rating and privacy answers, and a separate version train per platform. `project.yml` declares one version for both targets, but **each platform needs its own version record open in App Store Connect carrying that string**, or the build has nothing to attach to. A platform newly added to the record starts at `1.0`, not at your number.

**iOS has no direct-download path.** A beta is TestFlight. Internal testing needs no beta review and lands minutes after processing. External testing needs Beta App Review for the first build of each version train, plus a beta description, a feedback email and Beta App Review Information.

**Two postflights run on the exported `.ipa`**, because neither thing exists until the archive is re-signed for distribution. The widget executable must be present in `PlugIns/VibeWidget.appex/`, and the embedded profile must grant `group.com.commonwealthrecordings.Vibe`. The widget draws only what it reads from that container, so a profile that dropped the entitlement would ship a permanently blank widget. On failure the decoded profile is left at `build/appstore-ios/embedded.mobileprovision.plist`.

## Product-page metadata

**One run writes one platform's page.** App Store Connect localizations hang off a version, and versions are per platform, so macOS and iOS each have their own description, keywords, promotional text, what's new, captions and screenshots. `--platform macos` (the default) or `--platform ios` picks which. The iOS text is not the macOS text reworded: key analysis, the pitch fader and bit-perfect output are macOS-only, and a page describing features the app lacks is a review rejection.

The build upload carries no product-page content. Copy and screenshots live in `Assets/app-store/` (format in its README) and upload separately with `make appstore-upload-metadata`. That runs `scripts/appstore/appstore-upload-metadata.sh`, which drives the Swift tool in `scripts/appstore/asc-upload/` with the shared key.

The loop:

1. Edit `Assets/app-store/copy/<lang>/<platform>/` for every catalog language, not just `en`. Nothing auto-translates. **Rewrite `whats-new.txt` for every release.** The uploader omits it for a platform's first version. Later versions upload it verbatim. The shared support and marketing URLs upload to every version localization. The privacy URL uploads to app-info localizations.
2. `make appstore-validate-copy`: character limits, leftover markdown, captions that overflow the screenshot layout. The upload runs it first anyway.
3. `make appstore-generate-store-screenshots-all`, only if `screenshots.json` captions or the window captures changed.
4. `make appstore-upload-metadata ARGS="--dry-run"`, then without. **For a release whose screenshots did not change, add `--skip-screenshots` to both.** A new version already carries copies of the previous version's processed screenshots. Replacing them gains nothing and risks the stall described below. The checksum diff should leave those copies alone anyway. A dry run that would upload them shows the copies carry no checksum.

Flags via `ARGS`: `--platform ios`, `--locales de,fr`, `--skip-screenshots`, `--skip-text`, `--create-version <v>`.

- **It targets the one editable version on the chosen platform.** After a release goes live there is none, and the tool errors with every version's state. `--create-version <next>` opens the next version's page, the same record a later build attaches to, so metadata first is the normal order.
- **Text is diffed field by field, screenshots by checksum.** Unchanged text fields are skipped. A screenshot set keeps each processed screenshot whose `sourceFileChecksum` matches a local file. It deletes the rest and uploads only the files left over. A set with nothing to change prints "unchanged" and is not touched. The dry run prints what each set would keep, upload, and delete.
- **TRAP: App Store Connect can leave a screenshot unprocessed for good.** On the iOS 1.15 upload, about half of every batch stayed in `UPLOAD_COMPLETE` with no errors and a null `sourceFileChecksum`. "Add for Review" then refused the version with "1 or more screenshots must finish processing". Uploading whole sets again stalled just as often. Unique file bytes did not help. Re-sending the commit PATCH answered 500. What worked was deleting each stuck screenshot alone and uploading it again, a few rounds over. The tool now does this itself. It polls until every upload is processed, and syncs a stalled set again in bounded rounds. The timings are constants at the top of `ASCUpload.swift`. Expect a screenshot upload to take several minutes, and much longer when the stall recurs. A run that hits the cap names the stuck files. Running it again, without `--skip-screenshots`, uploads only those.
- **macOS has one screenshot set per locale, iOS has two**: `APP_DESKTOP` against `APP_IPHONE_67` and `APP_IPAD_PRO_3GEN_129`. The iPad set is required because `TARGETED_DEVICE_FAMILY` is `1,2`.
- **`bg` is skipped by design**, since the App Store has no Bulgarian product page. Catalog `nb` maps to `no`. A new catalog language fails loudly until added to `ascLocale` in `ASCUpload.swift`.
- **The privacy policy URL is not a version field.** It lives on `appInfoLocalizations`, per locale. `copy/privacy-url.txt` patches each locale whose URL differs. Creating an `appInfoLocalization` needs a `name`, so a locale with none is reported, not created.
- **Out of scope**: the app name and subtitle. Edit them in App Store Connect by hand.
- `description.txt` uploads verbatim, as plain text.

## The shared API key

All scripts share one App Store Connect API key, `ASC_KEY_ID` and `ASC_ISSUER_ID`, from the gitignored `.release-env` at the repo root. `scripts/appstore/asc-auth-lib.sh` resolves it. The key covers cloud signing, notarization (`notarytool --key/--key-id/--issuer`, no app-specific password) and upload.

The key must carry the **Admin** role. Cloud-managed App Store certificates are Admin-gated, so an App Manager key authenticates and uploads but fails the export with a 403. A key's role cannot be edited after creation.

## Signing traps

Each is guarded by a preflight or an error explainer.

- **Archives keep the project's automatic signing.** Distribution identities belong in the export options. Pinning a distribution identity for the archive conflicts with automatic signing.
- **`release.sh` requires a local Developer ID Application certificate.** It checks the keychain before building. Create the certificate through the team's signing setup before running it.
- **xcodebuild hides the reason.** A cloud-signing denial surfaces only as "Cloud signing permission error", with Apple's real 403 buried in a temporary `.xcdistributionlogs` bundle. `asc_explain_export_failure` reprints it, with guidance per certificate type.

## A Debug build for someone else's Mac

`make release` is Release-only. A Debug build for another Mac needs a separate signed and notarized package. Remove `com.apple.security.get-task-allow` from its entitlements. Sign the app and every nested Sparkle executable with Developer ID, hardened runtime and a timestamp. Use `release.sh`'s nested-code checks as the inventory. Notarize and staple the package before sharing it.

TRAP: **Source `asc-auth-lib.sh` from bash.** Its repo lookup uses `BASH_SOURCE`.

## What "upload succeeded" does not mean

`UPLOAD SUCCEEDED` is about **bytes, not registration**. A build takes minutes to appear in App Store Connect and the API. A run can end with `buildUploadFiles` timing out and "Skipping validation" among its warnings and still register. Never read an absent build as a failed delivery and re-upload: that burns the build number, and recovery means bumping `CURRENT_PROJECT_VERSION` and archiving again. Wait, or poll `/v1/builds`.

Two things mislead while checking:

- **`curl` eats `filter[app]=…`.** `[` and `]` are its URL-glob syntax, so the query returns an empty body with exit 0. Pass `-g` (`--globoff`).
- **Never pipe JSON through zsh's `echo`.** It rewrites escapes into control characters, and `jq` then reports malformed JSON. Use `printf '%s'`, or a file.

A stuck App Review attachment (`AWAITING_UPLOAD`) is in `docs/app-store-releasing.md`.
