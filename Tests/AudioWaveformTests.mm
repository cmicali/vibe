//
// AudioWaveform: the chunk-combining math every renderer reads through, the
// NaN sanitizing that keeps corrupt decodes out of the cache, and the shared
// mono downmix.
//

#import <XCTest/XCTest.h>

#import "AudioWaveform.h"

#include <algorithm>
#include <cmath>
#include <vector>

@interface AudioWaveformTests : XCTestCase
@end

@implementation AudioWaveformTests {
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

#pragma mark - getMaxMeanSquare

// 64 chunks whose mean square is their index, so the loudest column at any
// resolution is the mean of the last chunks it covers.
- (void)testMaxMeanSquareIsTheLoudestColumnAtThatResolution {
    std::vector<AudioWaveformCacheChunk> source(64, AudioWaveformCacheChunk());
    for (NSUInteger i = 0; i < 64; i++) {
        source[i].set(0, 0, (float)i * 4, 4);
    }
    AudioWaveform *w = new AudioWaveform(source.size(), source.data());
    XCTAssertEqualWithAccuracy(w->getMaxMeanSquare(64), 63, 1e-5);
    XCTAssertEqualWithAccuracy(w->getMaxMeanSquare(8), 59.5, 1e-5);   // chunks 56..63
    XCTAssertEqualWithAccuracy(w->getMaxMeanSquare(1), 31.5, 1e-5);   // the whole track
    XCTAssertEqualWithAccuracy(w->getMaxMeanSquare(1024), 63, 1e-5); // finer than the source repeats
    delete w;
    AudioWaveform *empty = new AudioWaveform();
    XCTAssertEqual(empty->getMaxMeanSquare(64), 0);
    delete empty;
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

- (void)testSmallColumnsCombineTheirWholeRange {
    // 64 → 8 columns: 8 chunks each, under the 16-chunk vDSP threshold.
    AudioWaveform *w = [self waveform];
    AudioWaveformCacheChunk first = w->getChunkAtIndex(0, 8);
    XCTAssertEqual(first.getMin(), -7.0f, @"column 0 covers chunks [0,8)");
    XCTAssertEqual(first.getMax(), 7.0f);

    AudioWaveformCacheChunk last = w->getChunkAtIndex(7, 8);
    XCTAssertEqual(last.getMin(), -63.0f, @"column 7 covers chunks [56,64)");
    XCTAssertEqual(last.getMax(), 63.0f);
    delete w;
}

- (void)testLargeColumnsCombineTheirWholeRange {
    // 64 → 4 columns: 16 chunks each, on the vDSP path.
    AudioWaveform *w = [self waveform];
    AudioWaveformCacheChunk first = w->getChunkAtIndex(0, 4);
    XCTAssertEqual(first.getMin(), -15.0f, @"column 0 covers chunks [0,16)");
    XCTAssertEqual(first.getMax(), 15.0f);

    AudioWaveformCacheChunk last = w->getChunkAtIndex(3, 4);
    XCTAssertEqual(last.getMin(), -63.0f, @"column 3 covers chunks [48,64)");
    XCTAssertEqual(last.getMax(), 63.0f);
    delete w;
}

- (void)testBothCombinePathsAgree {
    // The <16 plain loop and the >=16 vDSP reduction must be the same
    // function. 64→5 (12.8 chunks/column) exercises the loop, 64→3 (21.3) the
    // vDSP path; both are checked against an independent scalar reduction.
    AudioWaveform *w = [self waveform];
    for (NSUInteger size : {(NSUInteger)5, (NSUInteger)3}) {
        for (NSUInteger i = 0; i < size; i++) {
            NSUInteger end = 64 * (i + 1) / size;
            AudioWaveformCacheChunk c = w->getChunkAtIndex(i, size);
            XCTAssertEqual(c.getMin(), -(float)(end - 1), @"size %lu column %lu", size, i);
            XCTAssertEqual(c.getMax(), (float)(end - 1));
        }
    }
    delete w;
}

- (void)testColumnsTileTheSourceWithoutSkippingChunks {
    // The reason columns are [start(i), start(i+1)) rather than a floored
    // fixed width: at a fractional ratio the latter skips a source chunk on
    // most steps, and a transient peak living there vanishes at that width.
    // A spike must survive at EVERY view width.
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
    // The failed-alloc / null-source guard: numChunks collapses to 0 and
    // every read is a safe no-op rather than a NULL dereference.
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

- (void)testMergeWidensToTheExtremesOfBoth {
    AudioWaveformCacheChunk a, b;
    a.set(-1.0f, 2.0f);
    b.set(-3.0f, 1.0f);
    a.merge(&b);
    XCTAssertEqual(a.getMin(), -3.0f);
    XCTAssertEqual(a.getMax(), 2.0f);
}

- (void)testMergeIgnoresNarrowerRanges {
    AudioWaveformCacheChunk a, b;
    a.set(-5.0f, 5.0f);
    b.set(-1.0f, 1.0f);
    a.merge(&b);
    XCTAssertEqual(a.getMin(), -5.0f);
    XCTAssertEqual(a.getMax(), 5.0f);
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

- (void)testMergeCombinesEnergyExactlyWhateverTheOrder {
    // Sequential pairwise merges must equal one flat combine: energy is a sum
    // plus a frame count, not a stored mean, or the first chunk's weight
    // would halve with every later merge.
    AudioWaveformCacheChunk a, b, c;
    a.set(0, 0, 4.0f, 2.0f);
    b.set(0, 0, 1.0f, 1.0f);
    c.set(0, 0, 10.0f, 5.0f);
    a.merge(&b);
    a.merge(&c);
    XCTAssertEqualWithAccuracy(a.getMeanSquare(), 15.0f / 8.0f, 1e-6);
}

- (void)testColumnsCombineEnergyOnBothCombinePaths {
    // Chunk i carries meanSquare i over one frame, so a column's meanSquare is
    // the average of its chunk indexes — checkable on the <16 plain loop
    // (8 chunks per column) and the vDSP path (16 per column) alike.
    std::vector<AudioWaveformCacheChunk> chunks(64, AudioWaveformCacheChunk());
    for (NSUInteger i = 0; i < 64; i++) {
        chunks[i].set(0, 0, (float)i, 1.0f);
    }
    AudioWaveform *w = new AudioWaveform(chunks.size(), chunks.data());
    XCTAssertEqualWithAccuracy(w->getChunkAtIndex(0, 8).getMeanSquare(), 3.5f, 1e-6,
                               @"column 0 covers chunks [0,8)");
    XCTAssertEqualWithAccuracy(w->getChunkAtIndex(3, 4).getMeanSquare(), 55.5f, 1e-6,
                               @"column 3 covers chunks [48,64)");
    delete w;
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
