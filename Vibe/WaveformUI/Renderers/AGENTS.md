# Waveform renderers

The strategies both views draw through, the morph engine they share and the level mapping. `WaveformRenderer` is the base. `WaveformRendererRegistry` is the one home of identifier to renderer and of the fallback chain for a persisted style, so the two platforms cannot drift on which styles exist. The renderer and morph-engine headers carry C++ and are for `.mm` importers only (`../AGENTS.md`). A `.m` may import three headers here. `WaveformRendererRegistry.h` is plain ObjC. `WaveformLevelMath.h` holds the level mapping. `WaveformBarMath.h` holds the bar geometry. Both math headers are C++-free. `WaveformBarMath.h` needs CoreGraphics for its rects.

**Compare styles by identifier, never by class.** Variants share classes. Wiggle is `DetailedWaveformRenderer`, the oversampled types share a file, Cupertino subclasses Bars, and Spectrum subclasses 3-Band in 3-Band's file. The resolved registry identifier is what persists. Wiggle's is `wiggle_centered` whatever Centered says. Bars persists as `basic` and its class is `BasicWaveformRenderer`. Progress persists as `cupertino_basic` and its class is `CupertinoBasicWaveformRenderer`. Both keep the names they shipped under. The retired `wiggle` (Wiggle MC) is read only by the migrations that turn it into Wiggle with Centered off.

The registry's bake renders the real style into a bitmap with the caller's palette, density, width and levels. The settings preview and the iOS widget use it. Its synthetic preview sample includes fine transients, because a smooth envelope hides the Detailed family's sampling differences at thumbnail size. A bake never changes a live renderer's geometry. Under a theme's `playheadColor` the bake draws what the views draw: the waveform wholly played and the line at the progress (`../AGENTS.md`).

## Families

Two families and one flat style, split by how progress and hover quantize:

- **Continuous**: Detailed in every type, Wiggle, 3-Band and Spectrum. The played clip edge is the playhead. Hover lights a thin slice, or a whole loop for Wiggle so it does not flicker into dots between strokes.
- **Block**: Bars, Cupertino and Sonic Cirrus. Hover lights the whole block under the cursor, and the played fill advances a block at a time. `VibeBlockIndexForX` and `VibeBlockBoundaryForProgress` hold both rules. Their one home is `WaveformBarMath.h`. **This is presentation only. The seek a hover or click reports stays continuous.**
- **Progress** is the Apple Music pill, the one style that never reads the samples. It has no morph engine, so settle and the convert dip are base no-ops. The registry can still render its layers into a bitmap. Having a waveform decides only whether the pill shows.

**Detailed is one style with four types**: Detailed and Oversampled 2x, 4x and 8x. Each type keeps its own identifier and class. The type is the persisted style. It needs no setting of its own. `styleIdentifiers` lists every style once, in chooser order, with the family under its 4x type. Choosing Detailed from another style lands on the 4x type. Choosing Detailed while it is current keeps the type. `typeIdentifiersForIdentifier:` feeds each platform's Type chooser. Every other registry query takes the type's identifier.

## Pictures

**Every style but Sonic Cirrus and Progress draws a picture into a layer's contents.** The Detailed family draws coverage, white and premultiplied, into its mask, which cuts both gradients and the hover slice to the waveform. 3-Band and Spectrum paint their colors into one layer under the sides' mask. A rebuild draws the picture once, from the displayed samples, and installs it with actions off. The layer tree never holds a path, so a moving or scrolling waveform costs the render server no scan conversion. `VibeNewLayerImage` (`WaveformRenderer.h`) is the one image factory. **A picture is painted in its window's color space** (`pictureColorSpace`, which the mac view sets). Core Animation color-matched an sRGB picture at every commit, which took half the main thread while a long file loaded on an external display. 3-Band and Spectrum convert their fills into it once.

- **TRAP: a picture is 32-bit premultiplied ARGB, never an alpha-only image.** An alpha-only mask draws nothing under `renderInContext:`, which the registry's bake uses.
- **TRAP: in a `geometryFlipped` tree a layer shows its contents upside down.** The iOS host is one. A picture for a layer whose `contentsAreFlipped` is written bottom-up, which `VibeNewLayerImage` does from the flag.

**The picture covers `renderRect`, by default the whole bounds** (`renderPixelsForSize:`). The layer's frame is that window, so a view far wider than the screen can draw only the stretch it shows. A window that moves with nothing else changed redraws.

