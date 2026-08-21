//
//  AudioFileOpenTimeoutMathTests.m
//

#import <XCTest/XCTest.h>

#import "AudioFileOpenTimeoutMath.h"

@interface AudioFileOpenTimeoutMathTests : XCTestCase
@end

@implementation AudioFileOpenTimeoutMathTests

- (void)testNoPositiveProgressExpiresAtTheWholeBaseline {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenDefaultTimeoutConfiguration();
    XCTAssertEqual(VibeAudioOpenEffectiveDeadline(1000, 0, configuration), 1060);
}

- (void)testEarlyProgressCannotShortenTheBaseline {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenDefaultTimeoutConfiguration();
    XCTAssertEqual(VibeAudioOpenEffectiveDeadline(1000, 1001, configuration), 1061);
}

- (void)testThirtySecondCadenceSurvivesTheOldTwentySecondWindow {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenDefaultTimeoutConfiguration();
    NSTimeInterval submitted = 1000;
    NSTimeInterval sampleAtSixty = 1060;
    NSTimeInterval deadline = VibeAudioOpenEffectiveDeadline(
            submitted, sampleAtSixty, configuration);
    XCTAssertGreaterThan(deadline, 1090);
    XCTAssertGreaterThan(VibeAudioOpenDeadlineRemaining(
            1089, submitted, sampleAtSixty, configuration), 0);
}

- (void)testLateProgressGetsTheFullSilenceAllowance {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenDefaultTimeoutConfiguration();
    XCTAssertEqual(VibeAudioOpenEffectiveDeadline(1000, 1059, configuration), 1119);
}

- (void)testPostProgressStallExpiresAtItsSilenceDeadline {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenDefaultTimeoutConfiguration();
    XCTAssertEqual(VibeAudioOpenDeadlineRemaining(1119, 1000, 1059, configuration), 0);
}

- (void)testDeadlineRemainingClampsAtZero {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenTimeoutConfigurationMake(5, 7);
    XCTAssertEqual(VibeAudioOpenDeadlineRemaining(1010, 1000, 0, configuration), 0);
}

- (void)testDiagnosticConfigurationUsesPositiveFiniteValues {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenTimeoutConfigurationMake(2.5, 4.5);
    XCTAssertEqual(configuration.noProgressSeconds, 2.5);
    XCTAssertEqual(configuration.progressSilenceSeconds, 4.5);
}

- (void)testInvalidDiagnosticConfigurationFallsBackToDefaults {
    VibeAudioOpenTimeoutConfiguration configuration =
            VibeAudioOpenTimeoutConfigurationMake(NAN, -1);
    XCTAssertEqual(configuration.noProgressSeconds,
                   kVibeAudioOpenDefaultNoProgressSeconds);
    XCTAssertEqual(configuration.progressSilenceSeconds,
                   kVibeAudioOpenDefaultProgressSilenceSeconds);
}

@end
