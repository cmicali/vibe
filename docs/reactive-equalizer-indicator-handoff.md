# Handoff: the audio-reactive equalizer indicator

Written 2026-08-18, **taken to green the same day** — every gate below now passes and the
feature has been verified against both running apps. Kept because the design rationale, the
traps and the tuning knobs are still the reference; the verification table records what was
actually run rather than what was hoped.

Branch `claude/live-eq-animation`, on top of `ios-app` at `ca124c8`.

It replaces `docs/future/reactive-equalizer-indicator.md`, which was the plan and is deleted in `e39e705`. Re-check every file:line below before trusting it — `AudioPlayer.m` moves often.

## What it does

The library row's playing indicator ran canned keyframe tables on both platforms. On iOS it now follows the audio: a tap on `mainMixerNode` bus 0 publishes five log-spaced band levels at the FFT hop rate, and `EqualizerIndicatorView` eases them onto its bars per displayed frame.

macOS followed later, from the same FFT tapped at a different node — see the tap-point section, which was written when this was iOS-only and is now the rule for both.

## Why the design is what it is

Three decisions that will look arbitrary otherwise, and should not be undone casually.

**The tap point.** `mainMixerNode` bus 0 is exactly the signal reaching the speaker *only while the FX segment is absent*, which is what `enableFX:NO` gives the iOS player: post-fade, post-varispeed, and the crossfade sum comes free because both chains already meet at that mixer. With FX on — macOS — the reverb and delay returns re-enter downstream of it, so the same tap would miss every wet tail. That is why the tap point is chosen per graph rather than fixed: `AudioFX.masterBusOutputNode` is the node on macOS, `mainMixerNode` where there is no FX segment, and `applyLevelTapOnQueue` picks. It was iOS-only until that was resolved.

**Smoothing lives in the view, not the tap.** The tap publishes instantaneous levels and smooths nothing. Motion is therefore tied to the display rather than the hop rate, and a tap that stops firing — the engine's deferred idle stop takes it a few seconds after a pause — decays gracefully instead of freezing mid-pose.

**Levels are demand-driven, not a constructor flag.** `AudioPlayer.levelsEnabled` is set from the two gates the position tick already uses (playing, and foreground), so nothing is spent while backgrounded. A lifetime flag beside `enableFX` could not do that.

## The files

**New:** `Vibe/Audio/AudioLevelMath.h`, `Vibe/Audio/AudioLevelTap.{h,m}`, `Tests/AudioLevelMathTests.m`.

**Modified:** `Vibe/Audio/AudioPlayer.{h,m}`, `Vibe/Audio/AudioPlayerInternal.h`, `Vibe/Controls/EqualizerIndicatorView.{h,m}`, `Vibe/iOS/PlaybackController.{h,m}`, `Vibe/iOS/LibraryViewController.m`, `Vibe/Debug/iOS/{DebugCommands.m,RootViewController+Debug.{h,m}}`, plus the root, `Audio/` and `iOS/` `CLAUDE.md`s.

No `project.yml` change: `Vibe/Audio` and `Vibe/Controls` are already source entries on both targets, and `Vibe/Audio` is already on the `VibeTests` header search path.

## Verification status — read this before reporting anything as working

| Gate | State |
| --- | --- |
| `make check-layout` | passes |
| `make check-vocabulary` | passes |
| `make build` (macOS) | passes, no warnings |
| `make build-ios` | passes, no warnings |
| `make test` | passes — 694 cases, `AudioLevelMathTests` included |
| `make analyze CONFIG=Release` | clean, both targets |
| Runtime, iOS simulator | verified — see below |
| Runtime, macOS | builds and runs; keyframe path unchanged by construction (see the layout trap) |

Nothing in the original diff failed to compile. Three defects were found *after* it compiled,
all of them invisible to a compiler and to the host-less suite:

1. **`copyBandLevels:count:` was declared in the `(State)` category but implemented in the
   main `@implementation`** — an `-Wincomplete-implementation` warning on both targets. It
   never belonged in `(State)`, which is documented as taking the state lock; this one is
   lock-free via the atomic `levelTap`. Moved beside `levelsEnabled`, the property that arms it.
2. **`kLevelReferenceFloor` was three orders of magnitude below the noise it exists to
   reject** — see the section below.
