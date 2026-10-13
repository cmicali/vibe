//
//  AudioWaveformDataTests.mm
//  VibeTests
//
//  The waveform data: column and bar reads, copies, chunks and the mono mix.
//  The renderers' tests are AudioWaveformTests, in WaveformUI/.
//

#import <XCTest/XCTest.h>

#import "AudioWaveform.h"

#include <algorithm>
#include <cmath>
#include <numeric>
#include <vector>

@interface AudioWaveformDataTests : XCTestCase
@end

@implementation AudioWaveformDataTests {
    // 64 chunks, chunk i = (min -i, max +i): the index is recoverable from
    // either extreme, so a combined column reports which source chunks it
    // actually covered.
    std::vector<AudioWaveformCacheChunk> _source;
}

- (void)setUp {
    _source.assign(64, AudioWaveformCacheChunk());
    for (NSUInteger i = 0; i < 64; i++) {
        _source[i].set(-(float)i, (float)i);
    }
}

- (AudioWaveform *)waveform {
    return new AudioWaveform(_source.size(), _source.data());
}

#pragma mark - getDecodedFraction

// The edge is the first chunk with no frames, and a complete waveform is whole
// even where its decode ended a chunk short.
- (void)testDecodedFractionIsTheFirstUnfilledChunk {
    AudioWaveform loading;
    NSUInteger count = loading.getNumChunks();
    XCTAssertEqual(loading.getDecodedFraction(), 0);
    AudioWaveformCacheChunk silent;
    silent.set(0, 0, 0, 4);
    for (NSUInteger i = 0; i < count / 4; i++) {
        loading.setChunkAtIndex(silent, i);
    }
    XCTAssertEqual(loading.getDecodedFraction(), 0.25);
    loading.markComplete();
    XCTAssertEqual(loading.getDecodedFraction(), 1);
}

#pragma mark - getBarMeanSquares

// Chunk i carries mean square i, and bands i, 2i and 3i, over one frame.
static AudioWaveform VibeRampWaveform(NSUInteger count) {
    std::vector<AudioWaveformCacheChunk> chunks(count);
    std::vector<float> bands;
    for (NSUInteger i = 0; i < count; i++) {
        chunks[i].set(0, 0, (float)i, 1);
        bands.insert(bands.end(), {(float)i, (float)i * 2, (float)i * 3});
    }
    return AudioWaveform(chunks.size(), chunks.data(), bands.data());
}

// Without reach a bar's window is the bar, so a ramp reads its own value at
// the bar's center, in the mix and in every band; with or without, it never
// runs backwards.
- (void)testBarMeanSquaresReadARampAtEachBarsCenter {
    AudioWaveform w = VibeRampWaveform(64);
    for (NSUInteger size : {(NSUInteger)64, (NSUInteger)32, (NSUInteger)8}) {
        std::vector<float> mix(size), bands(size * kAudioWaveformBandCount);
        w.getBarMeanSquares(size, 0, mix.data(), bands.data());
        for (NSUInteger i = 0; i < size; i++) {
            float center = ((float)i + 0.5f) * 64 / (float)size - 0.5f;
            XCTAssertEqualWithAccuracy(mix[i], center, 1e-4, @"size %lu bar %lu", size, i);
            for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
                XCTAssertEqualWithAccuracy(bands[i * kAudioWaveformBandCount + b], center * (b + 1), 1e-3,
                                           @"size %lu bar %lu band %lu", size, i, b);
            }
        }
    }
    for (float reach : {0.0f, 0.5f, 1.0f}) {
        for (NSUInteger size = 1; size <= 200; size++) {
            std::vector<float> mix(size);
            w.getBarMeanSquares(size, reach, mix.data(), nullptr);
            for (NSUInteger i = 0; i < size; i++) {
                XCTAssertTrue(mix[i] >= 0 && mix[i] <= 63 + 1e-3f, @"reach %g size %lu bar %lu", reach, size, i);
                if (i > 0) {
                    XCTAssertGreaterThanOrEqual(mix[i], mix[i - 1] - 1e-4f, @"reach %g size %lu bar %lu", reach, size, i);
                }
            }
        }
    }
    // The tent is symmetric about the bar's center, so on a ramp it reads
    // reach 0's value too, except at the edge bars, where the track clips it.
    for (NSUInteger size : {(NSUInteger)64, (NSUInteger)32, (NSUInteger)8}) {
        std::vector<float> plain(size * kAudioWaveformBandCount), window(size * kAudioWaveformBandCount);
        w.getBarMeanSquares(size, 0, nullptr, plain.data());
        w.getBandWindowMeanSquares(size, size, window.data());
        for (NSUInteger i = kAudioWaveformBandCount; i < plain.size() - kAudioWaveformBandCount; i++) {
            XCTAssertEqualWithAccuracy(window[i], plain[i], 1e-3f, @"size %lu value %lu", size, i);
        }
        // Clipped to the track, the edge bars lean inward; at a chunk a bar
        // the tent's feet weigh nothing and they read as the box.
        XCTAssertGreaterThanOrEqual(window[0], plain[0], @"size %lu", size);
        XCTAssertLessThanOrEqual(window[plain.size() - 1], plain[plain.size() - 1], @"size %lu", size);
    }
}

