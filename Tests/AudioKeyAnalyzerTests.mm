//
//  AudioKeyAnalyzerTests.mm
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "AudioKeyAnalyzer.h"
#include <vector>
#include <cmath>

// Like AudioBPMAnalyzerTests: the analyzer frames the stream itself, so the
// frame counts the decoder happens to hand it must not reach the result.

static const double kTestSampleRate = 44100.0;

// A sustained A minor triad — A3, C4, E4 — over a root-octave bass, which is
// the shape the chromagram and the bass chroma are built for.
static std::vector<float> VibeTestAMinorChord(double seconds) {
    const size_t total = (size_t)(kTestSampleRate * seconds);
    std::vector<float> out(total);
    for (size_t i = 0; i < total; i++) {
        double t = (double)i / kTestSampleRate;
        out[i] = (float)(0.30 * std::sin(2 * M_PI * 220.00 * t) +   // A3
                         0.25 * std::sin(2 * M_PI * 261.63 * t) +   // C4
                         0.20 * std::sin(2 * M_PI * 329.63 * t) +   // E4
                         0.20 * std::sin(2 * M_PI * 110.00 * t));   // A2, the bass
    }
    return out;
}

static VibeMusicalKey VibeTestAnalyzeKey(const std::vector<float> &audio,
                                         const std::vector<size_t> &chunks) {
    AudioKeyAnalyzer *analyzer = [[AudioKeyAnalyzer alloc] initWithSampleRate:kTestSampleRate];
    size_t offset = 0, index = 0;
    while (offset < audio.size()) {
        size_t take = std::min(chunks[index++ % chunks.size()], audio.size() - offset);
        [analyzer appendMonoSamples:audio.data() + offset frameCount:take];
        offset += take;
    }
    return [analyzer finish];
}

@interface AudioKeyAnalyzerTests : XCTestCase
@end

@implementation AudioKeyAnalyzerTests

- (void)testDetectsASustainedMinorTriad {
    std::vector<float> audio = VibeTestAMinorChord(20.0);
    XCTAssertEqual(VibeTestAnalyzeKey(audio, {65536}), VibeMusicalKeyMake(9, 1)); // A minor
}

// The framing invariant. The analysis frame here is 32768 samples with a
// 16384 hop, so the sizes below run from far under one frame to well over it.
- (void)testResultIsIndependentOfBufferSizes {
    std::vector<float> audio = VibeTestAMinorChord(20.0);
    VibeMusicalKey reference = VibeTestAnalyzeKey(audio, {audio.size()});
    XCTAssertNotEqual(reference, VibeMusicalKeyNone);

    const std::vector<std::vector<size_t>> chunkings = {
        {1}, {4096}, {16383}, {16384}, {16385}, {32767}, {32768}, {32769},
        {7, 40000, 63, 4096, 1}, {65536}, {200000},
    };
    for (const std::vector<size_t> &chunks : chunkings) {
        XCTAssertEqual(VibeTestAnalyzeKey(audio, chunks), reference,
                       @"first chunk size %zu", chunks.front());
    }
}

- (void)testTooShortAudioReportsNoKey {
    std::vector<float> audio = VibeTestAMinorChord(1.0);
    XCTAssertEqual(VibeTestAnalyzeKey(audio, {4096}), VibeMusicalKeyNone);
}

- (void)testSilenceReportsNoKey {
    std::vector<float> silence(kTestSampleRate * 20, 0.0f);
    XCTAssertEqual(VibeTestAnalyzeKey(silence, {65536}), VibeMusicalKeyNone);
}

// An unusable sample rate leaves the analyzer inert rather than crashing on the
// frame sizing, and appends into it are ignored.
- (void)testInvalidSampleRateReportsNoKey {
    AudioKeyAnalyzer *analyzer = [[AudioKeyAnalyzer alloc] initWithSampleRate:0];
    std::vector<float> audio = VibeTestAMinorChord(20.0);
    [analyzer appendMonoSamples:audio.data() frameCount:audio.size()];
    XCTAssertEqual([analyzer finish], VibeMusicalKeyNone);
    XCTAssertEqual(analyzer.tuningCents, 0);
}

@end
