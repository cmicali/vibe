# WaveformCore

A waveform engine meant for reuse outside Vibe: the summary of an audio stream, the reads every display is drawn from, and its archive. It is plain C++17 over Accelerate. It names no app type, so another app can take the directory as it is. Vibe compiles its sources straight into both apps and the tests (`project.yml`). In Vibe the summary is `AudioWaveform` (`Vibe/Audio/Waveform/AGENTS.md`).

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

The pyramid, the running sums and the loudest answers are built on first use and kept, behind one lock. A shared summary never changes. **TRAP: never append to a summary after a read.** Its pyramid would no longer describe it. Only builders and archive decodes append, before the summary is shared.

## The archive

`encode` writes a header and the float16 planes. Each plane's values become differences from the one before, then every low byte goes before every high byte, then LZFSE compresses the result. Together the two filters make the archive 5 to 13% smaller. `decode` refuses anything malformed or non-finite, since the archive has no checksum. **TRAP: an archive's bytes need not be aligned.** Copy the header out, never cast it.

**LZFSE is Apple's, from the system's Compression library, chosen by measurement.** zstd, lz4, brotli and zlib-ng were each built and run on the archive's own planes from real tracks, from a 24-s loop to a 66-minute mix. Every codec landed between 0.70 and 0.90 of the raw size, because the peaks are close to noise. zstd at level 19, its window capped so the compressor stays near 5 MB, was 2.4 to 4.5% smaller than LZFSE and decoded faster, but it adds about 420 KB of code to each app. LZMA and brotli at their highest levels were 2% smaller again, but decoded 5 to 35 times slower. lz4 and zlib-ng were larger than LZFSE. LZFSE decodes a typical track's archive in about 0.2 ms with no third-party code, and the codec is one call in each direction if the trade changes.
