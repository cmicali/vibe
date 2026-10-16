# WaveformCore

A waveform engine meant for reuse outside Vibe: the summary of an audio stream, the reads every display is drawn from, the raster that draws them, and the archive. It is plain C++17 over Accelerate. It names no app type, so another app can take the directory as it is. Vibe compiles its sources straight into both apps and the tests (`project.yml`). In Vibe the summary is `AudioWaveform` (`Vibe/Audio/Waveform/AGENTS.md`).

The public headers are in `Sources/WaveformCore/include`, and each states its contract. The namespace is `wavecore`, a name no variable takes, so it cannot be shadowed by a local `waveform`.

## The summary

**Every value is a function of absolute time.** A bin is a fixed span of frames counted from the start of the stream, so a bin never moves when the length turns out different, and two reads of the same frames always agree. Bins are 256 frames, or a finer power of two for a file too short to fill 8,192 of them (`BinFramesForLength`). Each bin keeps its channels' peaks, the mono mix's sum of squares, and optionally three bands' sums. A builder appends a decode's stream in order. A snapshot is a copy of the whole bins so far.

**Peaks are stored as float16.** A float16 peak is exact to about a twentieth of a percent, and it halves a long file's memory.

## The reads

Every read takes frames, never bins.

- **`column` is exact.** Its extremes are the union of what it covers, read through the coarsest pyramid level with eight bins to a column, its edges refined level by level. A straddling base bin's peaks count whole, so a peak is never lost. Sums count a straddling bin by its part.
- **`columns` is a grid counted from frame 0.** Column k covers [kF, (k+1)F), so a window, a scroll or a zoom anchor never moves a column's frames.
- **`meanSquares` reads a grid's energy with reach.** A column can take the loudest of five column-long windows around its own, so a beat about a column long does not flicker as edges move.
- **`tentBandMeanSquares`** reads the bands under a tent per column, through double running sums kept per pyramid level.
- **`loudestMeanSquares`** is the loudest over a fixed column count across the whole stream: a normalize reference no view can move.

**Deep zoom reads the stream's own frames** (`Detail`, the summary's `detail()`). A holder fills it with blocks of 65,536 frames of the mix on demand, from any thread, while reads run. A grid of columns finer than a bin reads the detail when it holds every block the columns cross, and the bins otherwise. It reads through the line joining the samples at their frames' centers, so a column narrower than a frame holds the line's span across it. At sample zoom the picture is that line. It keeps the newest 16 blocks. A copy starts without them.

The pyramid, the running sums and the loudest answers are built on first use and kept, behind one lock. A shared summary never changes. **TRAP: never append to a summary after a read.** Its pyramid would no longer describe it. Only builders and archive decodes append, before the summary is shared.

## The raster

`WaveformRaster.hpp` turns columns into device pixels, one pixel column at a time, so a picture's working memory is one column whatever its width.

- **A view reads columns only at zoom steps.** Step s holds columns of 2^(s/2) frames on the grid from frame 0. `StepWindowForPixels` picks the step no coarser than the frames a column should cover, the next coarser one, and how near the view is to each. It also picks the columns of each under a window of pixels. A resize, a zoom or a scroll inside a step reads the same columns, so a view that keeps its samples needs no new reads.
- **Each pixel is a continuous function of the view.** `ForEachColumnShare` lands each column in the pixels it overlaps by its share. The two steps are crossfaded by the window's `coarse`. Columns reduced per pixel instead re-partition the track on every resize, and fine texture reshuffles. Sonic Visualiser avoids that by allowing only fixed zoom levels. The steps avoid it at every zoom.
- **`RemapStepSamples` moves samples from one window's layout to another's** by the track's frames, the same step first. A view that eases its samples keeps easing through a zoom or a scroll.
- **`ColumnCoverage` is exact.** A span covers each row by its part, and a span costs its two ends whatever its height. It writes a premultiplied white mask.
- **`ColumnPaint` paints spans in order.** A row takes each color by the area it shows there, never coverage over coverage, so edges that coincide do not stack into a bolder line.

Rows are written from the top with a signed stride, so a caller whose layer shows its contents flipped writes bottom-up.

## The archive

`encode` writes a header and the float16 planes. Each plane's values become differences from the one before, then every low byte goes before every high byte, then LZFSE compresses the result. Together the two filters make the archive 5 to 13% smaller. `decode` refuses anything malformed or non-finite, since the archive has no checksum. **TRAP: an archive's bytes need not be aligned.** Copy the header out, never cast it.

**LZFSE is Apple's, from the system's Compression library, chosen by measurement.** zstd, lz4, brotli and zlib-ng were each built and run on the archive's own planes from real tracks, from a 24-s loop to a 66-minute mix. Every codec landed between 0.70 and 0.90 of the raw size, because the peaks are close to noise. zstd at level 19, its window capped so the compressor stays near 5 MB, was 2.4 to 4.5% smaller than LZFSE and decoded faster, but it adds about 420 KB of code to each app. LZMA and brotli at their highest levels were 2% smaller again, but decoded 5 to 35 times slower. lz4 and zlib-ng were larger than LZFSE. LZFSE decodes a typical track's archive in about 0.2 ms with no third-party code, and the codec is one call in each direction if the trade changes.
