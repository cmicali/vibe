# Equalizer counters

`dump_equalizer`'s schema, the bounds each counter must hold, and `set_equalizer_mode`. Read when judging the equalizer bars on either platform. The producer contract is `vibe-libs/audio/Meter/AGENTS.md`'s, with the player's side in `vibe-libs/audio/Player/AGENTS.md` and the shells' demand in `Vibe/Audio/AGENTS.md` (Live output levels). The renderer's is `Vibe/Controls/AGENTS.md`'s.

`dump_equalizer` has the same schema on both apps: `{levelsEnabled, outputAudioActive, published, sequence, bands, audio: {requested, meterObject, installed, callbacks, analyzedWindows, publications, sequence, lastFrameLength, sampleRate, retiredOutputCount, outputAudioActive, normalizationMode, signalProbe}, renderer: {activeDisplayLinks, displayTicks, geometryLayouts, transformWrites}, silent, noAudioHw, manualRendering}`. Counters are cumulative and never reset.

Bounds:

- `displayTicks` counts snapshot polls, not animation frames, and stays at or below 30 per second.
- `geometryLayouts` stays flat with stable bounds.
- `transformWrites` is at most one per changed bar for each new publication, plus changed-bar passes for geometry, source, activity and one stale-to-zero settle. A visible pause or stop may add one pass to put the model at dots. Core Animation then plays the 0.55 s release with no further writes, ticks, FFT callbacks or timers. Pixel loss cancels the release at once.
- After an inactive transition settles, the audio counters and `displayTicks` stay flat and `activeDisplayLinks` is zero.
- The geometry and transform-write bounds also need no resizing, scrolling or cell population during the sample.

## `set_equalizer_mode balanced|activity|spectrum`

A session-only switch between the three normalization modes, the same on both apps. `balanced` is the launch default. What each mode computes is in `vibe-libs/audio/Meter/AGENTS.md`.

The reply carries `ok:true`, the canonical `normalizationMode`, and `requested`, `meterObject` and `installed`, so a failed meter replacement is visible. `meterObject` reports whether a meter currently exists. `installed` reports an active publisher session. Both can return to zero when demand ends. Any other argument is the usage error. Changing an active mode replaces the meter and resets its history, so wait for `published:true` and an advancing `sequence` before judging the new mode. The mode survives later reinstalls in that process. A relaunch restores `balanced`.
