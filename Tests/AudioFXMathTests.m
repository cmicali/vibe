//
//  AudioFXMathTests.m
//  VibeTests
//
//  The numbers AudioFX's toggles resolve to, without hosting a unit;
//  AudioFXChainTests renders the chain itself.
//

#import <XCTest/XCTest.h>
#import "AudioFXMath.h"

@interface AudioFXMathTests : XCTestCase
@end

@implementation AudioFXMathTests

#pragma mark - Low-kill cutoff

- (void)testParkedCutoffSitsBelowTheAudibleBand {
    XCTAssertEqual(VibeLowKillCutoffHz(NO, NO), kLowKillParkedHz);
    XCTAssertLessThan(kLowKillParkedHz, 25.0f);
}

- (void)testTheToggleEngagesTheWorkingCutoff {
    XCTAssertEqual(VibeLowKillCutoffHz(YES, NO), kLowKillCutoffHz);
}

// Including while the toggle reads off: the boost runs the filter on its own.
- (void)testTheBoostOutranksTheToggle {
    XCTAssertEqual(VibeLowKillCutoffHz(YES, YES), kLowKillCutoffHz * kLowKillBoostMultiplier);
    XCTAssertEqual(VibeLowKillCutoffHz(NO, YES), kLowKillCutoffHz * kLowKillBoostMultiplier);
}

- (void)testTheThreeCutoffsAreStrictlyOrdered {
    XCTAssertLessThan(VibeLowKillCutoffHz(NO, NO), VibeLowKillCutoffHz(YES, NO));
    XCTAssertLessThan(VibeLowKillCutoffHz(YES, NO), VibeLowKillCutoffHz(YES, YES));
}

// The sweep interpolates in log frequency, so a non-positive endpoint is undefined.
- (void)testEveryCutoffIsPositive {
    XCTAssertGreaterThan(VibeLowKillCutoffHz(NO, NO), 0.0f);
    XCTAssertGreaterThan(VibeLowKillCutoffHz(YES, NO), 0.0f);
    XCTAssertGreaterThan(VibeLowKillCutoffHz(YES, YES), 0.0f);
}

#pragma mark - Delay tap times

- (void)testTapIsAFractionOfABeatAtTheGivenTempo {
    // 120 BPM is a half-second beat.
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(120, 0.5f), 0.25, 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(120, 0.25f), 0.125, 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(174, 0.5f), 60.0 / 174 * 0.5, 1e-9);
}

- (void)testTapScalesInverselyWithTempo {
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(60, 0.5f),
                               VibeDelayTapSeconds(120, 0.5f) * 2, 1e-9);
}

- (void)testAnUnknownTempoFallsBackToTheDefault {
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(0, 0.5f),
                               VibeDelayTapSeconds(kDelayDefaultBPM, 0.5f), 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(-1, 0.5f),
                               VibeDelayTapSeconds(kDelayDefaultBPM, 0.5f), 1e-9);
    XCTAssertTrue(isfinite(VibeDelayTapSeconds(0, 0.5f)));
}

// The two lanes interleave at twice the tap period into a ping-pong.
- (void)testALaneRunsAtTwiceTheTap {
    XCTAssertEqualWithAccuracy(VibeDelayLaneSeconds(174, 0.5f),
                               VibeDelayTapSeconds(174, 0.5f) * 2, 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayLaneSeconds(0, 0.25f),
                               VibeDelayTapSeconds(0, 0.25f) * 2, 1e-9);
}

// AUDelay caps its delay time at two seconds; the 1/8-note lane is the longest
// time the chain asks for.
- (void)testRealTemposStayInsideTheDelayUnitsTwoSecondCeiling {
    for (float bpm = 30; bpm <= 250; bpm += 0.5f) {
        XCTAssertLessThanOrEqual(VibeDelayLaneSeconds(bpm, 0.5f), 2.0,
                                 @"1/8-note lane at %.1f BPM", bpm);
    }
    XCTAssertLessThanOrEqual(VibeDelayLaneSeconds(0, 0.5f), 2.0);
}

#pragma mark - Lane feedback

// One lane revolution is two hops.
- (void)testLaneFeedbackIsThePerHopDecaySquared {
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(75.0f), 56.25f, 1e-4);
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(50.0f), 25.0f, 1e-4);
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(100.0f), 100.0f, 1e-4);
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(0.0f), 0.0f, 1e-4);
}

// Otherwise the lane's echoes grow and the delay runs away.
- (void)testLaneFeedbackNeverExceedsItsInput {
    for (float hop = 0; hop <= 100; hop += 5) {
        float lane = VibeDelayLaneFeedbackPercent(hop);
        XCTAssertLessThanOrEqual(lane, hop + 1e-4, @"hop %.0f%%", hop);
        XCTAssertGreaterThanOrEqual(lane, 0.0f);
    }
}

#pragma mark - Send swell

- (void)testSwellMultipliesTheBaseLevel {
    XCTAssertEqualWithAccuracy(VibeSendSwellLevel(0.3f, 1.8f), 0.54f, 1e-5);
    XCTAssertEqualWithAccuracy(VibeSendSwellLevel(0.3f, 1.0f), 0.3f, 1e-5);
}

// 0.3 and 1.8 are AudioFX's send level and swell ratio; a gate past unity
// would boost the return.
- (void)testTheShippedSendLevelsSwellWithinUnity {
    XCTAssertLessThanOrEqual(VibeSendSwellLevel(0.3f, 1.8f), 1.0f);
}

@end
