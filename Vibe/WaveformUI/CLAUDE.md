# Waveform rendering

The *rendering* half of the two-layer waveform system. The data layer — generation, caching, BPM and key — is `Vibe/Audio/Waveform/` and `Vibe/Audio/Analysis/`.

This top level holds everything both platforms draw. **`Mac/` (the `NSView`) and `iOS/` (the scrubber) each have their own `CLAUDE.md`.**

## Renderers

`AudioWaveformRenderer` is the strategy protocol; `WaveformRendererRegistry` maps stable style identifiers to implementations. Two families:

- **Detailed** (`DetailedAudioWaveformRenderer`, `OversamplingDetailedAudioWaveformRenderer`) — a shared bar mask over a band-pinned gradient. The default style is `oversampling_detailed_x4` (`SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT`).
- **Basic** / **Sonic Cirrus** — `BasicAudioWaveformRenderer` re-aims its fade; `SonicCirrusWaveformRenderer` draws discrete bar layers with gaps.

**The bar count follows the drawn width at each style's designed pitch** — 4pt for Basic and Sonic Cirrus's 128 bars, half a point for Detailed's 1,024, all across the 512pt design-width waveform — so a resize adds or removes bars at their designed size instead of stretching the pitch (`numBarsForWidth:` on the Detailed family, `barCountForWidth:` in Sonic Cirrus, each with its own cap). The oversampling x2/x4/x8 styles are the deliberate exception and keep their fixed counts: their look is the sub-pixel overlap of more rects than pixels, which a resize already preserves. A count change mid-picture reaches the morph engine, which resamples the displayed bars to the new count rather than collapsing them, so a live resize stays continuous.

Both families animate through a shared **`WaveformMorphEngine`**, which owns the displayed and target sample vectors, the 60 Hz easing timer and the retarget decision tree. Renderers supply only target-building and layer geometry.

**The morph is what makes the live tree expensive, so it is skippable.** `settleMorphImmediately` (forwarded by both families to `WaveformMorphEngine.settleImmediately`) lands the bars on the new shape in one rebuild.

## The theme

**`WaveformTheme` is the one home of the palette resolution rules** — the theme identifier (`AppSettings.waveformTheme`), the appearance, the artwork color, and the appearance's custom pair go in; `playedColor`/`unplayedColor`/`hoverColor` come out. The theme is the *palette* and the style stays the *geometry*.

**Each theme color carries its side's resting level in its alpha; renderers own only their ramp shapes**, scaling every stop relative to that level (`VibeColorAtRampFraction`, `AudioWaveformRenderer.h`). The Mono pair's alphas (0.75/0.375) are the Detailed family's old stop-times-layer alphas verbatim, which keeps the default look pixel-identical to the pre-theme output; Orange pairs the full-strength hue with the monochrome base at 0.89 — Sonic Cirrus's historical unplayed level — so every style draws the classic Sonic Cirrus pairing, and on Sonic Cirrus's own bars the Orange theme *is* the pre-theme output; Album art is that pairing reversed, the base played at full strength over the art's hue as the unplayed side. A custom well's alpha dials its side's whole intensity, persisted in the hex (`#RRGGBBAA`).

The custom theme stores a played/unplayed pair **per appearance** — one pair cannot read on both backdrops — and each view's resolver passes the pair matching its current `isDark`; the built-in themes resolve per appearance inside the constructor, so a flip always re-resolves rather than merely recoloring. The album-art legibility clamp is perceptual: below the saturation floor it falls back to Mono, otherwise it blends toward the appearance's contrast pole until the color's *luminance* clears the bar — HSB brightness is hue-blind and passes a too-dark pure blue untouched. The hover color is derived, not the old "base at full alpha": the played hue at full alpha, shifted toward the pole until the luminance delta clears 0.25, so the highlight survives any custom palette.

