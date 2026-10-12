//
//  AudioBPMAnalyzerTests.mm
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "AudioBPMAnalyzer.h"
#include <vector>
#include <cmath>

// The analyzer frames the stream itself from whatever buffers the decoder
// hands it; a result that depended on the split would make a file's tempo
// depend on its codec's packet size.

static const double kTestSampleRate = 44100.0;

// A click track: one short decaying burst per beat over a quiet tone, which is
// enough onset structure for the envelope and the phase comb.
static std::vector<float> VibeTestClickTrack(double bpm, double seconds, double rate = kTestSampleRate) {
    const size_t total = (size_t)(rate * seconds);
    const double period = 60.0 / bpm * rate;
    const double scale = kTestSampleRate / rate; // the same sound at any rate
    std::vector<float> out(total);
    for (size_t i = 0; i < total; i++) {
        double sinceBeat = std::fmod((double)i, period);
        double click = std::exp(-sinceBeat * scale / 200.0) * std::sin((double)i * scale * 0.7);
        out[i] = (float)(0.9 * click + 0.05 * std::sin((double)i * scale * 0.03));
    }
    return out;
}

static float VibeTestAnalyze(const std::vector<float> &audio, const std::vector<size_t> &chunks,
                             double rate = kTestSampleRate) {
    AudioBPMAnalyzer *analyzer = [[AudioBPMAnalyzer alloc] initWithSampleRate:rate];
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

// Sizes below, around and above the 1024-sample analysis frame.
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

// A file at twice the 44.1/48 kHz family or more is decimated first; the
// filter's history crosses appends, so the split still never reaches the result.
- (void)testHighRatesFindTheTempoWhateverTheBufferSizes {
    for (double rate : {96000.0, 192000.0}) {
        std::vector<float> audio = VibeTestClickTrack(128.0, 30.0, rate);
        float reference = VibeTestAnalyze(audio, {audio.size()}, rate);
        XCTAssertEqualWithAccuracy(reference, 128.0f, 1.0f, @"at %.0f Hz", rate);
        for (const std::vector<size_t> &chunks : std::vector<std::vector<size_t>>{{1}, {3, 1025, 64}, {65536}}) {
            XCTAssertEqual(VibeTestAnalyze(audio, chunks, rate), reference, @"at %.0f Hz, first chunk %zu",
                           rate, chunks.front());
        }
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