// The tent is 1/columns of the track foot to foot about the bar's center,
// clipped to the track, and two bars wide when that is wider.
- (void)testBandWindowMeanSquaresAreATentAboutTheBar {
    std::vector<AudioWaveformCacheChunk> chunks(8);
    std::vector<float> bandSums;
    for (NSUInteger i = 0; i < chunks.size(); i++) {
        chunks[i].set(-0.1f, 0.1f, 0.01f, 1);
        bandSums.insert(bandSums.end(), {(float)i, 0.0f, 1.0f});
    }
    AudioWaveform waveform(chunks.size(), chunks.data(), bandSums.data());
    std::vector<float> bands(8 * kAudioWaveformBandCount);
    // Four chunks foot to foot about a one-chunk bar: 7/8 of the tent's area
    // over the bar's own chunk, 1/2 over each neighbor, 1/16 over the next.
    waveform.getBandWindowMeanSquares(8, 2, bands.data());
    XCTAssertEqualWithAccuracy(bands[3 * kAudioWaveformBandCount], 3, 1e-5);
    XCTAssertEqualWithAccuracy(bands[3 * kAudioWaveformBandCount + 2], 1, 1e-5);
    const float edge = 0.875f + 0.5f + 0.0625f;
    XCTAssertEqualWithAccuracy(bands[0], (1 * 0.5f + 2 * 0.0625f) / edge, 1e-5);
    XCTAssertEqualWithAccuracy(bands[7 * kAudioWaveformBandCount], (7 * 0.875f + 6 * 0.5f + 5 * 0.0625f) / edge, 1e-5);
    // Bars wider than the floor: two bars foot to foot, symmetric about
    // the track's middle here.
    waveform.getBandWindowMeanSquares(2, 2, bands.data());
    XCTAssertEqualWithAccuracy(bands[0] + bands[kAudioWaveformBandCount], 7, 1e-5);
    XCTAssertGreaterThan(bands[0], 1.5);
    XCTAssertLessThan(bands[0], 2.5);
    AudioWaveform plain(chunks.size(), chunks.data());
    plain.getBandWindowMeanSquares(2, 2, bands.data());
    XCTAssertEqual(bands[0], 0);
    XCTAssertEqual(bands[2 * kAudioWaveformBandCount - 1], 0);
}


