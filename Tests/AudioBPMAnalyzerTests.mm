//
//  AudioBPMAnalyzerTests.mm
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "AudioBPMAnalyzer.h"
#include <vector>
#include <cmath>

// The analyzer is fed whatever frame counts the decoder hands the waveform
// loader, and it frames the stream itself: analysis frames overlap, so most of
// them straddle a buffer boundary. Anything that depends on where the caller's
// buffers happen to split would make the tempo of a file depend on its codec's
// packet size, so the tests below pin the result to the audio alone.

static const double kTestSampleRate = 44100.0;

// A click track: one short decaying burst per beat over a quiet tone, which is
// enough onset structure for the envelope and the phase comb.
static std::vector<float> VibeTestClickTrack(double bpm, double seconds) {
    const size_t total = (size_t)(kTestSampleRate * seconds);
    const double period = 60.0 / bpm * kTestSampleRate;
    std::vector<float> out(total);
    for (size_t i = 0; i < total; i++) {
        double sinceBeat = std::fmod((double)i, period);
        double click = std::exp(-sinceBeat / 200.0) * std::sin((double)i * 0.7);
        out[i] = (float)(0.9 * click + 0.05 * std::sin((double)i * 0.03));
    }
    return out;
}

static float VibeTestAnalyze(const std::vector<float> &audio, const std::vector<size_t> &chunks) {
    AudioBPMAnalyzer *analyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:kTestSampleRate];
    size_t offset = 0, index = 0;
    while (offset < audio.size()) {
        size_t take = std::min(chunks[index++ % chunks.size()], audio.size() - offset);
        [analyzer appendMonoSamples:audio.data() + offset frameCount:take];
        offset += take;
    }
    return [analyzer finish];
}

@interface AudioBPMAnalyzerTests : XCTestCase
@end

@implementation AudioBPMAnalyzerTests

- (void)testDetectsSteadyClickTrackTempo {
    std::vector<float> audio = VibeTestClickTrack(128.0, 30.0);
    float bpm = VibeTestAnalyze(audio, {65536});
    XCTAssertEqualWithAccuracy(bpm, 128.0f, 1.0f);
}

// The framing invariant: the buffer sizes the caller happens to use must not
// reach the result. Sizes below, around and above the 1024-sample analysis
// frame all appear here, including ones that leave a straddling frame short.
- (void)testResultIsIndependentOfBufferSizes {
    std::vector<float> audio = VibeTestClickTrack(128.0, 30.0);
    float reference = VibeTestAnalyze(audio, {audio.size()});
    XCTAssertGreaterThan(reference, 0.0f);

    const std::vector<std::vector<size_t>> chunkings = {
        {1}, {255}, {256}, {257}, {1023}, {1024}, {1025},
        {7, 1500, 63, 4096, 1}, {512, 1}, {65536}, {100000},
    };
    for (const std::vector<size_t> &chunks : chunkings) {
        float bpm = VibeTestAnalyze(audio, chunks);
        XCTAssertEqualWithAccuracy(bpm, reference, 0.001f,
                                   @"first chunk size %zu", chunks.front());
    }
}

- (void)testTooShortAudioReportsNoTempo {
    std::vector<float> audio = VibeTestClickTrack(128.0, 4.0);
    XCTAssertEqual(VibeTestAnalyze(audio, {4096}), 0.0f);
}

- (void)testEmptyInputReportsNoTempo {
    AudioBPMAnalyzer *analyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:kTestSampleRate];
    float silence[512] = {0};
    [analyzer appendMonoSamples:silence frameCount:0];
    XCTAssertEqual([analyzer finish], 0.0f);
}

@end
