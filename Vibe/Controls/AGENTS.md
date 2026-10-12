# Shared controls

Controls both apps draw identically. A platform shell owns placement and visibility. A shared control owns its retained layers, visual state and animation. Neither side imports `Audio/`.

## EqualizerIndicatorView

The playing-row marker owns five retained pill `CALayer`s. It never redraws a bitmap or path for live motion. A material level change writes only the affected layer's model `transform.scale.y`. It replaces one keyed explicit animation that starts from the presentation scale. Core Animation interpolates at display cadence with no app callback per frame. Stable bounds make `layoutBars` a no-op. The poll path never invalidates layout, its row, the waveform or any sibling view.

`EqualizerLevelSource` is producer-agnostic. It supplies a level snapshot with a monotonic sequence and accepts balanced demand. The control's poller runs at 20 to 30 Hz and reads only that snapshot and the staleness clock. It is a `CADisplayLink` on macOS 14+ and iOS, and a tolerant `NSTimer` on macOS 13. The timer is confined to `startLevelLink`'s `@available` else-branch, which goes when macOS 13 support does. A repeated sequence writes nothing. The threshold and the attack and release durations are in `EqualizerAnimationMath.h`. Activity is the fail-closed decision in `EqualizerActivityRules.h`.

`audioOutputActive` and `presentationVisible` both default to NO. The poller also needs a source, a window and nonempty geometry. Starting it declares one consumer. When audio stops while the row stays visible, the control stops the poller and balances demand at once. It writes the collapsed model scales and lets one keyed release per bar finish on the compositor. That release owns no display link, FFT, timer, callback or completion. Visibility loss, detachment, empty geometry and source replacement cancel the animations and settle to dots at once. Source replacement releases the old source before requesting the new one.

`Audio/Levels/AGENTS.md` owns production. `iOS/AGENTS.md` and `Playlist/Mac/AGENTS.md` own their material-visibility facts. The root `AGENTS.md` guarantee ties them together.

## LoadingIndicator and LoadingIndicatorView

`LoadingIndicator` is one control with **two styles and both modes**. It draws a faint track across its bounds, a solid fill over `[0, fraction]`, and, in the waveform style only, a shimmer band sweeping the unfilled rest. Indeterminate is the case where nothing is filled.

**`layoutInBounds:` honors the origin, not just the size.** The iOS scrubber hands it only the span its content occupies (`WaveformUI/iOS/AGENTS.md`). Every other site hands it full bounds.

The **waveform style** is the hairline midline both waveform views draw. The views own when it shows and how wide (`WaveformUI/AGENTS.md`). Its traps are the control's own:

**TRAP: the band sweeps in from before its span and out past the end, and the host layer does not mask to bounds.** So the shimmer rides inside a `masksToBounds` clip layer (`_shimmerClip`) sized to that span. Without it the band draws over the artwork on one side and out to the window edge on the other.

**TRAP: reinstall the sweep only when its endpoints actually change.** Live resize lands in `installSweepAcrossRemainder:bandWidth:` every frame. An unconditional remove and re-add restarts the 1.2s sweep each time and freezes the band at the left edge.

**TRAP: when the sweep is reinstalled, carry the running animation's phase over**, or the band snaps back to the left edge. The phase is elapsed time plus the previous carry-over. `animationForKey:` returns a copy that keeps `timeOffset`, so dropping it loses the phase on every reinstall after the first. `beginTime` is 0 until the first transaction commit stamps it. Treat elapsed as 0 then.

The **row style** is a small round-ended pill for the 16pt number gutter. **It builds no shimmer** (`hasShimmer`), since a sweep that small reads as flicker. Its indeterminate motion is a slow whole-pill alpha pulse (`pulseAlpha`). A static pill would read as a bar stuck at zero, and a provider's transfer can sit indeterminate for a long time. The first fill sample retires the pulse.

`LoadingIndicatorMath.h` holds the per-style metrics and is the seam under test. **`LoadingIndicatorMathTests` pins the waveform style's numbers**, so adding or tuning a style cannot move what both waveform views draw. The macOS empty-state line reads the waveform style's height and track alpha from the same header, so it cannot drift from the loading track.

`LoadingIndicatorView` hosts the row style in a gutter. It is built like `EqualizerIndicatorView`, with `#if TARGET_OS_OSX` only for the superclass and the layout, appearance and backing hooks. Its only motion is one repeating `CABasicAnimation` on one layer. **It must not hold a live animation for a row nobody can see.** So the row wiring in `Playlist/Mac/` and `iOS/` sets `active` to NO on cell reuse and on hiding. The view also drops it when it leaves its window (`viewDidMoveToWindow`, `didMoveToWindow`), which covers scroll-out and detachment. A row scrolled back in is configured again by its table. `endSweepKeepingFill` is never used here. It serves only the iOS scrubber.