// The frames are windowed as the sums are, so a steady level reads as itself
// at every width and reach, the bars whose windows slide off the track
// included, and a load still streaming is the mean of the frames it has: its
// front bar is not dragged toward the silence past it.
- (void)testBarMeanSquaresAreTheMeanOfTheFramesTheWindowCovers {
    std::vector<AudioWaveformCacheChunk> chunks(64);
    for (NSUInteger i = 0; i < 32; i++) chunks[i].set(-0.5f, 0.5f, 0.25f * 4, 4);
    AudioWaveform half(chunks.size(), chunks.data());
    for (NSUInteger i = 32; i < 64; i++) chunks[i].set(-0.5f, 0.5f, 0.25f * 4, 4);
    AudioWaveform whole(chunks.size(), chunks.data());
    for (float reach : {0.0f, 1.0f}) {
        for (NSUInteger size = 1; size <= 200; size++) {
            std::vector<float> loaded(size), level(size), bands(size * kAudioWaveformBandCount, 1);
            whole.getBarMeanSquares(size, reach, level.data(), bands.data());
            half.getBarMeanSquares(size, reach, loaded.data(), nullptr);
            for (NSUInteger i = 0; i < size; i++) {
                XCTAssertEqualWithAccuracy(level[i], 0.25f, 1e-5, @"size %lu bar %lu", size, i);
                XCTAssertTrue(loaded[i] == 0 || fabsf(loaded[i] - 0.25f) < 1e-5f, @"size %lu bar %lu", size, i);
                XCTAssertEqual(bands[i * kAudioWaveformBandCount], 0, @"no bands read as silence");
            }
            XCTAssertEqualWithAccuracy(loaded[0], 0.25f, 1e-5, @"size %lu", size);
            if (size >= 4) XCTAssertEqual(loaded[size - 1], 0, @"size %lu", size);
        }
    }
    AudioWaveform empty(0, nullptr);
    float untouched = 7;
    empty.getBarMeanSquares(1, 1, &untouched, nullptr);
    XCTAssertEqual(untouched, 0);
}

// What the reach is for. A kick in two chunks of every ten, drawn at about a
// thousand bars: a bar is 0.8 of a beat, so a bar with hard edges holds a
// whole kick, part of one or two parts, and the bars beat against the kicks
// in a pattern that runs along the waveform as a resize moves the edges. With
// reach every bar finds a window holding one kick whole, at its full height.
- (void)testReachHoldsBarsStillAgainstABeatAboutABarLong {
    std::vector<AudioWaveformCacheChunk> chunks(8192);
    for (NSUInteger i = 0; i < chunks.size(); i++) {
        chunks[i].set(-1, 1, i % 10 < 2 ? 1.0f : 0.01f, 1);
    }
    AudioWaveform w(chunks.size(), chunks.data());
    auto spread = [](const std::vector<float> &bars) {
        auto [low, high] = std::minmax_element(bars.begin() + 1, bars.end() - 1);
        float mean = std::accumulate(bars.begin() + 1, bars.end() - 1, 0.0f) / (float)(bars.size() - 2);
        return (*high - *low) / mean;
    };
    for (NSUInteger size : {(NSUInteger)1000, (NSUInteger)1001, (NSUInteger)1010}) {
        std::vector<float> still(size), hard(size);
        w.getBarMeanSquares(size, 1, still.data(), nullptr);
        w.getBarMeanSquares(size, 0, hard.data(), nullptr);
        XCTAssertGreaterThan(spread(hard), 1.0f, @"size %lu", size);
        XCTAssertLessThan(spread(still), 0.05f, @"size %lu", size);
        float oneKick = (2 + ((float)chunks.size() / size - 2) * 0.01f) / ((float)chunks.size() / size);
        XCTAssertEqualWithAccuracy(still[size / 2], oneKick, oneKick * 0.01f, @"size %lu", size);
    }
}
#pragma mark - getChunkAtIndex

- (void)testRequestingTheNativeChunkCountReturnsChunksVerbatim {
    AudioWaveform *w = [self waveform];
    for (NSUInteger i = 0; i < 64; i++) {
        AudioWaveformCacheChunk c = w->getChunkAtIndex(i, 64);
        XCTAssertEqual(c.getMin(), -(float)i);
        XCTAssertEqual(c.getMax(), (float)i);
    }
    delete w;
}

