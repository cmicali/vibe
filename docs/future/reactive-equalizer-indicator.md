# Future: an audio-reactive equalizer indicator on iOS

Written 2026-08-16, planned but not implemented. Nothing in the repo has changed for it yet. The file:line anchors below were taken against branch `ios-app` with an uncommitted working tree, in which `Vibe/Controls/EqualizerIndicatorView.{h,m}` had been moved out of `Vibe/Mac/Controls/` and made cross-platform but not yet staged; that move has since landed in `1a492d3`, along with the three documentation fixes this file used to list as adjacent staleness. Re-check every anchor before acting.

## Context

Apple Music's now-playing bars genuinely follow the music, in its track-list rows and in the Dynamic Island. **Neither is reusable, and that is not a matter of effort.** There is no public API for the Dynamic Island equalizer, and no API that hands any app the audio levels of playback — its own or another app's. Apple Music's row indicator is reactive because Apple Music taps its own engine; the Dynamic Island is a system surface fed privately. Nothing here can be vended, wrapped or subscribed to.

Vibe is in the same position Apple Music is, though: it plays its own audio, so it can tap its own engine. That makes this the easy version of the problem rather than the impossible one.

Today `Vibe/Controls/EqualizerIndicatorView.m` is entirely canned — hardcoded `transform.scale.y` keyframe tables (`barValues()`, lines 33-42) with deliberately mismatched per-bar durations (`kBarDurations`, line 42) so the loop does not read as a loop. It costs **zero CPU per frame**, because Core Animation runs the whole thing on the render server; the header contrasts this explicitly with the animated-GIF `NSImageView` it replaced in `0198e60` (CPU 7% → 2%). Any reactive path gives that property up, and should say what it buys.

## Scope this was planned at

Three decisions, already taken:

- **Surface: the library row indicator only** — `LibraryTrackCell`'s `_indicatorView`, built at `Vibe/iOS/LibraryViewController.m:226` and driven at `:287`. Exactly one is visible at a time. This is the same surface Apple Music makes reactive.
- **Platform: iOS only.** macOS keeps the canned keyframes. This follows the existing pattern from the root `CLAUDE.md` — folder art, BPM/key analysis and the DJ FX graph are each switched off at *one place* rather than compiled out — inverted.
- **Fidelity: five log-spaced FFT bands**, per-band AGC with an absolute floor, asymmetric attack/release. Raw magnitudes look bad (bars slam to the floor in gaps, quiet tracks barely move) and amplitude-only moves all five bars together, which reads as the canned animation with a volume knob.

## The facts that shaped the design

**There is no real-time signal access in the repo at all.** Zero `installTapOnBus:`, zero `removeTapOnBus:`, zero `AVAudioSinkNode`, zero metering, zero render callbacks — searched case-insensitively across all sources. Every FFT in the codebase runs offline on the decode pass. The tap is genuinely new code; nothing is being extended.

**The iOS graph is why this is cheap to get right.** `Vibe/iOS/PlaybackController.m:51` passes a hard `enableFX:NO`, so `_fx` is nil for the player's lifetime and `installMasterBusOnQueue` (`AudioPlayer.m:283`) takes the bare branch:

```
playerNode(track)     -> varispeed(track)     -+-> mainMixerNode -> outputNode
playerNode(crossfade) -> varispeed(crossfade) -+
```

Nothing sits between the mixer and the output, so **`mainMixerNode` bus 0 is exactly the signal reaching the speaker** — post-fade, post-varispeed, and the crossfade sum comes for free because both chains already meet there. On macOS with FX on this tap point would be *wrong*: `AudioFX` connects `_masterMix -> outputNode` (`AudioFX.m:275`), and the reverb and delay returns re-enter downstream of the main mixer, so a `mainMixerNode` tap would miss every wet tail. That asymmetry is the second reason the plan stays iOS-only, beyond simple scope.

**The DSP already exists in the right shape.** `AudioBPMAnalyzer.mm:220-234` is a working streaming magnitude spectrum — `vDSP_hann_window`, `vDSP_vmul`, `vDSP_ctoz`, `vDSP_fft_zrip`, `vDSP_zvmags` on 1024-sample frames — along with the frame-accumulation idiom a tap needs. Copy the per-frame path; the feed is the only thing that differs.

**A correctly gated display link already exists on the card**, `PlayerViewController.m:62-67`, `CAFrameRateRangeMake(30, 60, 60)` through `VibeWeakProxy`, paused unless playing && foreground && presented && !scrolling. That is the pattern to copy, not to share — the row indicator wants its own.

**Cost is not the concern.** A 1024-point real FFT is ~5-10µs on modern ARM; at 48 kHz with a 1024 hop that is ~47 per second, comfortably under 0.1% of one core. Measure it rather than trusting this line, but do not design around it.

## Three things already checked, so they are not re-litigated

