# Future: render-pipeline follow-ups

Written 2026-09-24, after Stage 3 of the CoreAudio pipeline (#67, stacked on #66). Planned, not implemented. One tidy-up the review of Stage 3 proposed and the stage declined, judged right but not worth landing before the pipeline has settled: it changes nothing the user hears, and it touches the render path a beta has yet to run for a whole cycle. Two more from the same review — the meter accumulating once, and vDSP in the FX chain — landed in #67's performance round, with the bus mixing its rings in spans, so they are gone from here.

**When.** After #66 and #67 have merged to `main` and one beta has played through the pipeline for a release cycle with no `Stall:` report and `outputDropouts` at zero in the debug reports that come back. A small PR of its own against `main`.

## 1. The carrier verbs move onto the platform categories

**Today.** `Vibe/Audio/AudioPlayer+Graph.m` keeps twelve `TARGET_OS_OSX` branches for what the carrier is — create it, start it, stop it, is it running, its latency, dropout and cost readers — while `AudioPlayerInternal.h` already states the design that avoids them: one category per platform on the shared private surface (`Mac/Devices/AudioPlayer+Devices`, `iOS/AudioPlayer+Recovery`).

**Change.** Declare `createCarrierOnQueue`, `startCarrierOnQueueWithError:`, `stopCarrierOnQueue`, `carrierRunningOnQueue` and one carrier-counters reader in the two category headers and implement them in their `.m` files. `startOutputOnQueue:` becomes one body with no `#if`: bump the generation, open the gate, start the carrier, close the gate on refusal, install the meter, refresh, drain timer. `applyOutputRateOnQueue:` goes to `Mac/Devices/` with the carrier, which needs `setMasterBusFormatOnQueue:` in `AudioPlayer+Graph.h` and `VibeMasterBusRender` exported with a `void *` first parameter, so the proc trampoline in Graph.m goes. The four `diagnosticRender*` accessors in `AudioPlayer+Diagnostics.m` collapse into that one reader. The debug pump's attachment stays in Graph.m: it is the same on both platforms.

**Gate.** `make check-layout` (the platform-boundary rule), both Debug builds, both suites; the hardware transport pass and the iOS simulator loop from the `vibe-debug` skill, since the carrier's start and stop are the edges that move. About 40 lines out of Graph.m and 30 into the categories; the win is a shared file with no platform branch.

## Not in this list

The reviews also proposed exporting `VibeHostAudioUnit`'s dispose and latency readers further, a `Tests/*.h` for the shared PCM helpers the two audio test files re-spell, and a debug-only pin of the pump's max frames to the pipeline's slice size. Each is a handful of lines and was either done in Stage 3 or is not worth a PR of its own.
