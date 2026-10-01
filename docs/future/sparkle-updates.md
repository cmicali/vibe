# Future: Automatic updates for the direct-download Mac build (Sparkle)

**Status: planned, not implemented (verified 2026-10-01).** Issue #124, with `unsandboxed-direct-build.md`.

Written to be executed phase by phase. Each phase builds, passes `make test`, and is verifiable on its own. Read the root `AGENTS.md`, `Vibe/Mac/App/AGENTS.md`, `Vibe/Mac/Menu/AGENTS.md`, and `Vibe/ThirdParty/AGENTS.md` first; the release scripts need the `vibe-release` skill, strings the `vibe-strings` skill, verification the `vibe-debug` skill.

**Build this before unsandboxing, and independently of it.** Sparkle 2 updates a sandboxed app, so this plan keeps the direct build sandboxed and ships no data migration. `unsandboxed-direct-build.md` reuses Phase 1's configuration split and then deletes this plan's sandbox-only pieces (Phase 2's XPC keys and entitlements).

## The feature

- The **direct-download** Mac build (Developer ID, `make release`, the disk image on vibeplayer.app and GitHub) checks for updates on a schedule and offers to install them, through Sparkle's standard UI.
- **Vibe > Check for Updates…** checks on demand.
- Sparkle's own first-run prompt asks whether to check automatically; Vibe adds no setting of its own in the first version.
- **Betas reach only people who ask.** A `--prerelease` publish goes to a `beta` channel; a stable build never offers it. Opting in is a Settings > Advanced toggle (Phase 5), left out if the first version needs to be smaller.
- **The Mac App Store build contains no Sparkle code, no feed URL, and no menu item.** App Review rejects a Mac App Store app that updates itself (guideline 2.4.5), and a linked-but-unused updater framework is enough to trip it.
- iOS is untouched.

## What exists today

- Both Mac channels archive the same `Release` configuration with the same entitlements (`project.yml`'s `Vibe` target: `ENABLE_APP_SANDBOX: YES`, `Vibe/Mac/App/Vibe.entitlements`); `scripts/release.sh` and `scripts/release-appstore.sh` differ only in the export method. `asc_archive` (`scripts/asc-build-lib.sh`) hardcodes `-configuration Release`.
- No compile-time or runtime marker separates the two channels.
- The entitlements carry no network access. Sparkle will be the app's first network client.
- `release.sh` produces, per architecture set (universal, arm64-only), a stapled app, a stapled zip made after stapling, and a stapled disk image. `github-release.sh` verifies and attaches them, and `--prerelease` already keeps a beta off the website.
- Current direct-download users have no updater, so they reach the first Sparkle build by downloading it once by hand.

## Decisions to make before Phase 1

1. **How Sparkle enters the tree.** The repository has no package manager and vendors sources. Sparkle is a large Swift and Objective-C project with XPC services, so vendoring its source is not practical. Recommended: vendor the **prebuilt `Sparkle.xcframework`** from a pinned release tarball under `Vibe/ThirdParty/Sparkle/`, with the version and the tarball's SHA-256 recorded in `ThirdParty/AGENTS.md`, and the MIT notice (plus its bundled components' notices) in `THIRD-PARTY-NOTICES.md` and `NOTICE`. The alternative is a `packages:` entry in `project.yml`, which makes every `xcodegen generate` plus build depend on a network resolve; it is rejected unless the binary's size in git is unacceptable.
2. **Where the appcast lives.** Recommended: `https://vibeplayer.app/appcast.xml` (and `appcast-arm64.xml`), deployed by `make deploy-web`, with enclosures pointing at the GitHub release assets. The feed URL is baked into every shipped build forever, so it must be a domain Vibe controls, not a GitHub URL.
3. **One feed or two.** Two builds ship (universal, arm64-only). Recommended: two feeds, selected by a build setting (Phase 2), so an arm64-only install stays arm64-only. The fallback is one feed pointing everybody at the universal build.

## Phase 1 — A third configuration: `AppStore`

The split both plans need. No behavior change.

- `project.yml`: add `AppStore: release` to `configs`. `Release` stays the direct-download configuration, so `make build`, `make release`, CI's analyzer run, and the iOS App Store path keep their meaning. Anything set per configuration under `Release` is mirrored for `AppStore`.
- A preprocessor define on the `Vibe` target, `VIBE_DIRECT_DISTRIBUTION=1`, in `Debug` and `Release`; absent in `AppStore`. This is the one channel marker; nothing else may infer the channel (no receipt checks, no bundle inspection).
- `scripts/asc-build-lib.sh`: `asc_archive` takes the configuration from a variable defaulting to `Release`; `release-appstore.sh` sets it to `AppStore` for `--platform macos` only.
- `Makefile`: `make build CONFIG=AppStore` already works through `build.sh`; `make analyze` gains nothing new.
- CI (`.github/workflows/build.yml`): add one `make build CONFIG=AppStore` leg, so the configuration that ships to the store cannot rot.
- Docs: root `AGENTS.md` "Building" names the three configurations and which channel each is; the `vibe-release` skill and `docs/app-store-releasing.md` say the Mac App Store archive is `AppStore`.

**Verify:** `make build`, `make build CONFIG=AppStore`, `make test`, `make analyze CONFIG=Release`; `make appstore-build` validates against App Store Connect without uploading.

## Phase 2 — Link and embed Sparkle in the direct configurations only

- Vendor the xcframework (decision 1).
- `project.yml`, `Vibe` target: Sparkle is embedded, signed, and linked in `Debug` and `Release`, and absent from `AppStore`. XcodeGen has no per-configuration dependency, so the expected shape is the framework dependency plus `EXCLUDED_SOURCE_FILE_NAMES: Sparkle.framework` and no `-framework Sparkle` in `AppStore`. **Confirm against a real `AppStore` archive** (`find Vibe.app -iname '*sparkle*'` is empty, `otool -L` names no Sparkle) and make that check a preflight in `release-appstore.sh`, beside its existing entitlement check.
- `Info.plist` keys, present only in the direct configurations (per-configuration `INFOPLIST_PREPROCESS` on `VIBE_DIRECT_DISTRIBUTION`, or a `PlistBuddy` delete in the `AppStore` build; pick whichever leaves `Info.plist` readable):
  - `SUFeedURL` = `$(VIBE_SPARKLE_FEED_URL)`, a build setting defaulting to the universal feed. `release.sh`'s arm64-only `asc_archive` call passes the arm64 feed, the same way it already passes `ARCHS=arm64`.
  - `SUPublicEDKey` = the public half of the signing key (Phase 4).
  - `SUEnableInstallerLauncherService` = `YES`. Required while the app is sandboxed.
- A direct-only entitlements file (or per-configuration entitlements) adding, for the sandboxed direct build:
  - `com.apple.security.network.client`, so the app fetches the feed and the update itself. This avoids Sparkle's separate Downloader XPC service.
  - `com.apple.security.temporary-exception.mach-lookup.global-name` with `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`, Sparkle's installer connection and status services.
  The App Store entitlements stay exactly as they are. Temporary exceptions are accepted for Developer ID; they are the reason this file must never reach the `AppStore` configuration.
- **Signing.** The Developer ID export re-signs nested code. Confirm on the exported app that Sparkle's `Autoupdate`, `Updater.app`, and the Installer XPC service are signed with the Developer ID, hardened, and timestamped (`codesign -dvvv` on each), and that notarization accepts the app. If the export does not re-sign them correctly, `release.sh` signs them explicitly, inside out, before the app, as Sparkle's sandboxing guide lays out.

**Verify:** both configurations build; the `AppStore` preflight finds no Sparkle; `make release` notarizes. No update UI exists yet.

## Phase 3 — The updater and its menu item

Zero new files and zero new types: the updater belongs to the application object.

- `AppDelegate` holds one `SPUStandardUpdaterController`, created in launch after the window is up, inside `#if VIBE_DIRECT_DISTRIBUTION`. It is not started in a host-less test process or under the debug render pump.
- `MainMenuBuilder`: **Check for Updates…** under About in the app menu, target the updater controller's `checkForUpdates:`, enabled through its `canCheckForUpdates`. Compiled out of `AppStore` entirely, never merely hidden. The item is not rebindable in Settings > Keyboard Shortcuts unless that pane's rules make it free.
- Strings: one `STR_*` key (`menu.check_for_updates`) in `VibeStrings.h`, `make strings`, and translations for every language (`make check-translations` gates both release paths). Sparkle's own UI ships its own localizations; confirm the languages Vibe ships are covered and note any gap.
- Debug builds: the automatic check is off unless a debug argument points it at a local feed, so the debug channel, stress runs, and screenshots never raise an update dialog. A debug verb is added only if testing needs one.
- `DebugInfo`: add the channel (`direct` or `app store`) and, for direct, the feed URL and the last check date. One line each.

**Verify:** with a local HTTP server serving a hand-made appcast that advertises a higher build number, a direct Debug or Release build finds, downloads, verifies, installs, and relaunches into the new build, **from inside the sandbox**; the `AppStore` build has no menu item.

## Phase 4 — Release pipeline

- **Keys, once.** Sparkle's `generate_keys` puts the EdDSA private key in the login keychain and prints the public key for `SUPublicEDKey`. Export the private key to the same offline place the Developer ID certificate is backed up: losing it strands every installed build. `release.sh` preflights that the key is present, the way it preflights the Developer ID certificate.
- **`release.sh`**: after the final stapled zip of each architecture set exists, run `sign_update` on it and keep the signature and length beside it. Nothing else changes; the zip is already made after stapling.
- **`github-release.sh`**: after the release is created, write the appcast item for each feed (version, build number, minimum system version from `MACOSX_DEPLOYMENT_TARGET`, enclosure URL of the GitHub asset, EdDSA signature, length, and release notes from `Assets/app-store/copy/en/macos/whats-new.txt`) into `Assets/Web/appcast.xml` and `appcast-arm64.xml`, then leave publishing to `make deploy-web`, as the website's download button already works. `--draft` writes nothing. `--prerelease` writes the item with `<sparkle:channel>beta</sparkle:channel>` and, unlike the website repoint, **is** deployed, since the channel keeps it from stable users.
- Whether to keep `generate_appcast` out and write the XML from the script: recommended yes. The items are few and fixed in shape, and the script already knows every value.
- Sparkle compares `CFBundleVersion`. The build number already rises with every release; add a `github-release.sh` check that the new item's build number is higher than the feed's newest.
- The `vibe-release` skill gains the key requirement, the appcast step, and the deploy ordering (release assets must be public before the feed names them).

**Verify:** a `--draft` dry run produces correct signatures; a beta published with `--prerelease` is offered to a build opted into `beta` and not to a stable one.

## Phase 5 — Beta opt-in (optional for the first version)

- `AppSettings+Mac.h`: `receiveBetaUpdates`, default off, direct builds only.
- Settings > Advanced: one toggle, compiled out of `AppStore`. `AppDelegate` answers Sparkle's `allowedChannelsForUpdater:` with `beta` when it is on.
- A build that is itself a beta defaults the toggle on, so a tester stays on the beta train.

## Risks and traps

- **The feed URL and the public key are permanent.** Every shipped build trusts them. Changing either needs a bridging release.
- **A sandboxed Sparkle install is the fragile configuration.** The XPC services, their signatures, and the mach-lookup entitlements must all line up, and the failure is silent until an update is attempted. Phase 3's verification runs against the *exported, notarized* build at least once, not only a local Debug build.
- **Translocation.** A quarantined app run from the mounted disk image or the Downloads folder is translocated and cannot be updated in place; Sparkle refuses and says so. Nothing to build, but support will see it.
- **First adoption is manual.** The release that introduces Sparkle must be announced on the website, since no installed direct build can be told about it.
- **App Store leakage.** The `release-appstore.sh` preflight (no Sparkle binary, no `SU*` keys, no network or temporary-exception entitlements) is what keeps a `project.yml` mistake from becoming a rejection.

## Complexity report (expected)

- New source files: 0. New types: 0.
- New non-source files: the vendored xcframework, one direct-only entitlements file, two appcast files under `Assets/Web/`.
- New configuration: `AppStore`.
- Consolidates nothing: the feature is new surface. It does give the tree its first channel marker, which `unsandboxed-direct-build.md` reuses instead of adding its own.
