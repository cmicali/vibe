# iOS App Store release punchlist

Vibe has shipped to the Mac App Store since 1.0; **1.12 is the first release
that also ships the iOS app.** This is the list of what that first time needs
that a mac release does not. It is a living document — update the status
column as items land, and delete the file once iOS releases are routine and
`app-store-releasing.md` covers everything on its own.

Status: **done** · **blocked** (waiting on another item) · **open**.

> **This file is now safe to delete.** Every trap below that outlives 1.12 has
> been moved to a durable home — `app-store-releasing.md` (§4's first-version
> release-notes rule, "A build takes minutes to appear", "What the reviewer
> sees" for the notes and their attachment, and eight Troubleshooting
> entries), the **vibe-release** skill (upload-vs-registration, the image
> pipeline), **vibe-strings** (caption fit and CJK line breaks), **vibe-debug**
> (`VIBE_SIGN_SIM` and the widget), `Assets/app-store/README.md`,
> `Assets/Web/README.md`, and `TRAP:` comments beside the code. What is left
> here is the history of this one release.

The mechanics of each release path live in
[app-store-releasing.md](app-store-releasing.md); this file is only the
first-time-on-iOS delta.

---

## A. App Store Connect and the Apple account

Nothing in the repo can do these — they are account state.

| | Item | Status |
|---|---|---|
| A1 | Confirm Universal Purchase is what we want. Both targets ship `com.commonwealthrecordings.Vibe`, so iOS *must* join the existing record as a second platform — one name, subtitle, category, age rating, privacy answer and price, with separate version trains. Already baked into `project.yml`. | **done** |
| A2 | Add the iOS platform to the app record. | **done** |
| A3 | App ID must be multi-platform. Verified via the ASC API: both `com.commonwealthrecordings.Vibe` and `…Vibe.Widget` report `platform=UNIVERSAL`. | **done** |
| A4 | App Groups must reach *distribution*, not just development. Both App IDs carry the `APP_GROUPS` capability, and the App Store distribution profile ("iOS Team Store Provisioning Profile") grants `group.com.commonwealthrecordings.Vibe` — proven by the export postflight in B1, which now enforces it on every run. | **done** |
| A5 | **The first iOS build is uploaded and internal TestFlight is live.** 1.12 (112), `platform=IOS`, `processingState=VALID`, `internalBuildState=IN_BETA_TESTING` — installable now by the internal "App Store Connect Users" group, whose feedback email was already set. Prior trains on the record are `MAC_OS`, so this is genuinely the first. **External** is `READY_FOR_BETA_SUBMISSION` and still wants three fields, none of which any script writes: the tester-facing beta description, this build's "what to test", and Beta App Review Information — that last one is F1's `review-notes.txt` verbatim. | **done** for internal; external needs the three fields |
| A6 | The iOS version record was created at `1.0` against a `1.12` build, which would have had nothing to attach to. Both platform records now read 1.12. | **done** |

## B. Build and signing pipeline

| | Item | Status |
|---|---|---|
| B1 | An iOS archive → export → validate → upload path. Landed as `--platform ios` on `scripts/release-appstore.sh` (not a second script), with `make appstore-build-ios` / `make appstore-upload-signed-build-ios`. Proven end to end: `VERIFY SUCCEEDED with no errors` against ASC, nothing uploaded. Adds two iOS postflights — the widget executable is present, and the distribution profile grants the app group. | **done** |
| B2 | Version read back from the archived bundle, not scraped. `APP_SUBPATH` absorbs the `Contents/` difference; the run reported `1.12 (112)`. | **done** |
| B3 | Per-platform architecture assertion — `arm64` + `x86_64` for macOS, `arm64` for iOS. | **done** |
| B4 | CI builds iOS in Release as well as Debug. Everything under `Vibe/Debug` is `#if DEBUG`, so Release compiles different code, and Release is what the archive builds. `main` is unprotected, so the job rename to `build-ios (Debug｜Release)` breaks no required check. | **done** |
| B5 | ~~Add `VibeWidget/Localizable.xcstrings` to `check-translations`~~ — **withdrawn, it was already covered.** The four `widget.*` keys live in `Resources/Localizable.xcstrings` with every language, so `check-translations` gates them there, and `extract-strings.sh --check` re-derives the widget subset and diffs it, so a stale derived catalog fails `make check-strings`. Adding it would have double-reported every failure. | **n/a** |

## C. Product-page copy — complete

ASC localizations hang off a version and versions are per platform, so iOS
needs its own copy. Layout: `copy/<lang>/<platform>/`, because every file under
`<lang>/` is a version field. The three URL files are not version fields and
stay shared at `copy/`. `appstore-validate-copy` now requires both platforms in
every language.