- (void)testColumnsCombineTheirWholeRange {
    // Even columns of 8 and 16 chunks, and uneven ones of 12.8 and 21.3,
    // against an independent scalar reduction.
    AudioWaveform *w = [self waveform];
    for (NSUInteger size : {(NSUInteger)8, (NSUInteger)4, (NSUInteger)5, (NSUInteger)3}) {
        for (NSUInteger i = 0; i < size; i++) {
            NSUInteger end = 64 * (i + 1) / size;
            AudioWaveformCacheChunk c = w->getChunkAtIndex(i, size);
            XCTAssertEqual(c.getMin(), -(float)(end - 1), @"size %lu column %lu", size, i);
            XCTAssertEqual(c.getMax(), (float)(end - 1));
        }
    }
    delete w;
}

- (void)testBandMeanSquaresReadEachChunk {
    AudioWaveform w = VibeRampWaveform(64);
    float meanSquares[kAudioWaveformBandCount];
    for (NSUInteger i = 0; i < 64; i++) {
        w.getBandMeanSquares(i, meanSquares);
        for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
            XCTAssertEqual(meanSquares[b], (float)(i * (b + 1)), @"chunk %lu band %lu", i, b);
        }
    }
    AudioWaveform copy(w);
    copy.getBandMeanSquares(63, meanSquares);
    XCTAssertEqual(meanSquares[2], 189, @"a copy carries the bands");

    // Without bands every read is silence and every write a no-op.
    AudioWaveform plain(_source.size(), _source.data());
    XCTAssertFalse(plain.hasBands());
    const float sums[kAudioWaveformBandCount] = {1, 2, 3};
    plain.setBandSumSquaresAtIndex(sums, 0);
    plain.copyChunk(0, 1);
    plain.getBandMeanSquares(0, meanSquares);
    XCTAssertEqual(meanSquares[0] + meanSquares[1] + meanSquares[2], 0);
    XCTAssertFalse(AudioWaveform(plain).hasBands());
}

- (void)testColumnsTileTheSourceWithoutSkippingChunks {
    // Why columns are [start(i), start(i+1)) rather than a floored fixed width:
    // at a fractional ratio the latter skips source chunks, and a transient
    // there vanishes at that view width.
    for (NSUInteger size = 1; size <= 64; size++) {
        for (NSUInteger spikeAt : {(NSUInteger)0, (NSUInteger)37, (NSUInteger)63}) {
            std::vector<AudioWaveformCacheChunk> chunks(64, AudioWaveformCacheChunk());
            chunks[spikeAt].set(-1.0f, 1.0f);
            AudioWaveform *w = new AudioWaveform(chunks.size(), chunks.data());

            float widest = 0;
            for (NSUInteger i = 0; i < size; i++) {
                widest = std::max(widest, w->getChunkAtIndex(i, size).getMax());
            }
            XCTAssertEqual(widest, 1.0f,
                           @"spike at chunk %lu lost at width %lu", spikeAt, size);
            delete w;
        }
    }
}

- (void)testOversamplingBeyondTheSourceRepeatsRatherThanReadingGarbage {
    // The x2/x4/x8 styles deliberately ask for more columns than there are
    // chunks; every column must still land inside the buffer.
    AudioWaveform *w = [self waveform];
    for (NSUInteger i = 0; i < 256; i++) {
        AudioWaveformCacheChunk c = w->getChunkAtIndex(i, 256);
        XCTAssertTrue(std::isfinite(c.getMin()) && std::isfinite(c.getMax()));
        XCTAssertLessThanOrEqual(c.getMax(), 63.0f);
        XCTAssertGreaterThanOrEqual(c.getMin(), -63.0f);
    }
    delete w;
}

- (void)testOutOfRangeIndexReturnsAnEmptyChunk {
    AudioWaveform *w = [self waveform];
    AudioWaveformCacheChunk c = w->getChunkAtIndex(8, 8);
    XCTAssertEqual(c.getMin(), 0.0f);
    XCTAssertEqual(c.getMax(), 0.0f);
    delete w;
}

