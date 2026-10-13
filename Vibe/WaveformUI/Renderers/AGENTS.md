# Waveform renderers

The strategies both views draw through, the morph engine they share and the level mapping. `WaveformRenderer` is the base. `WaveformRendererRegistry` is the one home of identifier to renderer and of the fallback chain for a persisted style, so the two platforms cannot drift on which styles exist. The renderer and morph-engine headers carry C++ and are for `.mm` importers only (`../AGENTS.md`). A `.m` may import three headers here. `WaveformRendererRegistry.h` is plain ObjC. `WaveformLevelMath.h` holds the level mapping and the bar-count rules. `WaveformBarMath.h` holds the bar geometry. Both math headers are C++-free. `WaveformBarMath.h` needs CoreGraphics for its rects.

**Compare styles by identifier, never by class.** Variants share classes. Wiggle is `DetailedWaveformRenderer`, the oversampled types share a file, Cupertino subclasses Bars, and Spectrum subclasses 3-Band in 3-Band's file. The resolved registry identifier is what persists. Wiggle's is `wiggle_centered` whatever Centered says. Bars persists as `basic` and its class is `BasicWaveformRenderer`. Progress persists as `cupertino_basic` and its class is `CupertinoBasicWaveformRenderer`. Both keep the names they shipped under. The retired `wiggle` (Wiggle MC) is read only by the migrations that turn it into Wiggle with Centered off.

The registry's bake renders the real style into a bitmap with the caller's palette, density, width and levels. The settings preview and the iOS widget use it. Its synthetic preview sample includes fine transients, because a smooth envelope hides the Detailed family's sampling differences at thumbnail size. A bake never changes a live renderer's geometry. Under a theme's `playheadColor` the bake draws what the views draw: the waveform wholly played and the line at the progress (`../AGENTS.md`).

## Families

Two families and one flat style, split by how progress and hover quantize:

- **Continuous**: Detailed in every type, Wiggle, 3-Band and Spectrum. The played clip edge is the playhead. Hover lights a thin slice, or a whole loop for Wiggle so it does not flicker into dots between strokes.
- **Block**: Bars, Cupertino and Sonic Cirrus. Hover lights the whole block under the cursor, and the played fill advances a block at a time. `VibeBlockIndexForX` and `VibeBlockBoundaryForProgress` hold both rules. Their one home is `WaveformBarMath.h`. **This is presentation only. The seek a hover or click reports stays continuous.**
- **Progress** is the Apple Music pill, the one style that never reads the samples. It has no morph engine, so settle and the convert dip are base no-ops and it has no envelope bake. The registry can still render its layers into a bitmap. Having a waveform decides only whether the pill shows.

**Detailed is one style with four types**: Detailed and Oversampled 2x, 4x and 8x. Each type keeps its own identifier and class. The type is the persisted style. It needs no setting of its own. `styleIdentifiers` lists every style once, in chooser order, with the family under its 4x type. Choosing Detailed from another style lands on the 4x type. Choosing Detailed while it is current keeps the type. `typeIdentifiersForIdentifier:` feeds each platform's Type chooser. Every other registry query takes the type's identifier.

**Wiggle draws its centerline directly.** It is a shape-layer stroke live and a source-in Core Graphics stroke in the bitmap, both from `VibeNewWigglePath`. Never expand it into a filled outline first. That repeats the stroker's work on every resize and morph frame.

## Level mapping

**Bar heights draw energy, not peaks.** `VibeWaveformBarLevel` (`WaveformLevelMath.h`, pinned by `WaveformLevelMathTests`) is the one chunk-to-level mapping: RMS against `kVibeWaveformFullScaleRMS`. Peaks peg on limited masters, and the strip reads as a block.

**Every bar's level is read through `AudioWaveform`'s `getBarMeanSquares`, with a reach** (`Audio/Waveform/AGENTS.md` has the mechanism). Without it, bars about a beat long ripple as a resize moves their edges. A wider tapered window holds stiller, but it averages every hit into its neighbours, and zoomed in the kicks are the picture. **The reach fades out as the bars get short** (`VibeWaveformWindowReach`). Bars fine enough to draw each hit need none, and the reach would fatten every hit by a bar. 3-Band and Spectrum take the whole reach up to 2,048 bars and none from 4,096. The other styles take it whole up to 512 bars and none at 1,024. **A style that reads a level any other way brings the ripple back.**

**Every bar-level consumer but 3-Band and Spectrum reads energy columns** (`energyColumnLevelsForBarCount:waveform:`). A column is never finer than 1/1024 of the track (`kVibeWaveformEnergyColumns`). RMS over less than a beat converges back to peak and would peg the oversampled types' one-chunk bars. Past 1,024 bars, `VibeWaveformEnergyColumnIndexForBar` maps each bar to its column. Only the level is floored. The Detailed family keeps each bar's own min and max envelope as the *shape*, scaled so its column's peak draws the column's level. The `TRAP:` in `fillEnvelope:` explains which peak. `fillEnvelope:` is the one sampling hook behind both the live target and the envelope bake. Cupertino overrides it to ±level. Sonic Cirrus and Wiggle sample through `fillEnergyLevels:count:stride:waveform:`.

