# Future: macOS 13 (Ventura) support

Written 2026-08-20; Phases 1–3 implemented the same day on branch `ios-app`. **Phase 4 (App Store copy retranslation) remains open** and is release-time work. The file:line anchors below are against `6e7da8d` and predate the implementation — treat them as history, not targets.

Read the root `CLAUDE.md` (the equalizer guarantees especially), `Vibe/Controls/CLAUDE.md`, and `Vibe/Audio/Levels/CLAUDE.md` first; verification needs the `vibe-debug` skill, and Phase 4 the `vibe-strings` skill.

## The finding: one API blocks macOS 13

Audited by running the compiler as ground truth, not by grep: `clang -fsyntax-only -mmacosx-version-min=13.0 -Wunguarded-availability -Wunguarded-availability-new` (macOS 26 SDK, the prefix header preincluded) over all 143 non-iOS, non-ThirdParty `.m`/`.mm` sources and all 66 test sources, once plain and once with `-DDEBUG=1`. Do not re-audit; re-run that sweep instead if the tree has moved far from the anchor commit.

The complete list of macOS 14-only usage is **`CADisplayLink` in `Vibe/Controls/EqualizerIndicatorView.m`** — the class itself (`API_AVAILABLE(macos(14.0))`) and `-[NSView displayLinkWithTarget:selector:]` that mints it. Sites: the ivar (`:67`), creation (`:350`), `preferredFrameRateRange` (`:357`), the `levelTick:` signature (`:459`).

Everything else is already clean at 13.0:

- Now Playing (`Vibe/System/NowPlayingController.m`) uses only `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` / `MPMediaItemArtwork`, all macOS 10.12-era. No `MPNowPlayingSession`.
- Every SF Symbol name in use (7 `imageWithSystemSymbolName:` sites) is SF Symbols 4 or earlier. Symbol names are strings the compiler cannot check — the one class of risk needing a manual eyeball on a Ventura box.
- Existing `@available` guards all target 15.0 (`AudioFileConverter.m:559`, `-[AVAudioFile close]`) or 26.0 (the Liquid Glass chrome), each with a working fallback; none relax at a 13.0 floor.
- `NSView.clipsToBounds` is a linked-SDK behavior change, not a deployment-target one; the single setter site (`PlaylistDropZoneView.m:95`) is explicit anyway.
- CoreAudio HAL (`Audio/Mac/Devices/`), AVAudioEngine, Metal (About window), the entitlements, and all tests: clean.

## Containment constraints (decided here)

