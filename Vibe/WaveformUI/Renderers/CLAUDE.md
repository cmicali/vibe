# Waveform renderers

The strategies both views draw through, the morph engine they share and the level mapping. `AudioWaveformRenderer` is the base; `WaveformRendererRegistry` is the one home of identifier → renderer and of the fallback chain for a persisted style, so the two platforms cannot drift on which styles exist. Every header here carries C++ — `.mm` importers only (`../CLAUDE.md`).

**Compare styles by identifier, never by class.** Variants share classes — Wiggle and Wiggle MC are `DetailedAudioWaveformRenderer`, the oversampling trio share a file, Cupertino subclasses Basic — and the resolved registry identifier is what persists. `wiggle` stays with Wiggle MC so saved selections keep their geometry.

The registry's settings preview renders the actual style into a static bitmap with the caller's palette, density, width and levels. Its shared synthetic sample includes fine transients: a smooth envelope alone hides the Detailed family's sampling differences at thumbnail size. Preview rendering never changes the live renderer's geometry or sampling counts.

## Families

Two families and one flat style, split by *how progress and hover quantize*:

- **Continuous** — Detailed, its oversampling variants, Wiggle and Wiggle MC: the played clip edge is the playhead, hover lights a thin slice (a whole loop for Wiggle, so it does not flicker into dots between strokes).
- **Block** — Basic, Cupertino, Sonic Cirrus: hover lights the whole block under the cursor and the played fill advances a block at a time. `VibeBlockIndexForX`/`VibeBlockBoundaryForProgress` (`AudioWaveformRenderer.h`) are the one home of both rules. **Presentation only: the seek a hover or click reports stays continuous.**
- **Cupertino Basic** — the Apple Music pill, the one style that never reads the samples. It has no morph engine, so settle and the convert dip are base no-ops and it never bakes; having a waveform at all decides only whether the pill shows.

**Wiggle draws its centerline directly** — a shape-layer stroke live, a source-in Core Graphics stroke in the bitmap, both from `VibeNewWigglePath`. Never expand it into a filled outline first: that repeats the stroker's work on every resize and morph frame.

## Level mapping

**Bar heights draw energy, not peaks.** `VibeWaveformBarLevel` (`WaveformLevelMath.h`, Foundation-free so `WaveformLevelMathTests` pins it) is the one chunk-to-level mapping: RMS against `kVibeWaveformFullScaleRMS`. Peaks peg on limited masters — at Basic's pitch every bar held a full-scale kick and the strip read as a block. This is the one deliberate geometry change from the pre-theme look (root `CLAUDE.md`).

**Every bar-level consumer maps through `VibeWaveformEnergyColumnForBar`**, which floors the energy window at 1/1024 of the track (`kVibeWaveformEnergyColumns`) however fine the bars: RMS over less than a beat converges back to peak, which re-pegged the oversampling styles' one-chunk bars. Only the level is floored. The Detailed family keeps its min/max envelope as the *shape*, rescaled so its larger extent is the level, through `fillEnvelope:` — the one sampling hook behind both the live target and the envelope bake; Cupertino overrides it to ±level, and Sonic Cirrus and Wiggle sample through `fillEnergyLevels:count:stride:waveform:`.

**Normalize and Gain are the renderer's `normalizesLevels` and `gainDB`, handed over by each view as the theme is.** Normalize only raises: `VibeWaveformFullScaleRMSForWaveform` caps the track's loudest column at the fixed reference, measured over the drawn count (capped at 1,024) so it matches the windows the bars draw. Gain is a display gain ahead of the clamp plus a proportional curve bend (`kVibeWaveformGainDBPerExponentDoubling`). **A level change is a target change under the same identity**, which the morph's fast path would skip, so both setters call `invalidateTarget` and the bars ease to their new heights. Cupertino Basic ignores both.

## Bar count and thickness

**The count follows the drawn width at the style's designed pitch**, so a resize adds bars rather than stretching them. Basic, Cupertino and Sonic Cirrus share `blockBarCountForWidth:` (4pt, capped at 1,024); Detailed and Wiggle use `numBarsForWidth:`. `barDensity` multiplies the block and Wiggle counts, defaulting to 1; Detailed and its fixed-count oversampling variants ignore it, as does the flat Cupertino Basic pill. The registry gates density and width separately; width also scales Cupertino Basic's resting and hovered pill heights, with its seek band covering the enlarged pill. `barWidthScale` scales the supported styles' bar thickness (Wiggle's stroke) without changing the count; discrete bars share `scaledBarWidth:pitch:` to stop at their slot edges. Wiggle's live stroke, hover and bitmap bake share the scaled geometry. Wiggle's count reads `samplingWidth` when set, so an iOS pinch stretches its loops instead of resampling them (`../iOS/CLAUDE.md`).

## The morph engine

`WaveformMorphEngine` owns the displayed and target vectors, the 60 Hz ease and the retarget decision tree; each family installs a geometry callback and a fill. **Do not duplicate it per family** — near-identical copies diverge. Its header states the decision tree; the rules a caller is checked against:

- **`identity` is compare-only and never dereferenced.** It cannot false-match because the view retains the old waveform while the new one is allocated.
- **A geometry change rebuilds instantly; a content change eases.** A settled waveform's count change installs the new samples in one rebuild, and a resize mid-morph resamples the displayed bars and keeps easing, so loading, gain and the convert sweep survive a resize.
- **A nil↔non-nil identity flip always rebuilds**: a silent track's all-zero waveform is sample-identical to the collapsed target but draws hairlines. `barMinHeight` — 1 with a waveform, 0 without — is the engine's policy so both families agree.
- **The Detailed family pixel-rounds only when settled**; mid-morph rounding quantizes the motion into visible steps.
- **`settleImmediately` exists because every morph frame is a full-view repaint** — for Detailed a 4,096-rect mask path — and a couple of pager cells easing at once blow a scroll's frame budget. The base forwards it as `settleMorphImmediately`.

## The convert sweep

**Convert to FLAC's progress is drawn with the waveform itself; there is no separate progress element.** `dipBarsFromFraction:toFraction:` → `dipDisplayedSamplesFromFraction:toFraction:` zeroes the displayed samples in the newly crossed span, rebuilds once so the notch is seen at zero, and lets the standard ease carry them back to the unchanged target, so the graded trail behind the front falls out for free. The span rounds outward to `samplesPerBar` so an edge bar is never half-zeroed; a fraction maps to the array linearly in both families because samples run left to right. Keeping the front and feeding only the new span is `../Mac/CLAUDE.md`'s; reporting the fractions is `Audio/Mac/Convert/CLAUDE.md`'s.

## The envelope bake

`DetailedAudioWaveformRenderer`'s envelope-image API exists for the iOS scrubber's settled fast path (`../iOS/CLAUDE.md`); the mac view never calls it. **The bitmap must stay pixel-identical to the live layers**: both go through `fillBarRects` for geometry and pixel rounding (bitmap workers on their own scratch, off the live mask's state), `VibeNewWigglePath` for lines and `gradientColorsForColor:` for stops, and the bitmap's gradient endpoints are `configureGradient:`'s band. **A subclass that changes its gradient aim or fill quantization must answer `supportsEnvelopeBake` for itself** — Basic overrides it back to NO and Cupertino inherits that. While `unplayedSharesPlayedHue`, the unplayed side is the played bitmap at `unplayedOverPlayedOpacity`, valid because both sides share the ramp; a two-hue theme bakes the unplayed image separately, doubling that cell's bitmap bytes — a trade `WaveformZoomMath.h`'s budget does not model.
