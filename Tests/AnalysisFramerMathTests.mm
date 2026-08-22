//
// The stream framer both analyzers run their DSP behind: that the buffer sizes
// the decoder happens to hand an analyzer never reach its result.
//
// The two analyzer suites pin that end to end, through a real decode; this one
// pins the arithmetic directly, at the buffer sizes a decoder is unlikely to
// produce but a caller may — one sample at a time, exactly a frame, a boundary
// landing inside a frame — plus the precondition the function fails closed on.
//

#import <XCTest/XCTest.h>

#import "AnalysisFramerMath.h"

#include <algorithm>
#include <vector>

// A ramp, so a frame's contents identify where in the stream it started.
static std::vector<float> RampSamples(size_t count) {
    std::vector<float> samples(count);
    for (size_t i = 0; i < count; i++) {
        samples[i] = (float)i;
    }
    return samples;
}

// Runs a whole ramp through the framer in fixed-size buffers and returns every
// frame it produced. Because the stream is a ramp from 0, frame[0] IS the
// frame's start offset — so comparing two chunkings' results compares the
// framing and nothing else.
static std::vector<std::vector<float>> FramesForChunking(const std::vector<float> &stream,
                                                         size_t bufferSize,
                                                         size_t frameSize, size_t hopSize) {
    std::vector<float> pending;
    pending.reserve(frameSize * 2);
    std::vector<std::vector<float>> frames;
    for (size_t offset = 0; offset < stream.size(); offset += bufferSize) {
        size_t count = std::min(bufferSize, stream.size() - offset);
        VibeAnalysisFrameStream(pending, stream.data() + offset, count, frameSize, hopSize,
                                [&](const float *frame) {
            frames.push_back(std::vector<float>(frame, frame + frameSize));
        });
    }
    return frames;
}

static std::vector<float> FrameStarts(const std::vector<std::vector<float>> &frames) {
    std::vector<float> starts;
    starts.reserve(frames.size());
    for (const std::vector<float> &frame : frames) {
        starts.push_back(frame.front());
    }
    return starts;
}

@interface AnalysisFramerMathTests : XCTestCase
@end

@implementation AnalysisFramerMathTests

#pragma mark - The guarantee: framing is independent of buffer size

// The whole point of the file. 1, 2 and 3 are the pathological cases, where
// every frame straddles a boundary; 7 is coprime with the hop; 8 is exactly
// the frame; 41 is the whole stream in one call.
- (void)testFramingIsIdenticalWhateverTheBufferSize {
    const size_t frameSize = 8, hopSize = 4;
    std::vector<float> stream = RampSamples(41);
    std::vector<std::vector<float>> expected =
            FramesForChunking(stream, stream.size(), frameSize, hopSize);

    // 41 samples, 8-wide frames every 4: nine frames, starting at 0 … 32.
    std::vector<float> starts = FrameStarts(expected);
    XCTAssertEqual(starts.size(), (size_t)9);
    XCTAssertEqual(starts.front(), 0.0f);
    XCTAssertEqual(starts.back(), 32.0f);

    const size_t bufferSizes[] = {1, 2, 3, 5, 7, 8, 9, 16, 40, 41, 64};
    for (size_t bufferSize : bufferSizes) {
        std::vector<std::vector<float>> actual =
                FramesForChunking(stream, bufferSize, frameSize, hopSize);
        XCTAssertTrue(actual == expected, @"buffer size %zu framed differently", bufferSize);
    }
}

// Contents, not just offsets: a splice that dropped or duplicated one sample
// mid-frame would still pass an offsets-only comparison against itself.
- (void)testSplicedFramesHoldTheRightSamples {
    const size_t frameSize = 8, hopSize = 4;
    std::vector<std::vector<float>> frames =
            FramesForChunking(RampSamples(41), /*bufferSize*/ 3, frameSize, hopSize);
    XCTAssertEqual(frames.size(), (size_t)9);
    for (size_t frameIndex = 0; frameIndex < frames.size(); frameIndex++) {
        for (size_t i = 0; i < frameSize; i++) {
            XCTAssertEqual(frames[frameIndex][i], (float)(frameIndex * hopSize + i),
                           @"frame %zu sample %zu", frameIndex, i);
        }
    }
}

