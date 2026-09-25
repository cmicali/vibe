# Equalizer counters

`dump_equalizer`'s schema, the bounds each counter must hold, and `set_equalizer_mode`. Read when judging the equalizer bars on either platform; the launch flags (`--silent` zeroes after the meter, so the bars are live) are in `SKILL.md`. The producer contract is `Vibe/Audio/Levels/CLAUDE.md`'s, the renderer's `Vibe/Controls/CLAUDE.md`'s.

`dump_equalizer` has the same schema on both apps: `{levelsEnabled, outputAudioActive, published, sequence, bands, audio: {requested, meterObject, installed, callbacks, analyzedWindows, publications, sequence, lastFrameLength, sampleRate, retiredOutputCount, outputAudioActive, normalizationMode}, renderer: {activeDisplayLinks, displayTicks, geometryLayouts, transformWrites}, silent, noAudioHw, manualRendering}`. `audio.normalizationMode` is the canonical `balanced`, `activity` or `spectrum` string. Counters are cumulative and never reset.

Bounds:

- `displayTicks` counts snapshot polls, not animation frames, and must remain at or below 30 per second.
- `geometryLayouts` stays flat with stable bounds.
- `transformWrites` counts model-target and immediate-reconciliation writes: at most one per changed bar for each newly observed publication, plus changed-bar passes for geometry, source, activity and one stale-to-zero settle. A visible pause or stop may add one synchronous changed-bar pass to put the model at dots; Core Animation then displays the 0.55-second release with no further transform writes, display ticks, FFT callbacks, timer or completion callback. Pixel loss cancels that release immediately.
- After an inactive transition and queue/handoff settlement, the audio counters and `displayTicks` stay flat and `activeDisplayLinks` is zero.
- The geometry and transform-write bounds additionally need no resizing, scrolling or cell population during the sample.

## `set_equalizer_mode balanced|activity|spectrum`

A session-only comparison between Vibe's own three modes (no claim that any reproduces Apple's visualizer), the same on both apps. `balanced` is the launch default: it starts from the coherent shared energy-per-octave callback average, reserves 9% display headroom, and adds a shared-support-gated 35% of only the positive difference to the per-window private-reference activity summary; unsupported bands stay dark. `spectrum` exposes the unmodified coherent common-reference endpoint, `activity` the unmodified five-private-reference endpoint. All three reuse one FFT and callback cadence.

Success replies `ok:true`, the canonical `normalizationMode`, and `requested`, `meterObject` and `installed` — the last three make a failed active-meter replacement visible (`meterObject` stays 1 once a meter exists, since the meter is kept across demand; `installed` follows demand); any other grammar is the usage error. Changing an active mode synchronously replaces the meter, invalidates the old publication and resets the analyzer's partial window and reference history, so wait for `published:true` and an advancing `sequence` before judging the new mode. The mode survives later demand and pipeline-rebuild reinstalls in that process (each replacement starts fresh analyzer history); relaunch restores `balanced`.
