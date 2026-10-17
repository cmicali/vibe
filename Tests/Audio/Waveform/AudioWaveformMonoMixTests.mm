//
//  AudioWaveformMonoMixTests.mm
//  VibeTests
//
//  The mono mix the summary and both analyzers share. The summary's own tests
//  are WaveformSummaryTests, in WaveformCore/.
//

#import <XCTest/XCTest.h>

#import "AudioWaveform.h"

@interface AudioWaveformMonoMixTests : XCTestCase
@end

@implementation AudioWaveformMonoMixTests

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