| | Item | Status |
|---|---|---|
| C1 | iOS description, keywords and promotional text, in all 30 catalog languages. Same structure as the macOS page, iOS-true content: waveform scrubbing and swipe, Files/iCloud/Dropbox, no library, formats, home-screen widgets, free and open source. It claims none of the macOS-only features. | **done** |
| C2 | Translations complete — 30 languages × 2 platforms × 4 text fields = 240 files, plus the `themes` caption in every `screenshots.json`. The macOS description and release notes were re-translated where 1.12 changed them. Register and quote conventions per the **vibe-strings** skill (informal de/es/it/nl/hu, formal fr/ru/uk/bg/el, polite ja/ko), Apple's own menu names (`Ablage`, `Archivio`, `Arkiv`), and DJ loanwords kept (`FX`, `pitch`, German `Tempo`). Verified by dry run against both live 1.12 records. | **done** |
| C3 | Layout migrated: 150 files (30 languages × 5) moved under `<lang>/macos/`, English iOS copy added at `<lang>/ios/`, tracked screenshots to `screenshots/en/macos/`. Every reader updated — `appstore-validate-copy.sh` (platform loop, per-platform shot ids), `appstore-generate-store-screenshots.sh`, `appstore-capture-app-screenshots.sh`, `github-release.sh` (its release notes are the macOS ones), `ASCUpload.swift`, both READMEs, the Makefile comments and both skills. | **done** |
| C4 | Release notes for 1.12. macOS rewritten from the CHANGELOG's 1.12 section — it was still carrying the 1.11 notes. iOS written as a first-release introduction. Translated with C2. | **done** |
| C5 | `ASCUpload.swift` takes `--platform macos\|ios`, threaded through version filtering, version creation, the copy directory and the screenshot sets. A platform now declares a **list** of sets, each with the subdirectory its files come from: macOS one (`APP_DESKTOP`, flat), iOS two (`APP_IPHONE_67` from `ios/iphone/`, `APP_IPAD_PRO_3GEN_129` from `ios/ipad/`). Neither platform needs `--skip-screenshots` any more. Verified against the live 1.12 records by dry run on both. | **done** |

## D. Screenshots

| | Item | Status |
|---|---|---|
| D0 | The macOS shot set was reworked in passing: `keys` (keyboard shortcuts) replaced by `themes`, `pitch` moved to the compact capture, one built-in theme per shot, and window sizes pinned instead of inherited from the autosaved frame. Not iOS work, but it is why C2 has a caption to translate. | **done** |
| D1 | An iOS screenshot pipeline. `--platform ios` on `appstore-generate-store-screenshots.sh`, compositing simulator captures onto the two required canvases. Four shots — `player`, `seek`, `playlist`, `widget` — staged through the debug channel and captured with `xcrun simctl io <udid> screenshot`, so the pixels are the device's own. Three compositor changes were needed and **all three are no-ops on macOS, byte-verified after each**: type scaled by the canvas's geometric mean rather than its width, a headline that wraps to two lines, and `--center-text`. | **done** |
| D2 | iPad screenshots are **required** — `TARGETED_DEVICE_FAMILY` is `1,2`. Same four shots at 2048×2732, captured on `iPad Pro (12.9-inch) (6th generation)`. | **done** |
| D3 | **Resolved against Apple's own API.** A deliberately invalid POST made ASC enumerate the valid `screenshotDisplayType` values: `APP_IPHONE_67` and `APP_IPAD_PRO_3GEN_129` are both there and **`APP_IPHONE_69` does not exist at all** — so the pinned Bagbutik 24.0.3 needs no bump (upstream has nothing newer either; 24.0.3 is the latest tag). Targets are **iPhone 6.7\" = 1290x2796** and **iPad 12.9\" = 2048x2732**, and simulators exist at exactly those sizes: `iPhone 16 Plus` and `iPad Pro (12.9-inch) (6th generation)`. | **done** |
| D4 | All 30 languages captioned, headline-only. Short by necessity: at 1.9× with a two-line cap a long translation hits the 72% floor and fails the build. Register per the **vibe-strings** conventions — informal de/es/it/nl/hu/tr, formal fr/ru/uk/bg/el/id, polite ja/ko — and each language's own Apple term for widget (`小组件` Hans, `小工具` Hant). Three CJK captions were rewritten after **looking at the renders**: the compositor breaks ja/zh at any character (kinsoku deliberately unimplemented), so it split あ/ります and 播/放 mid-word. The fit check passes those — only the eye catches them. | **done** |
| D5 | Caption-fit validation for iOS. `appstore-validate-copy` now measures the four iOS captions at the 1.9× headline scale against **both** iOS canvases, and rejects a subhead written into an iOS `screenshots.json` — it would render, laying that one locale out differently from the other 29. Matters more here than on macOS: at 1.9× with a two-line cap, a long translation shrinks to the 72% floor and then fails the build. The iPhone canvas binds — the iPad is wider relative to its type size. A missing **non-English** iOS `screenshots.json` is counted, not failed, until D4 lands. | **done** |