**`AudioWaveformMonoMix` cannot be reused.** `Vibe/Audio/Waveform/AudioWaveform.h:14` looks like exactly the downmix a tap needs and is not: it expects **interleaved** float32, while an `installTapOnBus:` buffer is non-interleaved (`floatChannelData[ch]`). A stride-1 per-channel `vDSP_vadd` + `vDSP_vsmul` is a few lines; reaching for the existing helper will silently read garbage.

**`--silent` flattens the bars, and that is not a bug to fix.** `AudioPlayer.m:271` sets `mainMixerNode.outputVolume = 0`, and a tap on bus 0 is post-output-volume, so every band reads zero. Every `vibe-debug` screenshot run uses `--silent`. Visual verification has to run without it; numeric verification is what the debug command below is for. Do not move the tap upstream to work around this — upstream of the mute is also upstream of the mixer, which means per-track and re-plumbed on every crossfade.

**Demand-driven beats a constructor flag.** The obvious move is a fourth argument beside `enableFX:`, matching `AudioFX`'s precedent. A `levelsEnabled` property is better: it avoids churning the designated initializer and the macOS call site (`MainPlayerController.m:117`), and it is what lets the tap idle when the app is backgrounded, which a lifetime flag cannot.

## The design

### `Vibe/Audio/AudioLevelMath.h` — header-only, tested