1. **All macOS 13-specific code lives in one branch of one method**: the `else` of `if (@available(macOS 14.0, *))` inside `startLevelLink`. No new files, no poller class, no protocol seam. Re-raising the floor later is deleting that `else` branch and re-tightening the ivar type — nothing more.
2. **The display link is the implementation; the timer is a fallback.** The 14+/iOS path stays byte-for-byte what it is today, and the fallback can never execute on 14+ — the branch shape guarantees it, never a runtime flag.
3. **Findability is structural.** This becomes the tree's only `@available(macOS 14` guard, and every version-specific path in the codebase already sits behind `@available(macOS …)` — so `grep -rn '@available(macOS' Vibe` remains the complete inventory of platform-version code. Keep it true: no `#if`, no OS-version `NSProcessInfo` checks.

## Phase 1 — the fallback poller (`Vibe/Controls/EqualizerIndicatorView.m`)

Why a timer is equivalent: the link *only polls* the level snapshot and staleness clock at 20–30 Hz — Core Animation, not the callback, moves the bars (`Controls/CLAUDE.md`'s guarantee). Display sync buys nothing.

Why not `CVDisplayLink`: callbacks arrive off-main, it is deprecated in macOS 15 (so it would need the opposite availability guard), and `Vibe/Mac/About/AboutWindowController.m:179` records that CVDisplayLink loops do not reliably resume in this app — disqualifying for a table-cell indicator that starts and stops constantly.

The change:

- Ivar `CADisplayLink *_levelLink` (`:67`) → `id _levelLink`. Both `CADisplayLink` and `NSTimer` answer `invalidate`, so `stopLevelLink` (`:362`) is unchanged.
- `startLevelLink` (`:336`): the `TARGET_OS_OSX` arm becomes

  ```objc
  if (@available(macOS 14.0, *)) {
      _levelLink = [self displayLinkWithTarget:proxy selector:@selector(levelTick:)];
  } else {
      // macOS 13 fallback. The link only polls; a tolerant timer at the same
      // bounded rate is equivalent — Core Animation owns the motion.
      NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 25.0 target:proxy
                                             selector:@selector(levelTick:)
                                             userInfo:nil repeats:YES];
      timer.tolerance = 0.015;
      _levelLink = timer;
  }
  ```

  with `preferredFrameRateRange` (`:357`) moved inside the display-link branch, and the common `addToRunLoop:`/`addTimer:` registration on `NSRunLoopCommonModes` split per kind (the selectors differ). The iOS arm is untouched.
- `levelTick:` (`:459`) takes `id` and reads `CACurrentMediaTime()` instead of `link.timestamp` — valid on both paths; the timestamp feeds only the staleness clock.
- The debug counters (`sActiveDisplayLinks`, `sTotalDisplayTicks`) count the poller whatever its kind; only their names age, and renaming is optional.

**Acceptance**: `make build CONFIG=Debug`, `make build-ios` (shared file, both targets), `make test`.

## Phase 2 — the floor itself

- `project.yml:6` (`options.deploymentTarget.macOS`), `:92` (settingGroup `MACOSX_DEPLOYMENT_TARGET`), `:308` (the `Vibe` target override): `"14.0"` → `"13.0"`, then `xcodegen generate`.
- `LSMinimumSystemVersion` (`project.yml:220`) interpolates `$(MACOSX_DEPLOYMENT_TARGET)` — no edit.
- `CLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE` (`project.yml:74`) stays; it is what enforces the new floor against future code.
- CI needs no change — every job runs `macos-26` and back-deploys; only the rationale comment at `.github/workflows/build.yml:19-20` goes stale (update it).
- Release scripts, notarization, entitlements: audited, no version pins.

**Acceptance**: `make build`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`.

## Phase 3 — prose stating the floor

- Root `CLAUDE.md:153` ("Deployment targets are macOS 14.0…") and the equalizer guarantee's "one local `CADisplayLink`" wording → "one local poller — a display link on macOS 14+/iOS, a timer fallback on macOS 13".
- `Vibe/Controls/CLAUDE.md` — same `CADisplayLink` wording in the `EqualizerIndicatorView` section.
- `CONTRIBUTING.md:29` ("macOS 14 or later to run").
- `Vibe/Mac/MainWindow/APPEARANCE.md:17` ("the deployment target is 14.0").
- `docs/future/waveform-drag-behavior.md:34` (calls 14 "the deployment floor").
- `CHANGELOG.md` — the 26→14 lowering shipped in v1.9 (tagged), so that entry is history; a new "macOS 13 Ventura" bullet goes under the in-progress `1.10`.

## Phase 4 — App Store copy (release-time, not part of the code landing)

All 30 `Assets/app-store/copy/<lang>/whats-new.txt` files open with a translated "Now runs on macOS 14 Sonoma and later" and must be retranslated to say macOS 13 Ventura before the next `make appstore-upload-metadata`. Nothing flags them: `appstore-validate-copy.sh` has no version assertion. Follow the `vibe-strings` skill's translation conventions and terminology.

## Verification

- The full gate set: `make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make build-ios`.
- `vibe-debug`: play a track, screenshot the playlist — bars animate on the current OS (the preferred path), and stop cleanly when playback stops.
- The fallback path without Ventura hardware: locally invert the `@available` condition, rebuild, and repeat the same drive — bars animate, the poller starts and stops in balance (the debug channel's equalizer counters), release-to-dots still runs. Revert the inversion.
- **No CI leg runs macOS 13.** The floor itself — launch, playback, the timer poller, every SF Symbol resolving — is a manual check on a real Ventura install or VM before any release claims support.
