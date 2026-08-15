//
//  AudioFXMathTests.m
//  VibeTests
//
//  AudioFX's toggles resolved to numbers: the low-kill cutoff, the ping-pong
//  delay's tap and lane times, its lane feedback, and a held send's swell
//  target. AudioFX itself owns an AVAudioEngine graph and cannot be reached
//  from a host-less suite, so this is the half of it that can be asserted
//  rather than driven through the debug channel.
//

#import <XCTest/XCTest.h>
#import "AudioFXMath.h"

@interface AudioFXMathTests : XCTestCase
@end

@implementation AudioFXMathTests

#pragma mark - Low-kill cutoff

- (void)testParkedCutoffSitsBelowTheAudibleBand {
    // "Off" is a cutoff parked below hearing, never a bypass: un-bypassing a
    // band dumps its stale delay-line state into the signal and clicks.
    XCTAssertEqual(VibeLowKillCutoffHz(NO, NO), kLowKillParkedHz);
    XCTAssertLessThan(kLowKillParkedHz, 25.0f);
}

- (void)testTheToggleEngagesTheWorkingCutoff {
    XCTAssertEqual(VibeLowKillCutoffHz(YES, NO), kLowKillCutoffHz);
}

// The boost modifies the filter rather than being an effect of its own, so it
// outranks the toggle — including the case where the toggle reads off, which
// is what makes this a three-way resolution rather than two flags.
- (void)testTheBoostOutranksTheToggle {
    XCTAssertEqual(VibeLowKillCutoffHz(YES, YES), kLowKillCutoffHz * kLowKillBoostMultiplier);
    XCTAssertEqual(VibeLowKillCutoffHz(NO, YES), kLowKillCutoffHz * kLowKillBoostMultiplier);
}

- (void)testTheThreeCutoffsAreStrictlyOrdered {
    XCTAssertLessThan(VibeLowKillCutoffHz(NO, NO), VibeLowKillCutoffHz(YES, NO));
    XCTAssertLessThan(VibeLowKillCutoffHz(YES, NO), VibeLowKillCutoffHz(YES, YES));
}

// The sweep interpolates multiplicatively, along a log-frequency curve, so a
// zero or negative endpoint would make the ratio undefined.
- (void)testEveryCutoffIsPositive {
    XCTAssertGreaterThan(VibeLowKillCutoffHz(NO, NO), 0.0f);
    XCTAssertGreaterThan(VibeLowKillCutoffHz(YES, NO), 0.0f);
    XCTAssertGreaterThan(VibeLowKillCutoffHz(YES, YES), 0.0f);
}

#pragma mark - Delay tap times

- (void)testTapIsAFractionOfABeatAtTheGivenTempo {
    // 120 BPM is a half-second beat: a 1/8-note tap is 0.25s, a 1/16 is 0.125s.
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(120, 0.5f), 0.25, 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(120, 0.25f), 0.125, 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(174, 0.5f), 60.0 / 174 * 0.5, 1e-9);
}

- (void)testTapScalesInverselyWithTempo {
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(60, 0.5f),
                               VibeDelayTapSeconds(120, 0.5f) * 2, 1e-9);
}

// No tempo known — an untagged, unanalyzed track — must not divide by zero.
- (void)testAnUnknownTempoFallsBackToTheDefault {
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(0, 0.5f),
                               VibeDelayTapSeconds(kDelayDefaultBPM, 0.5f), 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayTapSeconds(-1, 0.5f),
                               VibeDelayTapSeconds(kDelayDefaultBPM, 0.5f), 1e-9);
    XCTAssertTrue(isfinite(VibeDelayTapSeconds(0, 0.5f)));
}

// The two acyclic lanes run at twice the tap period and interleave into the
// alternating pattern a cross-fed ping-pong would give.
- (void)testALaneRunsAtTwiceTheTap {
    XCTAssertEqualWithAccuracy(VibeDelayLaneSeconds(174, 0.5f),
                               VibeDelayTapSeconds(174, 0.5f) * 2, 1e-9);
    XCTAssertEqualWithAccuracy(VibeDelayLaneSeconds(0, 0.25f),
                               VibeDelayTapSeconds(0, 0.25f) * 2, 1e-9);
}

// AVAudioUnitDelay caps delayTime at two seconds. The 1/8-note lane is the
// longest time the graph ever asks for, so it is the one that can hit the cap.
- (void)testRealTemposStayInsideTheDelayUnitsTwoSecondCeiling {
    for (float bpm = 30; bpm <= 250; bpm += 0.5f) {
        XCTAssertLessThanOrEqual(VibeDelayLaneSeconds(bpm, 0.5f), 2.0,
                                 @"1/8-note lane at %.1f BPM", bpm);
    }
    // The default, for the no-tempo case, comfortably inside it too.
    XCTAssertLessThanOrEqual(VibeDelayLaneSeconds(0, 0.5f), 2.0);
}

#pragma mark - Lane feedback

// A lane revolution is two hops, so its own feedback is the per-hop decay
// squared — the arithmetic that keeps the audible trail at the intended rate.
- (void)testLaneFeedbackIsThePerHopDecaySquared {
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(75.0f), 56.25f, 1e-4);
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(50.0f), 25.0f, 1e-4);
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(100.0f), 100.0f, 1e-4);
    XCTAssertEqualWithAccuracy(VibeDelayLaneFeedbackPercent(0.0f), 0.0f, 1e-4);
}

// Below unity it must stay below unity, or the lane's echoes grow instead of
// decaying and the delay runs away.
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

// The gate is a mixer's outputVolume, so the swelled level has to stay inside
// unity for the ratios the sends actually use.
- (void)testTheShippedSendLevelsSwellWithinUnity {
    XCTAssertLessThanOrEqual(VibeSendSwellLevel(0.3f, 1.8f), 1.0f);
}

@end