Per the naming rule in the root `CLAUDE.md` (`*Math.h` returns a number in the problem's units), and so the tunable half is reachable from the host-less suite. Precedents: `FadeMath.h`, `AudioFXMath.h`, `GaplessSpliceMath.h`, `UIUpdateMath.h`.

- `VibeLevelBandBinRange(band, fftSize, sampleRate, *lo, *hi)` — log-spaced edges, roughly 40 Hz to Nyquist, bound at install from the **actual tap format**.
- `VibeLevelNormalize(meanEnergy, reference)` → 0..1 over a dB window, floored. Mean rather than sum, or the wide top band is loud by construction.
- `VibeLevelUpdateReference(reference, observed, dt)` — per-band AGC, slow decay, with an **absolute minimum** so true silence stays flat instead of amplifying the noise floor.
- `VibeLevelEnvelope(current, target, dt, attack, release)` — asymmetric; fast attack, slow release.

Per-band AGC is the thing that makes this read well rather than merely be correct: music slopes roughly -3 to -6 dB/octave, so without it the treble bars sit dead.

### `Vibe/Audio/AudioLevelTap.{h,m}`

Plain `.m` — Accelerate is C, so no C++ reaches a header. Lives in the shared `Vibe/Audio/`, so it compiles into both targets and needs no `project.yml` entry, but only iOS ever enables one. This mirrors `FolderArtResolver`, which likewise builds for both and is simply never handed to anything on iOS.

Owns the tap block, a ring accumulator (`bufferSize:` is a hint — delivered `frameLength` varies), the vDSP setup, the band reduction, and a published snapshot of five `_Atomic float` with relaxed ordering. Wait-free, no `os_unfair_lock` on a render-thread path, and tearing across bars is visually irrelevant.

**Smoothing deliberately does not live here.** The tap publishes instantaneous normalized levels at the hop rate; the view runs the envelope per display-link frame. That keeps motion frame-rate-based, and makes "the tap stopped firing" decay gracefully instead of freezing — which matters, because the engine's deferred idle stop (~6s after pause) stops the tap entirely.

### `AudioPlayer` — ownership

The player must own it: engine mutation is confined to `com.vibe.audioplayer` and `_queue` is private, and the reset rebuild re-runs `installMasterBusOnQueue`.

- `AudioPlayer.h`: `@property (nonatomic) BOOL levelsEnabled` (records intent, dispatches install/remove onto `_queue`, the idiom every `AudioFX` setter already uses) and `- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count` (lock-free, alongside `position` and `duration`).
- `AudioPlayerInternal.h`: the `_levelTap` ivar.
- `AudioPlayer.m`: install at the end of `installMasterBusOnQueue`; drop the reference in `dropEngineBoundStateOnQueue` (`:299`).

### `EqualizerIndicatorView` — reactive mode, keyframes as the fallback

In the header, a one-method protocol so the shared control gains no dependency on `Audio/`:

```objc
@protocol EqualizerLevelSource <NSObject>
- (BOOL)copyEqualizerLevels:(float *)out count:(NSUInteger)count;
@end

@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;
```

macOS never sets it, so the mac table's indicator is bit-for-bit unchanged.

In the implementation, `updateAnimations` (`:164`) becomes the fork. Run condition for the reactive path is `_animating && self.window != nil && _levelSource != nil`; it starts a `CADisplayLink` (`CAFrameRateRangeMake(30, 60, 60)`, targeted through `VibeWeakProxy`) and must **remove** the `@"eq"` keyframe animation, or the two modes fight over the same property. Per frame: pull five levels, run the envelope, write `bar.transform` inside a `CATransaction` with `setDisableActions:YES`, which is already this file's idiom. `setAnimating:NO` keeps today's dim to `alpha 0.5`, stops the link and decays to `kPausedHeights`. The existing `layoutSubviews` → `updateAnimations` call (`:127`) stays correct, since in reactive mode the per-frame write re-seats the transform anyway.

### iOS wiring

`PlaybackController` conforms to `EqualizerLevelSource`, forwarding to the player, and sets `player.levelsEnabled = isPlaying && windowVisible` — the same two gates `UIUpdateTimer` already uses (`PlaybackController.m:22-26` and the `UISceneDidEnterBackground` handler), so the tap costs nothing while backgrounded. `LibraryViewController` sets `_indicatorView.levelSource = _playback` where it builds the cell.

Accepted deliberately: while the now-playing card covers the library, the row's link still runs. Five CALayer transform writes on one offscreen view is not worth machinery to suppress.

### Debug channel

Add `dump_levels` to the iOS command table in `Vibe/Debug/iOS/`, printing the five band levels. Given the `--silent` interaction above, this is the *primary* verification path, not a convenience.

## Traps worth a `TRAP:` comment

1. **Media-services reset.** `installMasterBusOnQueue` is re-run by `AudioPlayer+Recovery`'s `reinitializeAfterMediaServicesReset`. A tap installed anywhere else dies silently after a reset — no error, no log, bars just stop. Install must happen inside that method. This is the one that will actually bite.
2. **`--silent`.** Worth a note beside the `--silent` block at `AudioPlayer.m:270` itself, since that is where someone will look when the bars are flat under a debug run.
3. **Non-interleaved tap buffers** — see `AudioWaveformMonoMix` above.
4. **No allocation and no ObjC message sends in the tap block.** Preallocate on enable; on disable, `removeTapOnBus:` and *then* release the scratch buffers, both on `_queue`.
5. **Sanitize non-finite values** before they reach a layer — precedent at `AudioWaveform.h:44-60`. A NaN level makes a `CATransform3D` NaN and the bar disappears permanently, with no way back short of a relayout.
6. **Sample rate is not constant** across route changes and media-services resets, so bind band edges from the tap format at install rather than a constant.

## Vocabulary

The root `CLAUDE.md` forbids synonyms and `make check-vocabulary` enforces the mechanical half. Fix the terms up front: **band** is a frequency range, **energy** is the raw summed magnitude, **level** is the published 0..1 per bar. No "meter", "RMS", "amplitude" or "spectrum" as a fourth name for any of these.

## Files

**New**: `Vibe/Audio/AudioLevelMath.h`, `Vibe/Audio/AudioLevelTap.{h,m}`, `Tests/AudioLevelMathTests.m`.

**Modified**: `Vibe/Audio/AudioPlayer.{h,m}`, `Vibe/Audio/AudioPlayerInternal.h`, `Vibe/Controls/EqualizerIndicatorView.{h,m}`, `Vibe/iOS/PlaybackController.{h,m}`, `Vibe/iOS/LibraryViewController.m`, the `Vibe/Debug/iOS/` command table.

No `project.yml` change — both new sources land in directories already listed. No `VibeStrings.h` change — nothing user-facing is written.

~~**Adjacent staleness, worth folding in.**~~ Resolved in `1a492d3`: `Vibe/iOS/CLAUDE.md` now names `EqualizerIndicatorView` on the library row, `Vibe/Mac/Controls/CLAUDE.md` records that the control moved out, and the root `CLAUDE.md` has its `Vibe/Controls/` entry. Nothing to fold in.

## Verification

1. `make test` — band edges, normalization, AGC decay and floor, envelope asymmetry. This is the half that decides how it *looks*, and it is the testable half; that is the whole reason for `AudioLevelMath.h`.
2. `make analyze` in **Release** (what CI gates), plus `make check-layout` and `make check-vocabulary`.
3. `vibe-debug` iOS, **launched without `--silent`**: play a track, `dump_levels` repeatedly to confirm the bands differ and move, then screenshot the library. Compare a bass-heavy track against a sparse one — band 0 and band 4 should behave visibly differently, which is the entire point of doing this rather than amplitude-only.
4. Fallback behaviour: pause → bars settle to the diamond pose at `alpha 0.5`; scroll the playing row off and back → the indicator reattaches via `didMoveToWindowShared`.
5. Background the app while playing → `levelsEnabled` goes NO, no CPU spent.
6. macOS `make build` → the mac table indicator unchanged, `levelSource` nil, keyframe path.
7. **Measure the CPU claim rather than asserting it** — Xcode's gauge with the library visible and playing, against the same build with `levelsEnabled` forced NO. The zero-per-frame property being given up is the reason to have a number.