**Wiggle draws its centerline directly.** Core Graphics strokes `VibeNewWigglePath` into the mask's picture. Never expand it into a filled outline first. That repeats the stroker's work on every resize and morph frame.

## Zoom steps

**The Detailed types, 3-Band and Spectrum read the waveform only at zoom steps** (`Packages/WaveformCore/AGENTS.md`). A step's columns cover fixed frames of the track. Each view draws the two steps around its scale and crossfades them by how near it is to each. A resize inside a step reads nothing new. It only resamples the same columns onto the new pixels, so every pixel changes continuously and nothing reshuffles. Columns read per pixel instead re-partition the track on every resize, and fine texture ripples.

**A style wants a number of columns a point** (`columnsPerPoint`, or the rate it passes to `updateStepTargetForSize:`). Detailed wants 2, and Oversampled 2x, 4x and 8x want 4, 8 and 16. That oversampling is their look, the same at every width. 3-Band wants one a point, so zoomed in it resolves each hit. Spectrum wants one a pixel, since its colors change from pixel to pixel. The Detailed types land each column in the pixels it overlaps by its share, so a pixel's coverage is the mean of its columns' spans (`ColumnCoverage`). 3-Band and Spectrum read their levels linearly between column centers, as their polygons did.

**The samples are laid out by the window's columns** (`_window`, part after part). `updateStepTargetForSize:` tells the morph engine when the columns change. A settled change installs at once. One that eases first moves the displayed samples to the new layout by the track's frames (`RemapStepSamples`), so a resize across a step or a scroll mid-morph keeps its motion.

**The base renderer owns the window.** It rebuilds a picture whose window moved with nothing else changed (`rebuildIfWindowMoved`), as the scrubber scrolls. It dips a step style's columns for the convert sweep. It refills the columns when deep zoom's blocks land in the waveform's detail, and they ease to the finer picture.

**Each style says how deep a zoom may show it** (`minimumFramesPerPointForWaveform:`). The bar styles stop where their 1,024 bars stop growing in number, since past that they only widen. 3-Band, Spectrum and Wiggle stop at two bins a point. The Detailed types reach the stream's own frames once the waveform is complete.

## Level mapping

**A height draws the loudest short window, not the mean and not the peak.** Every style reads a column's `loudest` (`Audio/Waveform/AGENTS.md`): the RMS of the loudest 20 ms it covers. `VibeWaveformBarLevel` (`WaveformLevelMath.h`, pinned by `WaveformLevelMathTests`) is the one level mapping: that RMS against `kVibeWaveformFullScaleRMS`. **Transients outrank energy.** A mean over a coarse column averages each hit into the sound around it, so zoomed out the kicks vanish. Peaks peg on limited masters, and the strip reads as a block. The loudest window still rises on each kick. It is a union, so a resize that moves a column's edges cannot hide a hit or ripple the levels.

**The bar styles read count bars' own levels across the track** (`fillLevels:`, and Bars through Detailed's `fillColumns:`). Bars, Cupertino, Sonic Cirrus and Wiggle never draw more than 1,024, so a bar is never finer than `kVibeWaveformLevelColumns`. Bars keeps each bar's min and max as its shape, scaled so its peak draws its level. Cupertino draws ±level.

**The Detailed types scale each column's own min and max by the level around it** (`fillColumns:`). DC-offset asymmetry and fine texture survive, and the heights still follow the level. The level is read on a grid of its own, no finer than 1/1024 of the track, so zoomed in the stream's own shape draws under one smooth gain. A column scales by the level over its peak, read linearly between the grid columns' centers, so no edge of the grid shows when zoomed in. **TRAP: the level grid is never finer than four pixels** (`kLevelPixels`). Its levels change from column to column, and finer than a pixel they alias into a comb that slides as a resize moves it. The grid is a multiple of the step's own columns, so a step keeps one grid at every width. The `TRAP:` in `fillColumns:` explains the cap that keeps quiet columns beside a transient quiet.

**Normalize and Gain are the renderer's `normalizesLevels` and `gainDB`.** Each view hands them over as it does the theme. In the mix styles Normalize only raises. `VibeWaveformFullScaleRMSForWaveform` caps the track's loudest window at the fixed reference. **The reference is the track's, never the drawn bars'**, so a resize cannot move it. Read from the drawn bars, it moved 2 to 11% as their count changed, and the whole picture breathed. Every column's level is a union, so the column holding the loudest window reaches full height in every style. 3-Band and Spectrum measure their own reference on the same rule (below).

