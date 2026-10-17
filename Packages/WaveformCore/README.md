# WaveformCore

A waveform engine for audio apps: a compact summary of an audio stream, the reads a display draws from, a raster that draws them without shimmer at any zoom, and an archive. It is C++17 over Accelerate and Compression, with no app types, so any Apple-platform app can take it. Vibe, the music player it was written for, compiles its sources straight into its apps.

## What it does

- **A summary on a grid of absolute time.** Each bin covers a fixed span of frames counted from the start of the stream: 256, or a finer power of two for a short file. A bin never moves when the length turns out different. Bins keep each channel's peaks, the mix's energy, and optionally three bands' energies (low, mid, high, split at 300 Hz and 2.5 kHz). Peaks are float16.
- **Exact reads at any width.** A column's peaks are the union of what it covers, read through a pyramid its builder keeps as bins arrive. Its sums count a straddling bin by its part. A progressive snapshot costs the same however long the stream, and a summary never exceeds about a million bins. A grid of columns counts from frame 0, so a scroll never moves a column's frames. A column's level is its loudest 20 ms window, so a hit is never averaged away at any zoom.
- **Zoom steps.** A view reads columns only at steps of 2^(s/2) frames and crossfades the two steps around its scale. A resize or a zoom inside a step only resamples the same columns, so every pixel changes continuously and fine texture never reshuffles.
- **Exact coverage.** `ColumnCoverage` lands spans in a pixel column by their exact area, and `ColumnPaint` paints colored spans in order without stacking their edges. Both work one pixel column at a time, so a picture of any width needs one column of memory.
- **Deep zoom.** A summary's `Detail` holds blocks of the stream's own frames, filled on demand. Columns finer than a bin read them through the line joining the samples. A read that misses blocks leaves them for the holder to fetch.
- **An archive.** About 250 KB for a 4:40 song: a header and float16 planes, delta-filtered and LZFSE-compressed. The decoder refuses anything malformed.

## Using it

With Swift Package Manager, depend on the package's directory or repository and import the `WaveformCore` library from C++ or Objective-C++ code. Without it, compile `Sources/WaveformCore/*.cpp` with `Sources/WaveformCore/include` on the header path, and link Accelerate and `libcompression`.

```cpp
#include "WaveformSummary.hpp"
#include "WaveformRaster.hpp"

// Build: feed decoded audio in order, interleaved and as its mono mix.
wavecore::SummaryBuilder builder(channels, /*stored*/ 1, /*bands*/ false, expectedFrames, sampleRate);
builder.append(interleaved, mono, frameCount);
std::unique_ptr<wavecore::Summary> summary = builder.finish(/*complete*/ true);

// Read: the two zoom steps under a window of pixels, then each step's columns.
double framesPerPixel = double(summary->totalFrames()) / widthInPixels;
wavecore::StepWindow window = wavecore::StepWindowForPixels(summary->totalFrames(), framesPerPixel,
                                                            /*columnsPerPixel*/ 1, x0, x1);
for (const wavecore::StepPart &part : window.parts) {
    std::vector<wavecore::Column> columns(part.count);
    summary->columns(part.framesPerColumn(), part.first, part.count, columns.data());
}

// Archive.
std::vector<uint8_t> bytes = summary->encode();
std::unique_ptr<wavecore::Summary> restored = wavecore::Summary::decode(bytes.data(), bytes.size());
```

The headers state every contract. `AGENTS.md` records the design decisions and their measurements.

## Tests

`swift test` here runs the package's XCTest suite. Vibe's `make test` compiles and runs the same files.