- (void)testWaveformBuiltFromNullChunksReadsAsEmpty {
    // The failed-alloc / null-source guard.
    AudioWaveform *w = new AudioWaveform(64, nullptr);
    XCTAssertEqual(w->getNumChunks(), (NSUInteger)0);
    AudioWaveformCacheChunk c = w->getChunkAtIndex(0, 8);
    XCTAssertEqual(c.getMin(), 0.0f);
    XCTAssertEqual(c.getMax(), 0.0f);
    delete w;
}

- (void)testDefaultWaveformIsZeroedAtFullChunkCount {
    AudioWaveform *w = new AudioWaveform();
    XCTAssertGreaterThan(w->getNumChunks(), (NSUInteger)0);
    XCTAssertEqual(w->getNumBytes(), w->getNumChunks() * sizeof(AudioWaveformCacheChunk));
    XCTAssertFalse(w->hasBands(), @"only a decode asked for the bands holds them");
    XCTAssertEqual(w->getNumBandBytes(), 0u);
    XCTAssertEqual(w->getChunkAtIndex(0, w->getNumChunks()).getMax(), 0.0f);
    delete w;
}

#pragma mark - Copying

- (void)testCopyConstructorDeepCopies {
    // Rule of three: a shallow copy of the chunks pointer would double-free.
    AudioWaveform *original = [self waveform];
    AudioWaveform *copy = new AudioWaveform(*original);

    AudioWaveformCacheChunk replaced;
    replaced.set(-99.0f, 99.0f);
    original->setChunkAtIndex(replaced, 0);

    XCTAssertEqual(original->getChunkAtIndex(0, 64).getMax(), 99.0f);
    XCTAssertEqual(copy->getChunkAtIndex(0, 64).getMax(), 0.0f,
                   @"the copy must not see writes to the original");
    delete original;
    delete copy;
}

#pragma mark - AudioWaveformCacheChunk

- (void)testAColumnWidensToTheExtremesOfItsChunks {
    AudioWaveformCacheChunk chunks[2];
    chunks[0].set(-1.0f, 2.0f);
    chunks[1].set(-3.0f, 1.0f);
    AudioWaveformCacheChunk widened = AudioWaveform(2, chunks).getChunkAtIndex(0, 1);
    XCTAssertEqual(widened.getMin(), -3.0f);
    XCTAssertEqual(widened.getMax(), 2.0f);

    chunks[0].set(-5.0f, 5.0f);
    chunks[1].set(-1.0f, 1.0f);
    AudioWaveformCacheChunk unmoved = AudioWaveform(2, chunks).getChunkAtIndex(0, 1);
    XCTAssertEqual(unmoved.getMin(), -5.0f);
    XCTAssertEqual(unmoved.getMax(), 5.0f);
}

- (void)testChunkFromMonoBufferTakesTheExtremes {
    // Chunks start at (0,0) and only ever widen, so a wholly positive buffer
    // keeps min 0 — the waveform is drawn symmetrically about the midline.
    const float samples[] = {0.25f, 0.75f, 0.5f};
    AudioWaveformCacheChunk c(samples, 3);
    XCTAssertEqual(c.getMin(), 0.0f);
    XCTAssertEqual(c.getMax(), 0.75f);
    XCTAssertEqualWithAccuracy(c.getMeanSquare(), (0.0625f + 0.5625f + 0.25f) / 3.0f, 1e-6);

    const float bipolar[] = {-0.6f, 0.2f};
    AudioWaveformCacheChunk d(bipolar, 2);
    XCTAssertEqual(d.getMin(), -0.6f);
    XCTAssertEqual(d.getMax(), 0.2f);
}

