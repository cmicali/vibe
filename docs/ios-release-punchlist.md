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

## C. Product-page copy

The largest remaining block. ASC localizations hang off a version and versions
are per platform, so **iOS needs its own copy in all 29 languages** — none of
it auto-translates.

| | Item | Status |
|---|---|---|
| C1 | Write the iOS description, keywords and promotional text. The macOS copy cannot be reused: it sells BPM and key analysis, the pitch fader and the FX rack — all macOS-only — and says formats are "decoded by macOS". The `converter` and `winamp` keywords are mac-only too. A page describing features the app lacks is a review rejection. | **open** |
| C2 | Translate that copy into all 29 catalog languages. | **blocked** on C1 |
| C3 | Decide the on-disk layout (a parallel `copy-ios/<lang>/`, or a `macos/`+`ios/` split per language) and teach `appstore-validate-copy.sh`, `appstore-upload-metadata.sh` and the `Assets/app-store/README.md` about it. | **open** |
| C4 | `whats-new.txt` still holds the **1.11** notes. Needed fresh for 1.12 in all 29 languages, both platforms — ASC blocks submission when a locale lacks release notes, and stale notes upload silently. | **open** |
| C5 | Teach `ASCUpload.swift` about iOS: `filters: [.platform([.macOS])]` and `attributes: .init(platform: .macOS, …)` are hardcoded, as is the `.appDesktop` screenshot set. Wants a `--platform` threaded through. | **open** |

## D. Screenshots

| | Item | Status |
|---|---|---|
| D1 | There is no iOS screenshot pipeline. `appstore-generate-store-screenshots.sh` composites *macOS window captures* onto a 2880×1800 canvas. The building blocks exist: `xcrun simctl io <udid> screenshot` for ground-truth pixels, and the `vibe-debug` channel to stage the app before each shot. | **open** |
| D2 | iPad screenshots are **required** — `TARGETED_DEVICE_FAMILY` is `1,2`. | **open** |
| D3 | Pick display types. Trap: the pinned Bagbutik (24.0.0) `ScreenshotDisplayType` tops out at `APP_IPHONE_67` — there is no `APP_IPHONE_69`. Verify ASC still accepts a 6.7" (1290×2796) set for a new iOS version; if it demands 6.9", bump Bagbutik or patch the enum and render 1320×2868. iPad is `APP_IPAD_PRO_3GEN_129`. | **open** |
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
  of the Mac App Store. Both platform records now read 1.12.
- **No iOS build had ever been uploaded** before this work — every TestFlight
  train on the record was `MAC_OS`.
- The iOS app uses **no permission-gated APIs and does no networking**, so App
  Privacy stays "no data collected", there are no usage-description strings to
  write, and `ITSAppUsesNonExemptEncryption: false` means no per-build export
  compliance question.
