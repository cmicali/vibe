# Future: render-pipeline follow-ups

Written 2026-09-24, after Stage 3 of the CoreAudio pipeline (#67, stacked on #66). Planned, not implemented. Three tidy-ups the review of Stage 3 proposed and the stage declined, each judged right but not worth landing before the pipeline has settled: none changes what the user hears, and each touches the render path a beta has yet to run for a whole cycle.

**When.** After #66 and #67 have merged to `main` and one beta has played through the pipeline for a release cycle with no `Stall:` report and `outputDropouts` at zero in the debug reports that come back. Each item is its own small PR against `main`, in the order below: the pure move first, the two measured ones after, and the last only if its measurement says so.

## 1. The carrier verbs move onto the platform categories

**Today.** `Vibe/Audio/AudioPlayer+Graph.m` keeps twelve `TARGET_OS_OSX` branches for what the carrier is — create it, start it, stop it, is it running, its latency, dropout and cost readers — while `AudioPlayerInternal.h` already states the design that avoids them: one category per platform on the shared private surface (`Mac/Devices/AudioPlayer+Devices`, `iOS/AudioPlayer+Recovery`).

**Change.** Declare `createCarrierOnQueue`, `startCarrierOnQueueWithError:`, `stopCarrierOnQueue`, `carrierRunningOnQueue` and one carrier-counters reader in the two category headers and implement them in their `.m` files. `startOutputOnQueue:` becomes one body with no `#if`: bump the generation, open the gate, start the carrier, close the gate on refusal, install the meter, refresh, drain timer. `applyOutputRateOnQueue:` goes to `Mac/Devices/` with the carrier, which needs `setMasterBusFormatOnQueue:` in `AudioPlayer+Graph.h` and `VibeMasterBusRender` exported with a `void *` first parameter, so the proc trampoline in Graph.m goes. The four `diagnosticRender*` accessors in `AudioPlayer+Diagnostics.m` collapse into that one reader. The debug pump's attachment stays in Graph.m: it is the same on both platforms.

**Gate.** `make check-layout` (the platform-boundary rule), both Debug builds, both suites; the hardware transport pass and the iOS simulator loop from the `vibe-debug` skill, since the carrier's start and stop are the edges that move. About 40 lines out of Graph.m and 30 into the categories; the win is a shared file with no platform branch.

## 2. The meter accumulates once

**Today.** `VibeLevelMeterRender` (`Vibe/Audio/Levels/AudioLevelTap.m`) copies every sample into the meter's accumulator, about 100 ms at the tap's rate (`VibeLevelTapBufferFrameCount`), and when it is full `VibeAudioLevelAnalyzerConsume` copies each FFT window out of it again. The batch exists so the analyzer's per-call summary spans several windows, which is the cadence and the cross-window averaging the engine tap's 100 ms delivery had and `references/equalizer-counters.md` bounds.

**Change.** Give the analyzer the batch length at creation (`VibeAudioLevelAnalyzerCreate(rate, mode, batchFrames)`): it accumulates whole windows itself, carries the per-window aggregates (`sharedEnergySum`, the private references, the callback record) across calls, and returns a publication only when a batch completes. `VibeLevelMeter` keeps the publisher session, the install generation and the beta probe; its accumulator and `fill` go. One copy of the samples, the same cadence.

**Gate.** The `AudioLevelMath` cadence tests; the render suite's signal-probe cases; on both apps, `dump_equalizer`'s `callbacks`, `analyzedWindows` and `publications` per second unchanged against a run on `main` at the same rate, and the balanced-mode levels on the same fixture within the display's resolution. About 60 lines fewer. The risk is the tuning: a change in publications per second or in the balanced levels is a regression, not a simplification.

## 3. vDSP in the FX chain

**Today.** `VibeFXAdd` and `VibeFXPan` (`Vibe/Audio/FX/AudioFX.m`) are scalar loops; the bus already mixes with `vDSP_vsma` on the audio thread. The gate's slew (`VibeFXGate`) is a clamped per-frame ramp with no vDSP form.

**Change.** `vDSP_vadd` for the adds, `vDSP_vsmul` for the pans. Measured first: with Q, E, R and T all held the callback costs about 450 µs mean and 0.6 ms max at 512 frames and 48 kHz against the device's 10.7 ms period, and the hosted units' own DSP is most of it. Take a `dump_health` cost pass on `main` with every FX held, apply the change, take it again; land it only if the mean moves by more than the run-to-run spread the Stage 3 measurements showed (a third), else close the item as measured and not worth its lines.

**Gate.** `AudioFXChainTests` exact (the idle chain, the delay's tap and rest, the low kill's rest) and the render suite's FX response, delay timing and reverb tail cases; the cost pass above.

## Not in this list

The reviews also proposed exporting `VibeHostAudioUnit`'s dispose and latency readers further, a `Tests/*.h` for the shared PCM helpers the two audio test files re-spell, and a debug-only pin of the pump's max frames to the pipeline's slice size. Each is a handful of lines and was either done in Stage 3 or is not worth a PR of its own.
