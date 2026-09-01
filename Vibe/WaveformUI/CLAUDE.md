# Waveform rendering

The *rendering* half of the two-layer waveform system. The data layer — generation, caching, BPM and key — is `Vibe/Audio/Waveform/` and `Vibe/Audio/Analysis/`.

This top level holds everything both platforms draw. **`Mac/` (the `NSView`) and `iOS/` (the scrubber) each have their own `CLAUDE.md`.**

## Renderers

`AudioWaveformRenderer` is the strategy protocol; `WaveformRendererRegistry` maps stable style identifiers to implementations. Two bar families plus one flat style:

- **Detailed** (`DetailedAudioWaveformRenderer`, `OversamplingDetailedAudioWaveformRenderer`) — a shared bar mask over a band-pinned gradient. The default style is `oversampling_detailed_x4` (`SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT`).
- **Basic** / **Sonic Cirrus** — `BasicAudioWaveformRenderer` re-aims its fade; `SonicCirrusWaveformRenderer` draws discrete bar layers with gaps. Both are block styles, so hover lights the whole block under the cursor and the played fill advances a block at a time — one home for the two quantization rules, `VibeBlockIndexForX`/`VibeBlockBoundaryForProgress` (`AudioWaveformRenderer.h`). Presentation only: the seek a hover or click reports stays continuous.
- **Cupertino** (`CupertinoWaveformRenderer`) — the Apple Music pill: a rounded-capsule track with a continuous played fill, clipped by the capsule so the end caps round and the playhead edge stays square. It never reads the samples — having a waveform at all only decides whether the pill shows, hidden being this style's collapse for the empty and loading states — so it sits outside the morph engine entirely (settle and the convert dip are base no-ops, meaning Convert to FLAC shows no sweep in this style) and never bakes. Hover grows the pill, Apple Music's own affordance, with a hairline tracked-seek column inside the capsule.

**Bar heights draw energy, not peaks.** `VibeWaveformBarLevel` (`AudioWaveformRenderer.h`) is the one home of the chunk-to-level mapping — RMS against a -6 dBFS full-scale reference — because per-bar peaks peg to full scale on limited dance masters: at Basic's pitch every bar covers seconds of audio, so each contained a full-scale kick and the strip read as a solid block. The Detailed family keeps its min/max envelope as the *shape*, rescaled so its larger extent is that level; Sonic Cirrus draws the level directly. The level's energy window is floored at 1/1024 of the track (`kVibeWaveformEnergyColumns`) however fine the bars — RMS over less than a beat converges back to peak, which re-pegged the oversampling styles' one-chunk bars — so every count draws the same loudness envelope. The scale's reference extent is the energy *column's* peak, not the bar's own, so bars finer than the column keep their relative peak texture below that envelope instead of flattening to it.

**The bar count follows the drawn width at each style's designed pitch** — 4pt for Basic and Sonic Cirrus's 128 bars, half a point for Detailed's 1,024, all across the 512pt design-width waveform — so a resize adds or removes bars at their designed size instead of stretching the pitch (`numBarsForWidth:` on the Detailed family, `barCountForWidth:` in Sonic Cirrus, each with its own cap). The oversampling x2/x4/x8 styles are the deliberate exception and keep their fixed counts: their look is the sub-pixel overlap of more rects than pixels, which a resize already preserves. A count change mid-picture reaches the morph engine, which resamples the displayed bars to the new count rather than collapsing them, so a live resize stays continuous.

Both families animate through a shared **`WaveformMorphEngine`**, which owns the displayed and target sample vectors, the 60 Hz easing timer and the retarget decision tree. Renderers supply only target-building and layer geometry.

**The morph is what makes the live tree expensive, so it is skippable.** `settleMorphImmediately` (forwarded by both families to `WaveformMorphEngine.settleImmediately`) lands the bars on the new shape in one rebuild.

## The theme

**`WaveformTheme` is the one home of the palette resolution rules** — the theme identifier (macOS reads it and the custom pair off `AppSettings.currentTheme`; iOS off the shared loose `AppSettings.waveformTheme` accessors), the appearance, the artwork color, and the appearance's custom pair go in; `playedColor`/`unplayedColor`/`hoverColor` come out. The theme is the *palette* and the style stays the *geometry*.