## E. Bundle details

| | Item | Status |
|---|---|---|
| E1 | `VibeWidget.appex` ships no `PrivacyInfo.xcprivacy`, and **should not** — answered rather than papered over. The **Release** widget binary was scanned for every symbol on Apple's required-reason lists (file timestamps, `UserDefaults`, boot time, disk space, active keyboards) and references none: it resolves the app-group container, enumerates it with `includingPropertiesForKeys:nil` and reads a plist. Adding the app's manifest would declare three categories the widget does not use. Recorded in `app-store-releasing.md` with what to re-check when the widget grows. | **done** |
| E2 | `UIFileSharingEnabled: true` **stays**, and is now documented as a product decision rather than reading half like a test-loop leftover. The app's Documents directory is a *permanent* search root (`SearchFolderStore`: no grant needed, so always a root and never a row); with sharing off, that root would have no way to get anything into it. Nothing of the app's own lives there — settings are in `NSUserDefaults`, caches in `Caches/` — so the user sees only what the user added. | **done** |
| E3 | iOS 26.0 minimum is a narrow install base — but it is **not a setting, it is what the code is built on**. Measured by lowering the floor to 18.0 and building: the app shell's mini player IS the iOS 26 tab-bar bottom accessory (`UITabAccessory` / `setBottomAccessory:animated:`, `RootViewController.m:374`), the search tab uses `automaticallyActivatesSearch`, and all three widget intents use `IntentModes` plus `continueInForeground(_:alwaysConfirm:)`. Supporting iOS 18 means a second mini-player implementation living above the tab bar on every screen, not a flag. Signed off: 1.12 ships to iOS 26 and later. | **done** |

## F. Review readiness

| | Item | Status |
|---|---|---|
| F1 | **A reviewer will open Vibe to an empty app.** Notes written to `Assets/app-store/review-notes.txt`: what the empty first launch means and that it is correct, the three ways to get audio in, the formats, why the widget shows a placeholder until the app has played once, background audio, and the privacy answer. Tracked because A5 needs the same text for Beta App Review Information. **Nothing uploads it** — paste it into ASC. The attachment it promises now exists: `Vibe-sample-track.mp4`, a tagged 30-second tone, because MP4 is the only media type ASC accepts on that field. Confirmed to open and play in the app, with its tags read and the widget picking up the title. | **done** |
| F2 | Background audio verified on a real device — lock-screen controls, Now Playing, playback with the screen off. Confirmed by hand; the simulator cannot answer this one. | **done** |
| F3 | Exercised on a genuinely clean install (a fresh session simulator, signed with `VIBE_SIGN_SIM=1` so the app group exists). The whole path holds: with no widget placed, `dump_state.widget.placed` is false and a **full track played end to end wrote nothing at all** to the shared container — the `widgetPlaced` gate is real, not incidental. The moment the extension first rendered (the widget gallery counts), its read signal flipped `placed` and the app republished at once: `state.plist` plus both waveform PNGs. Both sizes then tracked play, pause and seek, and tapping the widget's own pause button took the app from `playing` to `paused` with the snapshot republished to match. | **done** |

## G. Surrounding material

| | Item | Status |
|---|---|---|
| G1 | `docs/app-store-releasing.md` covered only the Mac App Store. Retitled and extended: Universal Purchase framing, the iOS prerequisites, the per-platform version-record trap, both build paths and their differences table, the iOS export postflights, TestFlight-vs-GitHub betas, what the reviewer sees, and four new troubleshooting entries. | **done** |
| G2 | The `vibe-release` skill described `release-appstore.sh` as the Mac App Store path. Rewritten: three-path table with the iOS column, Universal Purchase and the per-platform version record, TestFlight-vs-GitHub betas, the two `.ipa` postflights, the worktree `.release-env` trap, and the product-page section marked macOS-only. Its frontmatter description now names iOS, so the skill triggers on iOS release questions. | **done** |
| G3 | The page now carries iOS as a **companion**, not a second headline act: the hero, its three buttons and the schema's download URL stay the Mac app's, with one line under them ("Also on iPhone and iPad, in the same purchase"), and a closing section with a phone capture. Its App Store link deliberately **drops `?mt=12`** — the hero button forces the Mac listing, which an iPhone cannot install from. `schema.org` `operatingSystem` names both, since it is one app record. `github-release.sh` stays correct: it publishes mac DMG/zip only, and iOS ships through the store alone. | **done** |
| G4 | `README.md` and `CHANGELOG.md` framed for two platforms. CHANGELOG leads 1.12 with the iOS launch itself, which the `ios:` feature lines were burying. README's tagline names iPhone and iPad, and a new section carries three iPhone captures, what the phone app does, and — said plainly rather than left to be discovered — which features are Mac-only and why. | **done** |