`DetailedAudioWaveformRenderer` also exposes an envelope-bitmap API — `envelopeSamplesForWaveform:` (main thread), `newEnvelopeImageForSize:scale:samples:` and its unplayed twin (any queue), and `unplayedOverPlayedOpacity` — that renders the settled bar geometry and a theme-derived gradient into one image. It exists for the iOS scrubber's settled fast path; the mac view does not use it. The bitmap bakes *this* family's band-pinned gradient, so `Basic`'s re-aimed fade would need its own bake. **Keep it pixel-identical to the live layers**: it duplicates `rebuildMaskPaths`' settled rounding, `configureGradient:`'s band, and `updateColors:`' theme-derived stops on purpose, and a change to any must land in both. While the theme's unplayed hue is the played hue (`unplayedSharesPlayedHue`) the unplayed presentation is the played bitmap at `unplayedOverPlayedOpacity` — the ratio of the two colors' resting alphas, valid because both sides share the ramp shape; a two-hue theme bakes the unplayed image separately with its own stops — doubling that cell's bitmap bytes, a deliberate trade the zoom-floor budget does not model.

## The loading indicator

The control itself moved to `Vibe/Controls/LoadingIndicator` when the row gutters became its second consumer — one control, two styles (`LoadingIndicatorMath.h`), and the waveform style is pixel-identical to what lived here. What stays in this directory is *when* each view shows it, and the traps below, which are still the waveform's to know.

**It is one control across both of its modes**, not a shimmer with a progress bar bolted on: a faint full-width midline track, a solid filled head over `[0, fraction]` whose last few points fade out, and the shimmer band sweeping **only the unfilled remainder**. Indeterminate is simply the case where nothing is filled, so the sweep spans the whole width. Every part of the control, fill included, is placed by `layoutInBounds:animatedOver:` and nowhere else, with `setProgress:inBounds:` supplying only the ease and a resize passing 0, so a negative fraction reverts cleanly.

**The macOS empty state's static line reuses that control's resting track**, reading the waveform style's height and alpha from `LoadingIndicatorMath.h`, so it shares the loading line's weight and colour by construction. The iOS empty state draws no line.

`DownloadProgressMonitor` (`Vibe/System/`) feeds the fraction for a materializing cloud file — about once a second, which is the provider's ceiling — so `setProgress:inBounds:` **eases** the fill to each value over roughly the previous gap instead of snapping. Core Animation retargets from the presentation value, so an early sample redirects rather than jumps, and the fill never runs past what was reported, leaving a stall honest. Drive both modes without a real download via the debug channel's `set_loading`.

**Waveform data arriving ends the sweep but not the fill** — a disk-cached waveform can land while the provider is still materializing the audio, so the fill riding over the drawn waveform is the only remaining sign of the download. That is `endSweepKeepingFill`, whose answer tells the caller whether anything is left to keep.

**TRAP: the band sweeps in from before its span and out past the end, and the view's own layer does not mask to bounds** — so it rides inside a `masksToBounds` clip layer (`_shimmerClip`) sized to that span. Without it the shimmer draws over the artwork on one side and out to the window edge on the other.

**TRAP: reinstall the sweep animation only when its endpoints actually change.** Live resize lands in `installSweepAcrossRemainder:bandWidth:` every frame, and an unconditional remove-and-re-add restarts the 1.2s sweep each time, freezing the band at the left edge.

**TRAP: when the sweep *is* reinstalled, carry the running animation's phase over**, or the retargeted band snaps back to the left edge. The phase is elapsed time plus the previous carry-over — `animationForKey:` returns a copy that preserves `timeOffset`, so dropping it loses the phase on every reinstall after the first. `beginTime` is 0 until the first transaction commit stamps it; treat elapsed as 0 then.

## The convert sweep

Convert to FLAC's progress is drawn *with the waveform itself*: the bars the sweep front crosses collapse to the midline and ease back, a brush moving through the waveform at conversion pace. There is no separate progress element.

It rides the morph engine's displayed-vs-target split. `dipDisplayedSamplesFromFraction:toFraction:` zeroes the displayed samples in the newly crossed span, rebuilds once so the notch is seen at zero, and starts the standard ease back toward the unchanged target — so bars dipped earlier have recovered more and the graded trail behind the front falls out for free. Both families forward `dipBarsFromFraction:toFraction:` to their engine; an x fraction maps to the raw sample array linearly in both layouts, because samples run left to right.

## Language

These files are `.mm` because they hold the C++ sample vectors. Keep the C++ types out of any header that plain ObjC (`.m`) files import.
