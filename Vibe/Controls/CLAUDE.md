# Shared controls

This directory contains controls both apps draw identically. Platform shells own placement and visibility; a shared control owns its retained layers, visual state and animation behavior. Neither side imports `Audio/`.

## EqualizerIndicatorView

The playing-row marker owns five retained pill `CALayer`s. It never redraws a bitmap or path for live motion. A material level change updates only the affected layer's model `transform.scale.y` and replaces one keyed explicit Core Animation animation from the presentation scale. Core Animation interpolates at the display cadence without an app callback or property write for every displayed frame. Stable bounds make `layoutBars` a no-op, and the poll path never invalidates layout, its row, the waveform or any sibling view.

`EqualizerLevelSource` is deliberately producer-agnostic: it supplies a coherent level snapshot plus a monotonic sequence and accepts balanced demand. The control's 20–30 Hz `CADisplayLink` only polls that snapshot and the staleness clock. Duplicate sequences perform no transaction or layer write. Target threshold and attack/release durations live in `EqualizerAnimationMath.h`; activity is the pure fail-closed decision in `EqualizerActivityRules.h`.

Both `audioOutputActive` and `presentationVisible` default to NO. The poller also requires a source, a window and nonempty geometry. Starting declares one consumer. When audio stops while the row remains materially visible, the control invalidates the poller and balances demand immediately, writes the collapsed model scales, then lets one keyed Core Animation release per noncollapsed bar finish at compositor cadence. That release owns no display link, FFT, timer, callback or completion. Visibility loss, detachment, empty geometry and source replacement cancel keyed animations and settle to dots immediately; source replacement releases the old source before requesting the new one.

`Audio/Levels/CLAUDE.md` owns production. `iOS/CLAUDE.md` and `Playlist/Mac/CLAUDE.md` own their material-visibility facts. Root `CLAUDE.md` owns the cross-directory guarantee tying them together.