---

## Notes and traps found along the way

- **`.release-env` does not exist in a git worktree.** It is gitignored, so it
  lives only in the checkout that created it, and every release script fails
  its credential preflight from anywhere else. Release from the main checkout,
  or pass `ASC_KEY_ID` / `ASC_ISSUER_ID` in the environment. This is why this
  work lives on `main` in the primary checkout rather than in a worktree.
- **macOS 1.11 was never submitted.** It sat at `PREPARE_FOR_SUBMISSION` with
  build 111 uploaded while the store served 1.10, so GitHub was a release ahead
  of the Mac App Store. Both platform records now read 1.12, and the macOS
  `whats-new.txt` — which was still the 1.11 notes — has been rewritten for
  1.12.
- **No iOS build had ever been uploaded** before this work — every TestFlight
  train on the record was `MAC_OS`.
- **The capture tooling was broken in two ways, both pre-existing.** The setup
  block issued a `--debug-cmd` right after `pkill`, so the appearance pin was
  written to a process that had just been ended; and #32 (2026-09-16) made
  `--isolated-desktop` mandatory on `input.swift` without updating
  `screenshot-lib.sh`, so every run since had died at its first cursor move.
  Fixed in `fed353d9`; global input is now a per-run `ALLOW_GLOBAL_INPUT=1`
  assertion rather than something a library claims on the caller's behalf.
- **Release notes are not a field on a platform's FIRST version.** Uploading
  the iOS page died on its first locale with `Attribute 'whatsNew' cannot be
  edited at this time`, having written nothing — while macOS, carrying the
  *same* 1.12 version string, has a train back to 1.7 and takes them normally.
  Universal Purchase makes that asymmetry the normal case for a new platform.
  Nothing on the version record says so; the only signal is that the platform
  has no other version. `ASCUpload.swift` now derives it up front and omits the
  attribute, since sending it *unchanged* is what ASC rejects.
- **A caption that passes the fit check can still read badly.** The compositor
  breaks ja/zh at any character (kinsoku deliberately unimplemented), so three
  translated headlines split mid-word — あ/ります and 播/放 — and every one of them
  validated clean. Look at the renders for the CJK locales; nothing mechanical
  catches this.
- **A build takes minutes to appear in App Store Connect, and `UPLOAD
  SUCCEEDED` is about bytes, not registration.** The 112 upload ended with two
  warnings — `buildUploadFiles` timing out (-1001) and "Skipping validation"
  — and the API still showed 111 as the newest build six minutes later. It
  appeared, `VALID`, at about eight. Do not read an absent build as a failed
  delivery and re-upload: the build number would be burnt for nothing. Query
  until it appears, or wait.
- **`curl` eats `filter[app]=…` silently.** `[` and `]` are curl's own
  URL-glob syntax, so an unescaped ASC filter query returns an EMPTY body and
  exit 0 — no error, no warning, and a poll built on it reports "not there
  yet" forever whatever the truth. Pass `-g`/`--globoff`, or backslash the
  brackets.
- **`codesign -d --entitlements` reads empty on a simulator build.** It shows
  the signature's entitlements, and a simulator build carries its effective
  ones in the binary's `__TEXT,__entitlements` section instead (the
  `*-Simulated.xcent` the linker embeds). Reading the signature and concluding
  `VIBE_SIGN_SIM=1` did nothing is a wrong turn; the honest check is whether
  `simctl get_app_container <udid> <bundle-id> groups` resolves.
- **An unsigned simulator build cannot show the widget working.** `make
  build-ios` passes `CODE_SIGNING_ALLOWED=NO`, which drops the entitlements,
  which means no app-group container, which means the widget never sees a
  snapshot and sits on its placeholder forever. It reads exactly like a
  product bug. `VIBE_SIGN_SIM=1` signs ad-hoc with entitlements intact and is
  what the screenshot loop needs.
- **`set -o pipefail` plus a consumer that exits early is a landmine.** Both
  `unzip -l … | grep -q` in the release postflights and `… | head -5` in the
  screenshot generator killed their producer with SIGPIPE and failed the run,
  the second one silently truncating an iPad loop mid-way. Capture the output
  to a variable first, then filter it.
- The iOS app uses **no permission-gated APIs and does no networking**, so App
  Privacy stays "no data collected", there are no usage-description strings to
  write, and `ITSAppUsesNonExemptEncryption: false` means no per-build export
  compliance question.