**Normalize waits for the whole track** (`AudioWaveform`'s `isComplete`). A streaming load's loudest window is only the loudest so far, so a reference re-measured per delivery would shrink bars already drawn. A partial waveform draws at the fixed reference, and the completing delivery raises it. Gain is a display gain ahead of the clamp plus a curve bend (`kVibeWaveformGainDBPerExponentDoubling`). **A level change is a target change under the same identity**, which the morph's fast path would skip. So both setters call `invalidateTarget` and the bars ease to their new heights. Progress ignores both.

## Centered

**`centered`, on by default, draws about the midline. Off grounds every bar on the band's foot (`VibeBarBaseline`)** at the height it had about the midline. The level mapping and the seek band stay as they are. **The ramp reaches below the band, so a grounded foot is as bright as the midline it left** (`VibeBarRampDrop`). Without the drop, every quiet grounded bar sat in its dimmest stretch. Three geometry homes read `centered`: `VibeFillSpans` (Detailed, Bars and Cupertino), 3-Band's `rebuildPicture` and `VibeNewWigglePath`. Cupertino's fade mirrors its bars about the midline, so grounded it takes Bars' ramp. Sonic Cirrus and Progress ignore it (`supportsCenteringForIdentifier:`). The mac view takes it from its theme's `waveformCentered`. iOS takes `AppSettings.waveformCenteredForWidget:`, the card's or the widget's copy. Each settings switch dims for a style that ignores it.

## Bar count and thickness

**The count follows the drawn width at the style's designed pitch**, so a resize adds bars rather than stretching them. Bars, Cupertino and Sonic Cirrus share `blockBarCountForWidth:` (4pt, capped at 1,024). Wiggle uses `numBarsForWidth:`. `barDensity` multiplies the block and Wiggle counts. Detailed in every type and Progress ignore it. The step styles draw their columns a point instead. `barWidthScale` scales bar thickness, or Wiggle's stroke, without changing the count. Discrete bars share `scaledBarWidth:pitch:` to stop at their slot edges. Width also scales Progress's pill heights. The registry gates density and width separately. Wiggle's count reads `samplingWidth` when set, so an iOS pinch stretches its loops instead of resampling them (`../iOS/AGENTS.md`).

## The morph engine

`WaveformMorphEngine` owns the displayed and target vectors, the 60 Hz ease and the retarget decision tree. Each family installs a geometry callback and a fill. **Do not duplicate it per family.** Its header states the decision tree. The rules a caller is checked against:

- **`identity` is compare-only and never dereferenced.** It cannot false-match, because the view retains the old waveform while the new one is allocated.
- **A geometry change rebuilds at once. A content change eases.** A settled waveform's count or layout change installs the new samples in one rebuild. A resize mid-morph carries the displayed samples over and keeps easing, so loading, gain and the convert sweep survive a resize. A step style carries them by the track's frames (Zoom steps, above). The others carry them by nearest bar.
- **A nil to non-nil identity flip rebuilds even when the samples are unchanged.** A silent track's all-zero waveform equals the collapsed target, but it draws hairlines. `barMinHeight` is 1 with a waveform and 0 without, and both families read it from the engine.
- **The Detailed family pixel-rounds only when settled.** Rounding mid-morph quantizes the motion into visible steps.
- **`settleImmediately` exists because every morph frame is a full repaint.** Settling an unseen renderer avoids that work. The base forwards it as `settleMorphImmediately`.
- **An empty view keeps no buffers sized for the waveform it last drew.** A cleared picture eases flat, and once it settles the engine drops its samples and keeps an empty target until a waveform arrives. The families then drop their own fill and span buffers, and the picture's contents go. Kept, they held about 7 MB at rest with no track loaded.

## The convert sweep

**Convert to FLAC's progress is drawn with the waveform itself.** `dipBarsFromFraction:toFraction:` zeroes the displayed samples in the newly crossed span and rebuilds once, so the notch shows at zero. The standard ease then carries them back to the unchanged target, which draws the graded trail. The span rounds outward to whole bars, or for a step style to whole columns of each step, so an edge bar is never half-zeroed. Keeping the front and feeding only the new span is `../Mac/AGENTS.md`'s. Reporting the fractions is `Mac/Convert/AGENTS.md`'s.

## 3-Band

A DJ player's 3-band display: the low, mid and high bands' levels. **It is its own class because its fill is seven colors.** The Detailed family uses a theme gradient and one mask. Sonic Cirrus colors discrete layers. The morph engine carries three samples per column. **The bands exist only in a waveform decoded for a request that asked for them** (`readsBandsForIdentifier:`, `Audio/Waveform/AGENTS.md`). A waveform without them draws the silent hairline until the band decode lands.

**Each height shows the set of bands reaching it.** Each pixel column paints seven spans, each out to the lowest band of its set, mirrored about the midline or standing on the baseline. The spans paint in order: the three bands alone, the three pairs, then all three. A set's lowest band is never above a subset's, so the envelopes nest and the painter's order alone colors them. **A row takes each color by the area it shows there** (`ColumnPaint`). Painting coverage over coverage would stack edges that coincide, such as silence's hairline, into a bolder line. The levels read linearly between the columns' centers, so the tops are smooth. 3-Band shares Detailed's band, seek band and hover slice (`VibeBarVScale`). The hover slice is masked by the picture itself.

**Each band tops out at its own ceiling** (`kBandCeiling`): the lows the whole band, the mids three quarters, the highs half. So the bands nest as a DJ's waveform does, the lows outside and the highs as each hit's tip. Measured against one shared reference, a band's loudest windows jump with its percussion: on a hot club master the mids and highs pegged with the lows, and the whole strip read as the all-bands color.

**Normalize measures each band against its own loudest window.** Each band reaches its ceiling at its loudest column, raised or lowered, so a hot master's bands fill their ceilings rather than pegging. Without Normalize, and while a load streams, each band is measured against its share of the fixed full scale (`kBandShareOfFullScale`). Measured against the whole full scale, the mids and highs all but vanished. The references are the whole track's, whatever the width, so a resize measures nothing. No renderer keeps a reference of its own, because a view can drop its waveform without telling the renderer. The iOS scrubber always normalizes. Gain moves all three bands alike.

**The fills are the theme's `bandColors`, in painter's order.** The theme also gives the gradient and the hover slice. The gradient is Detailed's ramp over Detailed's band, which `flatFill` drops. It is not a fade mirrored about the midline, because the outer ring is most of what 3-Band shows. The palettes are `WaveformTheme`'s (`../AGENTS.md`). A change of fills redraws the picture. **The picture is drawn once, under one mask with two sides** split at the playhead. The played side is at full level, the unplayed at half, and each carries the ramp. The mask dims the composited picture, so the outer rings never show through the inner ones.

## Spectrum

`SpectrumWaveformRenderer` subclasses 3-Band in `ThreeBandWaveformRenderer.mm`. It shares the height mapping, normalization and morph. Each column is as tall as its tallest band, and Spectrum reads a column a pixel. A backing-scale change takes effect on the next waveform update.

Each column carries three height levels and three color levels. **Colors use a tent window of their own, centered on the column, 2 s from centre to foot and never narrower than two columns** (`kVibeWaveformSpectrumColorSeconds`, read through `tentBandMeanSquares`), without the height mapping's clamp. A column's color is its bar's mix, while its height still shows each hit. A window shorter than a bar leaks the bar's own pattern. On a drum loop it drew stripes a bar apart. At 2 s a side, the beat, the backbeat and a one-bar pattern each leak under 5% from 100 to 174 BPM. **The window is fixed in time, not a share of the track.** At 1/256 of the track it spanned a beat on a short track, and it leaked 69% of a one-bar pattern on a 5-minute track at 128 BPM. A column-long window alternates between the kick's and the hats' hues from pixel to pixel, and the comb crawls as a resize slides the windows. A window locked to the tempo would cancel these exactly. It would also change the colors at the end of every first decode, since detection answers only then.

Each color level is RMS divided by its band's share (`kBandShareOfFullScale`), which weighs the mids and highs up against music's falling spectrum. Display gain affects only heights. `VibeSpectrumColor` weights the primaries by the fourth power of these levels. It restores the weighted brightness of the primaries after mixing. Silence uses their plain mean. Only the level ratios affect color. No beat or section detection is involved.

Each pixel column paints its tallest band in its own mix, the color levels read between column centers like the heights. Spectrum always uses a flat fill. The unplayed side has half the played side's opacity.

Spectrum reads `spectrumColors`. Each renderer declares its palette through `paletteKind`. The registry uses that choice for the settings palettes and theme-list swatches. Spectrum's palettes are RGB, Blue, Green and Custom (`../AGENTS.md`). Custom shares 3-Band's Low, Mid and High wells.
