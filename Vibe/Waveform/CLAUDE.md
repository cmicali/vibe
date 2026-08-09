# Waveform rendering

This directory is the *rendering* half of the two-layer waveform system. The data layer — generation, caching and BPM analysis — lives in `Vibe/Audio/Waveform/` and `Vibe/Audio/Analysis/`; see `Vibe/Audio/CLAUDE.md`.

## The view and its renderers

`AudioWaveformView` is a CALayer-based `NSView` that delegates rendering to strategy objects. It is a pure rendering surface: `MainPlayerController` owns the `AudioWaveformCache`, symmetrically with `metadataCache`, requests loads and forwards deliveries to the view through `TrackDisplayController`'s pass-throughs — `prepareForWaveformLoad` to reset, then `showWaveform:`.

The view also draws the two non-waveform states: a sweeping shimmer while a slow file open is pending (`showLoadingIndicator`) and a static midline for the no-track empty state (`showEmptyPlaceholder`). The two are mutually exclusive, and `prepareForWaveformLoad` clears both.

The renderer hierarchy runs from the `AudioWaveformRenderer` base to `SonicCirrusWaveformRenderer`, whose display name is "Sonic Cirrus", and `DetailedAudioWaveformRenderer`. `BasicAudioWaveformRenderer` and the `x2`, `x4` and `x8OversamplingDetailedAudioWaveformRenderer` classes, all in one shared file, subclass `DetailedAudioWaveformRenderer`. Both families animate through a shared `WaveformMorphEngine`, which owns the displayed and target sample vectors, the 60 Hz easing timer and the retarget decision tree; renderers supply only target-building and layer geometry. The default style is "Oversampling Detailed x4", configurable in `AppSettings`.

## The convert sweep

Convert to FLAC's progress is drawn *with the waveform itself*: the bars the sweep front crosses collapse to the midline and ease back, a brush moving through the waveform at conversion pace. There is no separate progress element.

It rides on the morph engine's displayed-vs-target split. `WaveformMorphEngine.dipDisplayedSamplesFromFraction:toFraction:` zeroes the displayed samples in the newly crossed span, rebuilds once so the notch is seen at zero, and starts the standard ease back toward the unchanged target — bars dipped earlier have recovered more, so the graded trail behind the front falls out for free. Both families forward `dipBarsFromFraction:toFraction:` to their engine; an x fraction maps to the raw sample array linearly in both layouts, because samples run left to right.

`AudioWaveformView.convertSweepFraction` keeps the front and dips only the span since the last set, so bars behind the front are never re-zeroed mid-recovery. It gates on having a waveform, like hover, and resets in `prepareForWaveformLoad` and the empty and loading states. A value at or below the front just moves the front — that is the post-conversion reset.

## Hover scrubbing

While the cursor is over a loaded waveform, the waveform's own column under the cursor is lit to full brightness. Nothing is drawn on top of it, and there is no tooltip.

The view only routes the cursor's x to the renderer, through `setHoverHighlightX:`, where a negative value clears the highlight, because the two renderer families need opposite mechanisms. The Detailed family adds a flat full-alpha column layer inside `_waveformContainer`, so the shared bar mask clips it to the envelope for free; it is a couple of points wide, since one bar is sub-point at 1024 bars or more. Sonic Cirrus, whose bars are discrete layers with gaps, instead snaps to a bar index and recolors that bar's two layers, because a fixed-width column there could land in a gap and light nothing.

Sonic Cirrus must restore the bar's *resting* played or unplayed color when the hover moves off, and re-apply the highlight after `updateProgress:` repaints a range covering it. Otherwise the playhead crossing the hovered bar, or a full repaint after `updateColors:`, erases it. Renderers keep the x so a resize can re-place the highlight.

The view gates on having a waveform at all, which is how the empty, loading and parked states opt out, and the state transitions that clear the waveform also clear the highlight. Click-to-seek is unchanged.

## Language

These files are ObjC++ (.mm) because they hold the C++ sample vectors. Keep the C++ types out of any header that plain ObjC (.m) files import.
