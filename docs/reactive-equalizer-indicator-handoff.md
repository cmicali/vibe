# Handoff: the audio-reactive equalizer indicator

Written 2026-08-18. **The feature is implemented and pushed; it has never been compiled.** This file is the pickup point for whoever takes it to green.

Branch `claude/live-eq-animation`, two commits on top of `ios-app` at `ca124c8`:

```
15aebb1 git: ignore Claude Code worktrees
e39e705 ios: make the equalizer indicator follow the audio
```

It replaces `docs/future/reactive-equalizer-indicator.md`, which was the plan and is deleted in `e39e705`. Re-check every file:line below before trusting it — `AudioPlayer.m` moves often.

## What it does

The library row's playing indicator ran canned keyframe tables on both platforms. On iOS it now follows the audio: a tap on `mainMixerNode` bus 0 publishes five log-spaced band levels at the FFT hop rate, and `EqualizerIndicatorView` eases them onto its bars per displayed frame.

macOS is untouched — `levelSource` is nil there, so the keyframe path is bit for bit what it was.

## Why the design is what it is

Three decisions that will look arbitrary otherwise, and should not be undone casually.

**The tap point.** `mainMixerNode` bus 0 is exactly the signal reaching the speaker *only while the FX segment is absent*, which is what `enableFX:NO` gives the iOS player: post-fade, post-varispeed, and the crossfade sum comes free because both chains already meet at that mixer. With FX on — macOS — the reverb and delay returns re-enter downstream of it, so the same tap would miss every wet tail. That is the real reason this is iOS-only, beyond scope.

**Smoothing lives in the view, not the tap.** The tap publishes instantaneous levels and smooths nothing. Motion is therefore tied to the display rather than the hop rate, and a tap that stops firing — the engine's deferred idle stop takes it a few seconds after a pause — decays gracefully instead of freezing mid-pose.

**Levels are demand-driven, not a constructor flag.** `AudioPlayer.levelsEnabled` is set from the two gates the position tick already uses (playing, and foreground), so nothing is spent while backgrounded. A lifetime flag beside `enableFX` could not do that.

## The files

**New:** `Vibe/Audio/AudioLevelMath.h`, `Vibe/Audio/AudioLevelTap.{h,m}`, `Tests/AudioLevelMathTests.m`.

**Modified:** `Vibe/Audio/AudioPlayer.{h,m}`, `Vibe/Audio/AudioPlayerInternal.h`, `Vibe/Controls/EqualizerIndicatorView.{h,m}`, `Vibe/iOS/PlaybackController.{h,m}`, `Vibe/iOS/LibraryViewController.m`, `Vibe/Debug/iOS/{DebugCommands.m,RootViewController+Debug.{h,m}}`, plus the root, `Audio/` and `iOS/` `CLAUDE.md`s.

No `project.yml` change: `Vibe/Audio` and `Vibe/Controls` are already source entries on both targets, and `Vibe/Audio` is already on the `VibeTests` header search path.

## Verification status — read this before reporting anything as working

| Gate | State |
| --- | --- |
| `make check-layout` | **passes** |
| `make check-vocabulary` | **passes** |
| `AudioLevelMath.h` arithmetic | **verified**, 45 assertions, 0 failures — but see below |
| `make build` (macOS) | **NEVER RUN** |
| `make build-ios` | **NEVER RUN** |
| `make test` | **NEVER RUN** |
| `make analyze CONFIG=Release` | **NEVER RUN** |
| Anything against a running app | **NEVER RUN** |

The math was verified by compiling `AudioLevelMath.h` as plain C against a Foundation shim on Linux and running the same assertions `Tests/AudioLevelMathTests.m` makes — the authoring environment had no Xcode. That harness caught a real bug (adjacent bands overlapped by a bin, so one bin drove two bars; fixed by `VibeLevelBandEdgeBin`, which both ends of a band now share) and two wrong assertions. **`Tests/AudioLevelMathTests.m` itself has never been run by XCTest.** It is expected to pass; treat a failure there as a suite/compile problem first, not as a math problem.