3. **`layoutBars` hardcoded the collapsed pose**, which on iOS silently defeated the whole
   feature — see the section below.

The math was originally verified by compiling `AudioLevelMath.h` as plain C against a Foundation shim on Linux and running the same assertions `Tests/AudioLevelMathTests.m` makes — the authoring environment had no Xcode. That harness caught a real bug (adjacent bands overlapped by a bin, so one bin drove two bars; fixed by `VibeLevelBandEdgeBin`, which both ends of a band now share) and two wrong assertions. The suite now runs under XCTest and passes.

## The two defects the gates could not have caught

Both were found by measuring the running app, and both are the kind of bug that ships looking
fine: the feature was *on*, the tap was publishing, and nothing logged an error.

### The reference floor sat below the noise floor

`kLevelReferenceFloor` was `1e-7`. Measured 16-bit quantization noise is `1e-7..5e-7` in the
unnormalized magnitude-squared units the tap works in — so the floor never engaged, and the
per-band AGC divided each signal-free band by its own hiss. On a pure 220 Hz tone the two
**emptiest** bands published the **highest** levels: bands 3 and 4 averaged 0.979 and 0.990
against 0.669 for the band actually carrying the tone, whose energy was ten orders of
magnitude greater. Five bars pinned near full scale is exactly the "drive them all from
amplitude" look the feature exists to avoid.

Raised to `1e-2`, measured against the sweep in the commit message: signal-free bands read
0.000, and the band carrying the tone holds 0.669 unchanged down to -60 dBFS, so the AGC's
"a quiet track still moves its bars" property survives. Two tests pin both halves.

**Re-measure it if `kFrameSize` changes** — it is an absolute energy in unnormalized FFT
units, which is why the constant carries a `TRAP:`.

### `layoutBars` clobbered the reactive pose every frame

It ended with a hardcoded `bar.transform = CATransform3DMakeScale(1, collapsed, 1)`. On macOS
that is harmless — the row lays out once, and collapsed is the model value the keyframes
animate around. On iOS a table cell lays out on **every displayed frame** (measured: 377
`layoutBars` calls in 6 seconds), and `layoutSubviews` runs after the display link's write, so
the reactive value was overwritten before it could ever render. The bars sat at exactly the
dot pose while the tap published perfectly good levels — and `startLevelLink` early-returns
when the link already exists, so nothing re-applied them.

`layoutBars` now settles the **current** pose by calling `applyBarScales`, which resolves to
exactly `collapsed` while no link is running. macOS is therefore unchanged by construction:
same model value, same write.

**This is why a screenshot was worth taking.** `dump_levels` reported healthy, differentiated
bands the whole time. Only pixels showed the bars were dead — and note that macOS's
`dump_screenshot` renders the *model* tree on glass-bearing windows, so it structurally cannot
show the keyframe animation and must not be used to judge that path.

### Where a compiler was most likely to complain (all clean)

- **`[self displayLinkWithTarget:selector:]` in `EqualizerIndicatorView.m`.** `CADisplayLink`'s class constructor is UIKit-only; a mac link is minted from the view, and that method is macOS 14.0 — the deployment floor exactly. `CLANG_WARN_UNGUARDED_AVAILABILITY: YES_AGGRESSIVE` is on, so if the floor ever moves down this needs an `@available`.
- **Cross-directory imports.** `Vibe/Controls/EqualizerIndicatorView.m` imports `AudioLevelMath.h` (from `Vibe/Audio/`) and `VibeWeakProxy.h` (from `Vibe/Util/`), relying on Xcode's project-wide headermap rather than a search path. Both are shared directories, so neither breaks the platform-boundary rule, but a headermap miss shows up here first.
- **`_Atomic float` and `atomic_store_explicit`** in `AudioLevelTap.m` — C11 in an ObjC TU.
- **`LibraryTrackCell.levelSource`** implements both accessors and deliberately has no ivar; it forwards to the indicator.

## Runtime verification

**TRAP: `launch-ios.sh` passes `--silent` by default, and it makes every band read exactly 0.** `--silent` zeroes `mainMixerNode.outputVolume` and the tap is downstream of that, so a normal debug run shows flat bars and a screenshot cannot tell that from broken. This is not a bug to fix by moving the tap: upstream of the mute is upstream of the mixer, which means per-track and re-plumbed on every crossfade. `--no-audio-hw` is fine — its pump still renders, so the tap still fires.

