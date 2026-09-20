# iOS App Store release punchlist

Vibe has shipped to the Mac App Store since 1.0; **1.12 is the first release
that also ships the iOS app.** This is the list of what that first time needs
that a mac release does not. It is a living document — update the status
column as items land, and delete the file once iOS releases are routine and
`app-store-releasing.md` covers everything on its own.

Status: **done** · **blocked** (waiting on another item) · **open**.

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
| A5 | Beta path. No iOS build has ever been uploaded; the only group is the auto-created internal "App Store Connect Users", and TestFlight Test Information is empty. Plan: internal TestFlight first (no beta review, minutes after processing), external once the copy is closer. Needs a feedback email set; external additionally needs a beta description and Beta App Review Information — write it once and reuse it for F1. | **open** |
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
| C5 | `ASCUpload.swift` takes `--platform macos\|ios`, threaded through version filtering, version creation, the copy directory and the screenshot display type. iOS's display type is deliberately `nil` — which iPhone type ASC now accepts is unresolved (D3) and there are no files yet — so iOS requires `--skip-screenshots` and says so rather than uploading an empty set. Verified against the live iOS 1.12 record by dry run. | **done** |

## D. Screenshots

| | Item | Status |
|---|---|---|
| D0 | The macOS shot set was reworked in passing: `keys` (keyboard shortcuts) replaced by `themes`, `pitch` moved to the compact capture, one built-in theme per shot, and window sizes pinned instead of inherited from the autosaved frame. Not iOS work, but it is why C2 has a caption to translate. | **done** |
| D1 | There is no iOS screenshot pipeline. `appstore-generate-store-screenshots.sh` composites *macOS window captures* onto a 2880×1800 canvas. The building blocks exist: `xcrun simctl io <udid> screenshot` for ground-truth pixels, and the `vibe-debug` channel to stage the app before each shot. | **open** |
| D2 | iPad screenshots are **required** — `TARGETED_DEVICE_FAMILY` is `1,2`. | **open** |
| D3 | **Resolved against Apple's own API.** A deliberately invalid POST made ASC enumerate the valid `screenshotDisplayType` values: `APP_IPHONE_67` and `APP_IPAD_PRO_3GEN_129` are both there and **`APP_IPHONE_69` does not exist at all** — so the pinned Bagbutik 24.0.3 needs no bump (upstream has nothing newer either; 24.0.3 is the latest tag). Targets are **iPhone 6.7\" = 1290x2796** and **iPad 12.9\" = 2048x2732**, and simulators exist at exactly those sizes: `iPhone 16 Plus` and `iPad Pro (12.9-inch) (6th generation)`. | **done** |
| D4 | New captions × 29 languages. The four macOS shot ids (`player`, `playlist`, `pitch`, `keys`) do not map to iOS — there is no pitch fader and no keyboard shortcuts. Think playlist / now-playing card / favorites / widget. | **blocked** on D1 |
| D5 | The caption-fit validator (`compose-app-store-overlay.swift --measure`) is sized for the macOS canvas; it needs iOS geometry or the fit check means nothing. | **blocked** on D1 |

## E. Bundle details

| | Item | Status |
|---|---|---|
| E1 | `VibeWidget.appex` ships no `PrivacyInfo.xcprivacy` — confirmed absent from the built bundle. Probably not required (the widget uses no required-reason APIs: no `UserDefaults`, no file-timestamp reads, just the app-group container and a plist read), but adding it to the widget's sources is nearly free and removes the question. | **open** |
| E2 | Confirm `UIFileSharingEnabled: true` is a deliberate ship decision — it exposes the app's Documents folder to users in the Files app. The comment says it is for open-in-place *and* the simulator test loop; make it a choice, not a leftover. | **open** |
| E3 | iOS 26.0 minimum is a narrow install base. Worth a conscious sign-off rather than discovering it in the reviews. | **open** |

## F. Review readiness

| | Item | Status |
|---|---|---|
| F1 | **A reviewer will open Vibe to an empty app.** No bundled library, no streaming — the model is "the current directory is the playlist". Without review notes explaining how to get audio in (Files tab, open-in-place from the share sheet, a file dropped into the Vibe folder), this is the likeliest rejection. Consider attaching a sample track. Same content as A5's Beta App Review Information. | **open** |
| F2 | Verify background audio on a real device, not the simulator: lock-screen controls, Now Playing, playback with the screen off. `UIBackgroundModes: [audio]` is a claim review exercises. | **open** |
| F3 | Exercise the widget on a clean install before submitting — the app-group container is empty until the app publishes its first snapshot, which is exactly the state a reviewer hits. | **open** |

## G. Surrounding material

| | Item | Status |
|---|---|---|
| G1 | `docs/app-store-releasing.md` covered only the Mac App Store. Retitled and extended: Universal Purchase framing, the iOS prerequisites, the per-platform version-record trap, both build paths and their differences table, the iOS export postflights, TestFlight-vs-GitHub betas, what the reviewer sees, and four new troubleshooting entries. | **done** |
| G2 | The `vibe-release` skill described `release-appstore.sh` as the Mac App Store path. Rewritten: three-path table with the iOS column, Universal Purchase and the per-platform version record, TestFlight-vs-GitHub betas, the two `.ipa` postflights, the worktree `.release-env` trap, and the product-page section marked macOS-only. Its frontmatter description now names iOS, so the skill triggers on iOS release questions. | **done** |
| G3 | `Assets/Web/index.html` is macOS-only (one App Store badge, five "macOS" mentions). Decide whether the page advertises iOS. `github-release.sh` stays correct — it publishes mac DMG/zip only, and iOS ships through the store alone. | **open** |
| G4 | `README.md` and `CHANGELOG.md` framing for a two-platform release. | **open** |

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
- The iOS app uses **no permission-gated APIs and does no networking**, so App
  Privacy stays "no data collected", there are no usage-description strings to
  write, and `ITSAppUsesNonExemptEncryption: false` means no per-build export
  compliance question.