**Normalize and Gain are the renderer's `normalizesLevels` and `gainDB`.** Each view hands them over as it does the theme. Normalize only raises. `VibeWaveformFullScaleRMSForColumns` caps the track's loudest column at the fixed reference, read from the columns the fill just took, so it costs no second pass. 3-Band and Spectrum measure their own reference on the same rules (below). **Normalize waits for the whole track** (`AudioWaveform`'s `isComplete`). A streaming load's loudest column is only the loudest so far, so a reference re-measured per delivery would shrink bars already drawn. A partial waveform draws at the fixed reference, and the completing delivery raises it. While Gain is 0 the raise is one vertical scale (`normalizationGainForWaveform:`), which the iOS scrubber grows its bitmap into. Gain is a display gain ahead of the clamp plus a curve bend (`kVibeWaveformGainDBPerExponentDoubling`). **A level change is a target change under the same identity**, which the morph's fast path would skip. So both setters call `invalidateTarget` and the bars ease to their new heights. Progress ignores both.

## Centered

**`centered`, on by default, draws about the midline. Off grounds every bar on the band's foot (`VibeBarBaseline`)** at the height it had about the midline. The level mapping and the seek band stay as they are. **The ramp reaches below the band, so a grounded foot is as bright as the midline it left** (`VibeBarRampDrop`). Without the drop, every quiet grounded bar sat in its dimmest stretch. Three geometry homes read `centered`: `fillBarRects` (Detailed, Bars and Cupertino), `VibeAddThreeBandPaths` and `VibeNewWigglePath`. Cupertino's fade mirrors its bars about the midline, so grounded it takes Bars' ramp. Sonic Cirrus and Progress ignore it (`supportsCenteringForIdentifier:`). The mac view takes it from its theme's `waveformCentered`. iOS takes `AppSettings.waveformCenteredForWidget:`, the card's or the widget's copy. Each settings switch dims for a style that ignores it.

## Bar count and thickness

**The count follows the drawn width at the style's designed pitch**, so a resize adds bars rather than stretching them. Bars, Cupertino and Sonic Cirrus share `blockBarCountForWidth:` (4pt, capped at 1,024). Detailed and Wiggle use `numBarsForWidth:`. `barDensity` multiplies the block and Wiggle counts. Detailed in every type and Progress ignore it. The oversampled types keep fixed counts. `barWidthScale` scales bar thickness, or Wiggle's stroke, without changing the count. Discrete bars share `scaledBarWidth:pitch:` to stop at their slot edges. Width also scales Progress's pill heights. The registry gates density and width separately. Wiggle's count reads `samplingWidth` when set, so an iOS pinch stretches its loops instead of resampling them (`../iOS/AGENTS.md`).

## The morph engine

`WaveformMorphEngine` owns the displayed and target vectors, the 60 Hz ease and the retarget decision tree. Each family installs a geometry callback and a fill. **Do not duplicate it per family.** Its header states the decision tree. The rules a caller is checked against:

- **`identity` is compare-only and never dereferenced.** It cannot false-match, because the view retains the old waveform while the new one is allocated.
- **A geometry change rebuilds at once. A content change eases.** A settled waveform's count change installs the new samples in one rebuild. A resize mid-morph resamples the displayed bars and keeps easing, so loading, gain and the convert sweep survive a resize.
- **A nil to non-nil identity flip rebuilds even when the samples are unchanged.** A silent track's all-zero waveform equals the collapsed target, but it draws hairlines. `barMinHeight` is 1 with a waveform and 0 without, and both families read it from the engine.
- **The Detailed family pixel-rounds only when settled.** Rounding mid-morph quantizes the motion into visible steps.
- **`settleImmediately` exists because every morph frame is a full-view repaint.** Detailed can rebuild thousands of bars per frame. Settling an unseen renderer avoids that work. The base forwards it as `settleMorphImmediately`.

## The convert sweep

**Convert to FLAC's progress is drawn with the waveform itself.** `dipBarsFromFraction:toFraction:` calls `dipDisplayedSamplesFromFraction:toFraction:`. That zeroes the displayed samples in the newly crossed span and rebuilds once, so the notch shows at zero. The standard ease then carries them back to the unchanged target, which draws the graded trail. The span rounds outward to `samplesPerBar`, so an edge bar is never half-zeroed. Keeping the front and feeding only the new span is `../Mac/AGENTS.md`'s. Reporting the fractions is `Mac/Convert/AGENTS.md`'s.

## The envelope bake

The envelope-image API (`WaveformRenderer.h`, beside `supportsEnvelopeBake`) serves the iOS scrubber (`../iOS/AGENTS.md`). The mac view never calls it. Detailed, 3-Band and Spectrum implement it. **The bitmap must stay pixel-identical to the live layers.** So both paths share every geometry and color home:

- `fillBarRects` for bar geometry and pixel rounding. Bake workers use their own scratch, never the live mask's state.
- `VibeNewBarMaskPath` for the bars' mask, one outline where the bars abut.
- `VibeNewWigglePath` for lines, and `gradientColorsForColor:` for stops.
- `VibeAimBarGradient` and `VibeFillBarGradient` for the band the gradient is aimed at.
- `VibeAddThreeBandPaths` for 3-Band, whose bake applies the played side's mask stops over the same band.

**A subclass that changes its gradient aim or fill quantization must answer `supportsEnvelopeBake` for itself.** Bars overrides it back to NO, and Cupertino inherits that. A NULL unplayed bake means the unplayed side is the played bitmap at `unplayedOverPlayedOpacity`. Detailed answers NULL while the theme's `unplayedSharesPlayedHue`. A two-hue theme bakes the unplayed side separately, which doubles that cell's bitmap bytes. `WaveformZoomMath.h`'s budget does not model that. 3-Band and Spectrum always answer NULL.

## 3-Band

A DJ player's 3-band display: the low, mid and high bands' levels. **It is its own class because its fill is seven colored layers.** The Detailed family uses a theme gradient and one bar mask. Sonic Cirrus colors discrete layers. The morph engine carries three samples per bar. **The bands exist only in a waveform decoded for a request that asked for them** (`readsBandsForIdentifier:`, `Audio/Waveform/AGENTS.md`). A waveform without them draws the silent hairline until the band decode lands.

**Each height shows the set of bands reaching it.** Each layer is one polygon through the bars' centers, out to the lowest band of its set. It is mirrored about the midline or stands on the baseline. The layers paint in order: the three bands alone, the three pairs, then all three. A set's lowest band is never above a subset's, so the envelopes nest and the painter's order alone colors them. The fill's antialiasing smooths the steps between bars. Pixel-snapped columns would read as stair steps. `VibeAddThreeBandPaths` is the one home of the geometry, for the live layers and the bake alike. It also builds the hover slice's outline while the slice shows. 3-Band shares Detailed's band, seek band and hover slice (`VibeBarVScale`).

**The energy windows follow the drawn width, not the 1/1024 floor.** There is one bar per point, capped at 8,192 bars (`kVibeWaveformMaxBars`). Each has its own window and the reach above. Zoomed in, the scrubber's bars get short enough to draw each kick. Floored at 1/1024, a zoomed bar spans most of a beat, and kick and gap alias against the beat into a slow swell. Bars finer than a point flicker between kick and gap from bar to bar.

**Each band is measured against the broadband reference scaled by a per-band share** (`kBandShareOfFullScale`). The smaller mid and high shares keep those weaker bands visible beside the lows.

**Normalize measures the loudest band against its share**, not the full mix, so the tallest band at the loudest column reaches full height. **3-Band is its own reference, for speed.** Within 1,024 bars it reads the mean squares the fill just took. Past that it measures 1,024 columns the same way, so the reference does not step as a resize crosses 1,024 bars. The iOS scrubber always normalizes, so there the shares set only the balance. Gain moves all three bands alike.

**The fills are the theme's `bandColors`, in painter's order.** The theme also gives the gradient and the hover slice. The gradient is Detailed's ramp over Detailed's band, which `flatFill` drops. It is not a fade mirrored about the midline, because the outer ring is most of what 3-Band shows. The palettes are `WaveformTheme`'s (`../AGENTS.md`). **The seven layers are drawn once, under one mask with two sides** split at the playhead. The played side is at full level, the unplayed at half, and each carries the ramp. A second dimmed stack would hand every rebuild's paths to fourteen layers, each copying its path. The mask dims the composited stack, so the outer rings never show through the inner ones.

## Spectrum

`SpectrumWaveformRenderer` subclasses 3-Band in `ThreeBandWaveformRenderer.mm`. It shares the height mapping, reach, normalization and morph. Each bar is as tall as its tallest band. The count follows the width in backing pixels, capped at 8,192 bars. A backing-scale change takes effect on the next waveform update.

Each bar carries three height levels and three color levels. **Colors use the bar's own window, without the height mapping's reach or clamp.** `getBarMeanSquares` supplies both in one pass. Each color level is RMS divided by its band's reference. Display gain affects only heights. `VibeSpectrumColor` weights the primaries by the fourth power of these levels. It restores the weighted brightness of the primaries after mixing. Silence uses their plain mean. Only the level ratios affect color. No beat or section detection is involved.

`VibeNewSpectrumStrip` interpolates between neighboring bar colors into a one-row image at backing resolution. The live layer and bake mask this strip with the same tallest-band outline. Nearest filtering avoids another interpolation. Spectrum always uses a flat fill. The unplayed side has half the played side's opacity. The hover outline stays current on every rebuild.

Spectrum reads `spectrumColors`. Each renderer declares its palette through `paletteKind`. The registry uses that choice for the settings palettes and theme-list swatches. Spectrum's palettes are RGB, Blue, Green and Custom (`../AGENTS.md`). Custom shares 3-Band's Low, Mid and High wells.