// A hop equal to the frame is the no-overlap edge of the supported range: the
// key analyzer hops half a frame and the BPM analyzer a quarter, so nothing in
// the app travels it.
- (void)testHopEqualToFrameIsIdenticalWhateverTheBufferSize {
    const size_t frameSize = 8, hopSize = 8;
    std::vector<float> stream = RampSamples(35);
    std::vector<std::vector<float>> expected =
            FramesForChunking(stream, stream.size(), frameSize, hopSize);
    std::vector<float> starts = FrameStarts(expected);
    XCTAssertEqual(starts.size(), (size_t)4);
    XCTAssertEqual(starts.back(), 24.0f);

    const size_t bufferSizes[] = {1, 3, 8, 9, 34};
    for (size_t bufferSize : bufferSizes) {
        XCTAssertTrue(FramesForChunking(stream, bufferSize, frameSize, hopSize) == expected,
                      @"buffer size %zu framed differently", bufferSize);
    }
}

#pragma mark - The carried remainder

- (void)testShortOfAFrameProducesNothingAndCarriesEverything {
    const size_t frameSize = 8, hopSize = 4;
    std::vector<float> stream = RampSamples(7);
    std::vector<float> pending;
    pending.reserve(frameSize * 2);
    size_t frames = 0;
    VibeAnalysisFrameStream(pending, stream.data(), stream.size(), frameSize, hopSize,
                            [&](const float *frame) { (void)frame; frames++; });
    XCTAssertEqual(frames, (size_t)0);
    XCTAssertEqual(pending.size(), (size_t)7);
    XCTAssertEqual(pending.front(), 0.0f);
    XCTAssertEqual(pending.back(), 6.0f);
}

// The documented bound on the carry, checked after every call rather than at
// the end: it is what lets the owner reserve twice the frame and be sure the
// splice never reallocates.
- (void)testCarryStaysBelowOneFrameAtEveryBoundary {
    const size_t frameSize = 8, hopSize = 4;
    std::vector<float> stream = RampSamples(101);
    const size_t bufferSizes[] = {1, 2, 3, 5, 7, 8, 13};
    for (size_t bufferSize : bufferSizes) {
        std::vector<float> pending;
        pending.reserve(frameSize * 2);
        for (size_t offset = 0; offset < stream.size(); offset += bufferSize) {
            size_t count = std::min(bufferSize, stream.size() - offset);
            VibeAnalysisFrameStream(pending, stream.data() + offset, count, frameSize, hopSize,
                                    [](const float *frame) { (void)frame; });
            XCTAssertLessThan(pending.size(), frameSize,
                              @"buffer size %zu carried a whole frame", bufferSize);
        }
    }
}

- (void)testEmptyBufferIsANoOpAndKeepsTheCarry {
    std::vector<float> pending = RampSamples(5);
    pending.reserve(16);
    std::vector<float> stream = RampSamples(1);
    size_t frames = 0;
    VibeAnalysisFrameStream(pending, stream.data(), 0, /*frameSize*/ 8, /*hopSize*/ 4,
                            [&](const float *frame) { (void)frame; frames++; });
    XCTAssertEqual(frames, (size_t)0);
    XCTAssertEqual(pending.size(), (size_t)5);
}

#pragma mark - The precondition

// 0 < hopSize <= frameSize. Past it the in-place base can exceed the buffer and
// the final assign becomes a reversed range — an overread, not an empty one —
// so the framer fails closed instead. This is the exact shape that reaches it:
// a carried remainder, then a buffer shorter than the hop.
- (void)testAHopLargerThanTheFrameProducesNothing {
    std::vector<float> pending = RampSamples(3);
    pending.reserve(16);
    std::vector<float> stream = RampSamples(1);
    size_t frames = 0;
    VibeAnalysisFrameStream(pending, stream.data(), stream.size(), /*frameSize*/ 4, /*hopSize*/ 8,
                            [&](const float *frame) { (void)frame; frames++; });
    XCTAssertEqual(frames, (size_t)0);
    XCTAssertEqual(pending.size(), (size_t)3, @"a refused call must not consume the carry");
}

- (void)testAZeroHopProducesNothingRatherThanSpinning {
    std::vector<float> pending;
    std::vector<float> stream = RampSamples(64);
    size_t frames = 0;
    VibeAnalysisFrameStream(pending, stream.data(), stream.size(), /*frameSize*/ 8, /*hopSize*/ 0,
                            [&](const float *frame) { (void)frame; frames++; });
    XCTAssertEqual(frames, (size_t)0);
}

- (void)testAZeroFrameProducesNothing {
    std::vector<float> pending;
    std::vector<float> stream = RampSamples(64);
    size_t frames = 0;
    VibeAnalysisFrameStream(pending, stream.data(), stream.size(), /*frameSize*/ 0, /*hopSize*/ 4,
                            [&](const float *frame) { (void)frame; frames++; });
    XCTAssertEqual(frames, (size_t)0);
}

@end