## Do this first

1. `make build-ios CONFIG=Debug` and `make build`. **Expect to fix compile errors** — nothing here has met a compiler.
2. `make test`. `AudioLevelMathTests` is new.
3. `make analyze CONFIG=Release` — CI gates on Release, and this adds a `malloc`/`free` pair and a raw pointer captured by a block, which is exactly what the analyzer has opinions about.
4. Runtime, per the section below.

### Where a compiler is most likely to complain

- **`[self displayLinkWithTarget:selector:]` in `EqualizerIndicatorView.m`.** `CADisplayLink`'s class constructor is UIKit-only; a mac link is minted from the view, and that method is macOS 14.0 — the deployment floor exactly. `CLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE` is on, so if the floor ever moves down this needs an `@available`.
- **Cross-directory imports.** `Vibe/Controls/EqualizerIndicatorView.m` imports `AudioLevelMath.h` (from `Vibe/Audio/`) and `VibeWeakProxy.h` (from `Vibe/Util/`), relying on Xcode's project-wide headermap rather than a search path. Both are shared directories, so neither breaks the platform-boundary rule, but a headermap miss shows up here first.
- **`_Atomic float` and `atomic_store_explicit`** in `AudioLevelTap.m` — C11 in an ObjC TU.
- **`LibraryTrackCell.levelSource`** implements both accessors and deliberately has no ivar; it forwards to the indicator.

## Runtime verification

**TRAP: `launch-ios.sh` passes `--silent` by default, and it makes every band read exactly 0.** `--silent` zeroes `mainMixerNode.outputVolume` and the tap is downstream of that, so a normal debug run shows flat bars and a screenshot cannot tell that from broken. This is not a bug to fix by moving the tap: upstream of the mute is upstream of the mixer, which means per-track and re-plumbed on every crossfade. `--no-audio-hw` is fine — its pump still renders, so the tap still fires.

So: launch **without `--silent`**, then

1. `debug-ios.sh dump_levels` repeatedly while a track plays. `levelsEnabled` true, `published` true, and the five `bands` values differing and moving. The reply carries `silent` so a flat run explains itself.
2. Compare a bass-heavy track against a sparse one — band 0 and band 4 should behave visibly differently. That difference is the entire point of doing this rather than driving all five bars from amplitude.
3. Screenshot the library for the look.
4. Pause → bars settle to the dot pose. Scroll the playing row off and back → it reattaches (`didMoveToWindowShared`).
5. Background while playing → `levelsEnabled` goes false, nothing spent.
6. macOS: the table indicator is unchanged and still runs keyframes.
7. **Measure the CPU claim rather than asserting it.** The keyframe path costs zero per frame because Core Animation runs it on the render server, and this gives that up. Xcode's gauge, library visible and playing, against the same build with `levelsEnabled` forced false. A 1024-point real FFT ~47 times a second should be far under 0.1% of one core, but the number is the point.

## If it works but looks wrong

Every knob is in `AudioLevelMath.h`, and each is one line:

- bars slam to the floor between hits → `kLevelDynamicRangeDB` too narrow, or `kLevelReleaseSeconds` too short
- bars twitch in quiet passages → range too wide, or `kLevelReferenceFloor` too low
- treble bars dead → the per-band AGC is not doing its job; check `VibeLevelBandBinRange` against the delivered sample rate
- motion reads as the canned loop with a wobble → a keyframe animation survived alongside the reactive path; `startLevelLink` is what removes it

## Known accepted costs

- With the now-playing card covering the library, that one row's display link still runs. Five CALayer transform writes on one offscreen view was judged not worth machinery to suppress; backgrounding stops both link and tap anyway.
- `AudioLevelTap`'s scratch buffers are freed in `dealloc` rather than in `remove`, so a concurrent display-rate reader holding it through the atomic property cannot touch freed memory. Freeing in `remove` would need a lock on that path.
