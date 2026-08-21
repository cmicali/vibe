# Waveform rendering

The *rendering* half of the two-layer waveform system. The data layer — generation, caching, BPM and key — is `Vibe/Audio/Waveform/` and `Vibe/Audio/Analysis/`.

This top level holds everything both platforms draw. **`Mac/` (the `NSView`) and `iOS/` (the scrubber) each have their own `CLAUDE.md`.**

## Renderers

`AudioWaveformRenderer` is the strategy protocol; `WaveformRendererRegistry` maps stable style identifiers to implementations. Two families:

- **Detailed** (`DetailedAudioWaveformRenderer`, `OversamplingDetailedAudioWaveformRenderer`) — a shared bar mask over a band-pinned gradient. The default style is `oversampling_detailed_x4` (`SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT`).
- **Basic** / **Sonic Cirrus** — `BasicAudioWaveformRenderer` re-aims its fade; `SonicCirrusWaveformRenderer` draws discrete bar layers with gaps.

Both families animate through a shared **`WaveformMorphEngine`**, which owns the displayed and target sample vectors, the 60 Hz easing timer and the retarget decision tree. Renderers supply only target-building and layer geometry.

**The morph is what makes the live tree expensive, so it is skippable.** `settleMorphImmediately` (forwarded by both families to `WaveformMorphEngine.settleImmediately`) lands the bars on the new shape in one rebuild.

## The theme

**`WaveformTheme` is the one home of the palette resolution rules** — the theme identifier (`AppSettings.waveformTheme`), the appearance, the artwork color, and the custom pair go in; full-alpha `playedColor`/`unplayedColor`/`hoverColor` come out. The theme is the *palette* and the style stays the *geometry*: renderers keep deriving their own gradient alphas from the theme hues, which is what keeps the White theme pixel-identical to the pre-theme monochrome output. Sonic Cirrus's once-hardcoded orange pair is now a derivation from `theme.playedColor` (the bottom mirror is a fixed blend toward white); the Orange theme supplies that hue to every style. Each view resolves the theme itself — settings + appearance + (macOS only) the settled artwork color — and hands it down, re-resolving on an appearance flip because every rule in the constructor branches on `isDark`. The hover color is derived, not the old "base at full alpha": played shifted toward the appearance's contrast pole until the luminance delta clears 0.25, so the highlight survives any custom palette.

**A chromatic theme hue draws at full layer opacity in the Detailed family.** `kWaveformOpacity` tones the monochrome look down to sit over the album-art backdrop; applied to a colored hue it reads muddy next to Sonic Cirrus's full-alpha orange, so `updateColors:` picks the opacity per side from `theme.playedColorIsChromatic`/`unplayedColorIsChromatic`, and the envelope bake makes the same choice.

`DetailedAudioWaveformRenderer` also exposes an envelope-bitmap API — `envelopeSamplesForWaveform:` (main thread), `newEnvelopeImageForSize:scale:samples:` and its unplayed twin (any queue), and `unplayedOverPlayedOpacity` — that renders the settled bar geometry and a theme-derived gradient into one image. It exists for the iOS scrubber's settled fast path; the mac view does not use it. The bitmap bakes *this* family's band-pinned gradient, so `Basic`'s re-aimed fade would need its own bake. **Keep it pixel-identical to the live layers**: it duplicates `rebuildMaskPaths`' settled rounding, `configureGradient:`'s band, and `updateColors:`' theme stops and opacity choice on purpose, and a change to any must land in both. While the theme's unplayed hue is the played hue (`unplayedSharesPlayedHue`) the unplayed presentation is the played bitmap at `unplayedOverPlayedOpacity`; a two-hue theme bakes the unplayed image separately with its own stops — doubling that cell's bitmap bytes, a deliberate trade the zoom-floor budget does not model.

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