**Each theme color carries its side's resting level in its alpha; renderers own only their ramp shapes**, scaling every stop relative to that level (`VibeColorAtRampFraction`, `AudioWaveformRenderer.h`). The Mono pair's alphas (0.75/0.375) are the Detailed family's old stop-times-layer alphas verbatim, which keeps the default look pixel-identical to the pre-theme output; Orange pairs the full-strength hue with the monochrome base at 0.89 — Sonic Cirrus's historical unplayed level — so every style draws the classic Sonic Cirrus pairing, and on Sonic Cirrus's own bars the Orange theme *is* the pre-theme output; Album art is that pairing reversed, the base played at full strength over the art's hue as the unplayed side. A custom well's alpha dials its side's whole intensity, persisted in the hex (`#RRGGBBAA`). The theme editor's Gradient switch sets `WaveformTheme.flatFill`, under which every family's stops collapse to the side's color as-is — the levels in the alphas survive, only the ramp goes; macOS resolves it from `AppTheme.waveformGradient` at the same site as the palette, and iOS never sets it.

The custom theme stores a played/unplayed pair **per appearance** — one pair cannot read on both backdrops — and each view's resolver passes the pair matching its current `isDark`; the built-in themes resolve per appearance inside the constructor, so a flip always re-resolves rather than merely recoloring. The album-art legibility clamp is perceptual: below the saturation floor it falls back to Mono, otherwise it blends toward the appearance's contrast pole until the color's *luminance* clears the bar — HSB brightness is hue-blind and passes a too-dark pure blue untouched. The cleared color is then pulled halfway toward its own luminance gray before it colors the unplayed side, which mutes a vivid dominant hue without moving the luminance the clamp just fixed. The hover color is derived, not the old "base at full alpha": the played hue at full alpha, shifted toward the pole until the luminance delta clears 0.25, so the highlight survives any custom palette.

`DetailedAudioWaveformRenderer` also exposes an envelope-bitmap API — `envelopeSamplesForWaveform:` (main thread), `newEnvelopeImageForSize:scale:samples:` and its unplayed twin (any queue), and `unplayedOverPlayedOpacity` — that renders the settled bar geometry and a theme-derived gradient into one image. It exists for the iOS scrubber's settled fast path; the mac view does not use it. The bitmap bakes *this* family's band-pinned gradient, so `Basic`'s re-aimed fade would need its own bake — the scrubber gates on `supportsEnvelopeBake`, the renderer's own answer, which Basic overrides back to NO; a subclass that changes its gradient aim or fill quantization must do the same. **Keep it pixel-identical to the live layers**: it duplicates `rebuildMaskPaths`' settled rounding, `configureGradient:`'s band, and `updateColors:`' theme-derived stops on purpose, and a change to any must land in both. While the theme's unplayed hue is the played hue (`unplayedSharesPlayedHue`) the unplayed presentation is the played bitmap at `unplayedOverPlayedOpacity` — the ratio of the two colors' resting alphas, valid because both sides share the ramp shape; a two-hue theme bakes the unplayed image separately with its own stops — doubling that cell's bitmap bytes, a deliberate trade the zoom-floor budget does not model.

## The loading indicator

The control itself moved to `Vibe/Controls/LoadingIndicator` when the row gutters became its second consumer — one control, two styles (`LoadingIndicatorMath.h`), and the waveform style is pixel-identical to what lived here. What stays in this directory is *when* each view shows it, and the traps below, which are still the waveform's to know.

**It is one control across both of its modes**, not a shimmer with a progress bar bolted on: a faint midline track across the bounds it is given, a solid filled head over `[0, fraction]` whose last few points fade out, and the shimmer band sweeping **only the unfilled remainder**. The mac view gives it the whole width, since it draws the whole track there; the iOS scrubber gives it the span its content occupies (`iOS/CLAUDE.md`). Indeterminate is simply the case where nothing is filled, so the sweep spans the whole width. Every part of the control, fill included, is placed by `layoutInBounds:animatedOver:` and nowhere else, with `setProgress:inBounds:` supplying only the ease and a resize passing 0, so a negative fraction reverts cleanly.