**The touch driver re-arms this trap.** `drive-ios.sh` relaunches the app with the
audio-silencing flags, so a `drive-ios.sh start` — or any gesture that finds the app dead —
silently puts `--silent` back and every band returns to 0. Re-launch by hand
(`simctl launch <udid> <bundle> --no-audio-hw`) after driving, and check the `silent` field in
the reply rather than trusting the launch you remember.

So: launch **without `--silent`**, then

1. `debug-ios.sh dump_levels` repeatedly while a track plays. `levelsEnabled` true, `published` true, and the five `bands` values differing and moving. The reply carries `silent` so a flat run explains itself.
2. Compare a bass-heavy track against a sparse one — band 0 and band 4 should behave visibly differently. That difference is the entire point of doing this rather than driving all five bars from amplitude.
3. Screenshot the library for the look.
4. Pause → bars settle to the dot pose. Scroll the playing row off and back → it reattaches (`didMoveToWindowShared`).
5. Background while playing → `levelsEnabled` goes false, nothing spent.
6. macOS: the table indicator is unchanged and still runs keyframes.
7. **Measure the CPU claim rather than asserting it.** The keyframe path costs zero per frame because Core Animation runs it on the render server, and this gives that up. A 1024-point real FFT ~47 times a second should be far under 0.1% of one core, but the number is the point.

### The measured numbers

Debug build, iPhone simulator, sustained 220 Hz tone playing, library visible with the card
minimized, bars actively moving. Average CPU over three 20s windows, from cumulative CPU-time
deltas — **not** `ps %cpu`, which averages over the whole process lifetime and hides the effect.
The baseline is the same build with `levelSource` nil and `levelsEnabled` forced NO, which is
the pre-feature behaviour exactly: canned keyframes, no tap.

| State | CPU (one core) |
| --- | --- |
| Baseline — keyframes, no tap | 1.75% |
| Tap only — FFT running, view on keyframes | 1.80–1.85% |
| Full feature — tap + reactive bars | 1.80–1.95% |

**The whole feature costs about 0.1 of a percentage point of one core**, and the FFT is the
cheaper half of it. The claim holds.

**TRAP: measure with the card MINIMIZED and say so.** The expanded now-playing card renders
its own waveform and playhead and costs ~4% by itself, which swamps the indicator and reads as
a catastrophic regression. An early reading here did exactly that before the card state was
controlled for.

Release could not be A/B'd this way: the debug command channel and the `--silent` /
`--no-audio-hw` flags all compile out of Release, so a Release build can be neither driven nor
kept quiet. Debug is the pessimistic case for the view half anyway.

## If it works but looks wrong

Every knob is in `AudioLevelMath.h`, and each is one line:

- bars slam to the floor between hits → `kLevelDynamicRangeDB` too narrow, or `kLevelReleaseSeconds` too short
- bars twitch in quiet passages, or a band with no content reads bright → range too wide, or `kLevelReferenceFloor` too low. This one actually happened; see the defects section above before turning the knob
- treble bars dead → the per-band AGC is not doing its job; check `VibeLevelBandBinRange` against the delivered sample rate
- motion reads as the canned loop with a wobble → a keyframe animation survived alongside the reactive path; `startLevelLink` is what removes it

## Known accepted costs

- With the now-playing card covering the library, that one row's display link still runs. Five CALayer transform writes on one offscreen view was judged not worth machinery to suppress. **The FFT behind it is no longer in that bargain**: the tap is now switched by counted indicator demand plus the shell's `levelsOccluded`, so a covered card, a switched tab and a scrolled-away row all stop it. Only the view's own link is still spent while covered.
- The tap follows the cell's window attachment, and `UITableView` keeps a buffer of prepared cells just past the visible bounds — so a row scrolled *marginally* off keeps the tap alive until the cell is really let go. That is cheap hysteresis, not a leak; it is why a scroll test has to push the row well clear before asserting the tap stopped.
- `AudioLevelTap`'s scratch buffers are freed in `dealloc` rather than in `remove`, so a concurrent display-rate reader holding it through the atomic property cannot touch freed memory. Freeing in `remove` would need a lock on that path.
