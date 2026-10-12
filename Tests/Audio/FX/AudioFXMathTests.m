//
//  AudioFXMathTests.m
//  VibeTests
//
//  The numbers AudioFX's toggles and the iOS pad resolve to, without hosting
//  a unit; AudioFXChainTests renders the chain itself.
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

#pragma mark - The iOS pad

// The bottom edge and below are the parked, colorless off; the top edge is
// the ceiling; between them the cutoff climbs a log curve, so the midpoint
// is the geometric mean, an equal musical interval from either end.
- (void)testThePadsBottomIsParkedAndItsTopIsTheCeiling {
    XCTAssertEqual(VibeFXPadLowCutHz(0), kLowKillParkedHz);
    XCTAssertEqual(VibeFXPadLowCutHz(-0.5f), kLowKillParkedHz);
    XCTAssertEqualWithAccuracy(VibeFXPadLowCutHz(1), kFXPadLowCutMaxHz, 1e-3);
    XCTAssertEqualWithAccuracy(VibeFXPadLowCutHz(2), kFXPadLowCutMaxHz, 1e-3);
    XCTAssertEqualWithAccuracy(VibeFXPadLowCutHz(0.5f), sqrtf(kLowKillParkedHz * kFXPadLowCutMaxHz), 1e-2);
}

- (void)testThePadsCutoffRisesMonotonicallyAndStaysPositive {
    float previous = 0;
    for (float y = 0; y <= 1.0001f; y += 0.05f) {
        float cutoff = VibeFXPadLowCutHz(y);
        XCTAssertGreaterThan(cutoff, 0.0f);
        XCTAssertGreaterThanOrEqual(cutoff, previous, @"y %.2f", y);
        previous = cutoff;
    }
}

// The mac's momentary boost is reachable on the pad: it sits inside the
// sweep, not past its ceiling.
- (void)testThePadReachesTheMacsCutoffs {
    XCTAssertLessThan(kLowKillCutoffHz * kLowKillBoostMultiplier, kFXPadLowCutMaxHz);
    XCTAssertGreaterThan(kLowKillCutoffHz, kLowKillParkedHz);
}

// The reverb rides the whole axis; the delay waits for the onset and then
// climbs to full beside it, so the far right is both at 1.
- (void)testThePadsHorizontalAxisIsReverbThenDelay {
    XCTAssertEqual(VibeFXPadReverbLevel(0), 0.0f);
    XCTAssertEqual(VibeFXPadReverbLevel(-1), 0.0f);
    XCTAssertEqualWithAccuracy(VibeFXPadReverbLevel(0.25f), 0.25f, 1e-6);
    XCTAssertEqual(VibeFXPadReverbLevel(1), 1.0f);
    XCTAssertEqual(VibeFXPadReverbLevel(3), 1.0f);

    XCTAssertEqual(VibeFXPadDelayLevel(0), 0.0f);
    XCTAssertEqual(VibeFXPadDelayLevel(kFXPadDelayOnset), 0.0f);
    XCTAssertEqualWithAccuracy(VibeFXPadDelayLevel((1 + kFXPadDelayOnset) / 2), 0.5f, 1e-6);
    XCTAssertEqual(VibeFXPadDelayLevel(1), 1.0f);
    XCTAssertEqual(VibeFXPadDelayLevel(3), 1.0f);
}

- (void)testThePadsLevelsAreWithinUnityEverywhere {
    for (float x = -0.5f; x <= 1.5f; x += 0.05f) {
        XCTAssertGreaterThanOrEqual(VibeFXPadReverbLevel(x), 0.0f);
        XCTAssertLessThanOrEqual(VibeFXPadReverbLevel(x), 1.0f);
        XCTAssertGreaterThanOrEqual(VibeFXPadDelayLevel(x), 0.0f);
        XCTAssertLessThanOrEqual(VibeFXPadDelayLevel(x), 1.0f);
    }
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