- (void)testNonFiniteSamplesAreClampedNotPropagated {
    // A corrupt decode must not reach the renderers: NaN would produce NaN
    // CGRects, and — since the decode still completes — get persisted under
    // the file hash, breaking that track until the entry ages out.
    const float withNaN[] = {0.5f, NAN, -0.25f};
    AudioWaveformCacheChunk c(withNaN, 3);
    XCTAssertTrue(std::isfinite(c.getMin()));
    XCTAssertTrue(std::isfinite(c.getMax()));
    XCTAssertTrue(std::isfinite(c.getMeanSquare()));

    const float withInf[] = {INFINITY, -INFINITY};
    AudioWaveformCacheChunk d(withInf, 2);
    XCTAssertTrue(std::isfinite(d.getMin()));
    XCTAssertTrue(std::isfinite(d.getMax()));
    XCTAssertTrue(std::isfinite(d.getMeanSquare()));
}

- (void)testChunkFromMonoBufferAccumulatesEnergyWeightedByFrames {
    const float first[] = {0.5f, -0.5f};       // meanSquare 0.25 over 2 frames
    AudioWaveformCacheChunk c(first, 2);
    XCTAssertEqualWithAccuracy(c.getMeanSquare(), 0.25f, 1e-6);

    const float second[] = {1.0f};             // meanSquare 1.0 over 1 frame
    c.mergeFromMonoBuffer(second, 1);
    XCTAssertEqualWithAccuracy(c.getMeanSquare(), (0.25f * 2 + 1.0f) / 3.0f, 1e-6);
}

- (void)testABarWeighsEachChunksEnergyByItsFrames {
    // Energy is a sum plus a frame count, not a stored mean, or a bar of
    // uneven chunks would count a short chunk as much as a long one.
    AudioWaveformCacheChunk chunks[3];
    chunks[0].set(0, 0, 4.0f, 2.0f);
    chunks[1].set(0, 0, 1.0f, 1.0f);
    chunks[2].set(0, 0, 10.0f, 5.0f);
    float meanSquare = 0;
    AudioWaveform(3, chunks).getBarMeanSquares(1, 0, &meanSquare, nullptr);
    XCTAssertEqualWithAccuracy(meanSquare, 15.0f / 8.0f, 1e-6);
}

- (void)testEmptyMonoBufferLeavesTheChunkUntouched {
    AudioWaveformCacheChunk c;
    c.set(-2.0f, 3.0f);
    c.mergeFromMonoBuffer(nullptr, 0);
    XCTAssertEqual(c.getMin(), -2.0f);
    XCTAssertEqual(c.getMax(), 3.0f);
    XCTAssertEqual(c.getMeanSquare(), 0.0f, @"no frames merged means no energy");
}

#pragma mark - AudioWaveformMonoMix

- (void)testMonoInputIsPassedThroughWithoutCopying {
    const float mono[] = {0.1f, 0.2f};
    float scratch[2] = {0};
    const float *out = AudioWaveformMonoMix(mono, scratch, 2, 1);
    XCTAssertEqual(out, (const float *)mono, @"mono must not pay for a copy");
}

- (void)testStereoIsAveragedIntoScratch {
    // Interleaved L0 R0 L1 R1.
    const float stereo[] = {1.0f, 3.0f, 2.0f, 4.0f};
    float scratch[2] = {0};
    const float *out = AudioWaveformMonoMix(stereo, scratch, 2, 2);
    XCTAssertEqual(out, (const float *)scratch);
    XCTAssertEqualWithAccuracy(out[0], 2.0f, 1e-6);
    XCTAssertEqualWithAccuracy(out[1], 3.0f, 1e-6);
}

- (void)testMultiChannelIsAveragedAcrossEveryChannel {
    // 3 channels, 2 frames: c0f0 c1f0 c2f0 c0f1 c1f1 c2f1.
    const float surround[] = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
    float scratch[2] = {0};
    const float *out = AudioWaveformMonoMix(surround, scratch, 2, 3);
    XCTAssertEqualWithAccuracy(out[0], 2.0f, 1e-6);
    XCTAssertEqualWithAccuracy(out[1], 5.0f, 1e-6);
}

@end