**The macOS empty state's static line reuses that control's resting track**, reading the waveform style's height and alpha from `LoadingIndicatorMath.h`, so it shares the loading line's weight and colour by construction. The iOS empty state draws no line.

`DownloadProgressMonitor` (`Vibe/System/`) feeds the fraction for a materializing cloud file — about once a second, which is the provider's ceiling — so `setProgress:inBounds:` **eases** the fill to each value over roughly the previous gap instead of snapping. Core Animation retargets from the presentation value, so an early sample redirects rather than jumps, and the fill never runs past what was reported, leaving a stall honest. Drive both modes without a real download via the debug channel's `set_loading`.

**Waveform data arriving ends the sweep but not the fill** — a disk-cached waveform can land while the provider is still materializing the audio, so the fill riding over the drawn waveform is the only remaining sign of the download. That is `endSweepKeepingFill`, whose answer tells the caller whether anything is left to keep.

**TRAP: the band sweeps in from before its span and out past the end, and the view's own layer does not mask to bounds** — so it rides inside a `masksToBounds` clip layer (`_shimmerClip`) sized to that span. Without it the shimmer draws over the artwork on one side and out to the window edge on the other.

**TRAP: reinstall the sweep animation only when its endpoints actually change.** Live resize lands in `installSweepAcrossRemainder:bandWidth:` every frame, and an unconditional remove-and-re-add restarts the 1.2s sweep each time, freezing the band at the left edge.

**TRAP: when the sweep *is* reinstalled, carry the running animation's phase over**, or the retargeted band snaps back to the left edge. The phase is elapsed time plus the previous carry-over — `animationForKey:` returns a copy that preserves `timeOffset`, so dropping it loses the phase on every reinstall after the first. `beginTime` is 0 until the first transaction commit stamps it; treat elapsed as 0 then.

## The convert sweep

Convert to FLAC's progress is drawn *with the waveform itself*: the bars the sweep front crosses collapse to the midline and ease back, a brush moving through the waveform at conversion pace. There is no separate progress element.

It rides the morph engine's displayed-vs-target split. `dipDisplayedSamplesFromFraction:toFraction:` zeroes the displayed samples in the newly crossed span, rebuilds once so the notch is seen at zero, and starts the standard ease back toward the unchanged target — so bars dipped earlier have recovered more and the graded trail behind the front falls out for free. Both families forward `dipBarsFromFraction:toFraction:` to their engine; an x fraction maps to the raw sample array linearly in both layouts, because samples run left to right.

## Accessibility

**The waveform is a slider, on both platforms**, because it is the only way to seek by pointer or touch and there is no other seek control to fall back to: `AudioWaveformView` answers `NSAccessibilitySliderRole`, `WaveformScrubberView` carries `UIAccessibilityTraitAdjustable`, both label themselves `STR_A11Y_WAVEFORM` and report the playhead as a spoken percentage. Before that the whole strip was an unlabelled group and the app had no reachable seek at all.

Two things are deliberate and shared. **The step is a fraction of the track — 5% — not a number of seconds**, because neither view knows the duration: each is handed a 0–1 progress and reports a 0–1 seek, and nothing else. And **an adjustment reports the seek and waits for the position to come back** through the owner's normal progress write, exactly as a click or a released scrub does; writing the local progress would show a playhead that had not moved and then fight the next tick.

The value is a percentage *string* (`Formatters.percentString:`) rather than the raw fraction, because VoiceOver reads a bare number verbatim — 0.5 is announced as "zero point five".

The iOS view is adjustable only while `scrubbingEnabled`, so the swipe gesture is not offered for a scrubber with nothing loaded; the mac view's increment returns NO in the same state. The iOS `accessibilityIdentifier` is a separate thing with a separate purpose — it names the element for the XCUITest touch driver's pinch — and neither depends on the other.

## Language

These files are `.mm` because they hold the C++ sample vectors. Keep the C++ types out of any header that plain ObjC (`.m`) files import.
