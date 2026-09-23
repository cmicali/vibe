//
//  FadeMathTests.m
//  VibeTests
//
//  The fade curves and the rule that picks a track change's fade length. The
//  voice bus evaluates the curves per frame on the audio thread and AudioFX's
//  send gates step the log curve on the player queue; neither class is
//  reachable from a host-less suite, so the header is where their shared
//  arithmetic is asserted.
//

#import <XCTest/XCTest.h>
#import "FadeMath.h"

@interface FadeMathTests : XCTestCase
@end

@implementation FadeMathTests

#pragma mark - The per-frame curves

- (void)testEveryCurveStartsAtTheSourceAndLandsExactlyOnTheTarget {
    const uint32_t frames = 480;
    for (VibeFadeCurve curve = VibeFadeCurveLinear; curve <= VibeFadeCurveEqualPower; curve++) {
        XCTAssertEqual(VibeFadeGainAtFrame(curve, 1.0f, 0.0f, 0, frames), 1.0f, @"curve %d", curve);
        // Exactly: the landing frame is what leaves a paused voice at true
        // silence and a resumed one at true unity.
        XCTAssertEqual(VibeFadeGainAtFrame(curve, 1.0f, 0.0f, frames, frames), 0.0f, @"curve %d", curve);
        XCTAssertEqual(VibeFadeGainAtFrame(curve, 0.0f, 1.0f, frames, frames), 1.0f, @"curve %d", curve);
        XCTAssertEqual(VibeFadeGainAtFrame(curve, 0.0f, 0.25f, frames + 7, frames), 0.25f, @"curve %d", curve);
    }
}

- (void)testAZeroLengthFadeIsACut {
    XCTAssertEqual(VibeFadeGainAtFrame(VibeFadeCurveLinear, 1.0f, 0.0f, 0, 0), 0.0f);
    XCTAssertEqual(VibeFadeGainAtFrame(VibeFadeCurveEqualPower, 0.0f, 1.0f, 0, 0), 1.0f);
}

- (void)testEveryCurveIsMonotonicAndFinite {
    const uint32_t frames = 1000;
    for (VibeFadeCurve curve = VibeFadeCurveLinear; curve <= VibeFadeCurveEqualPower; curve++) {
        float previousOut = 2.0f, previousIn = -1.0f;
        for (uint32_t frame = 0; frame <= frames; frame++) {
            float out = VibeFadeGainAtFrame(curve, 1.0f, 0.0f, frame, frames);
            float in = VibeFadeGainAtFrame(curve, 0.0f, 1.0f, frame, frames);
            XCTAssertTrue(isfinite(out) && isfinite(in), @"curve %d frame %u", curve, frame);
            XCTAssertLessThanOrEqual(out, previousOut, @"curve %d frame %u rose", curve, frame);
            XCTAssertGreaterThanOrEqual(in, previousIn, @"curve %d frame %u fell", curve, frame);
            previousOut = out;
            previousIn = in;
        }
    }
}

// The declick's whole job. The render suite bounds a 0.25-amplitude signal's
// per-sample step below 0.002 at every rate; the slowest rate is the worst case.
- (void)testTheDeclickStepIsInaudibleAtEveryRate {
    const double rates[] = { 44100, 48000, 88200, 96000, 176400, 192000 };
    for (size_t r = 0; r < sizeof(rates) / sizeof(rates[0]); r++) {
        uint32_t frames = VibeFadeFramesForMilliseconds(kFadeDurationMilliseconds, rates[r]);
        VibeFadeCurve curve = VibeFadeCurveForMilliseconds(kFadeDurationMilliseconds);
        float previous = 0.25f * VibeFadeGainAtFrame(curve, 0.0f, 1.0f, 0, frames);
        for (uint32_t frame = 1; frame <= frames; frame++) {
            float gain = 0.25f * VibeFadeGainAtFrame(curve, 0.0f, 1.0f, frame, frames);
            XCTAssertLessThan(fabsf(gain - previous), 0.002f, @"%.0f Hz frame %u", rates[r], frame);
            previous = gain;
        }
    }
}

// The reason the second curve exists: two complementary sides must sum to
// about unity POWER, so a long crossfade holds level instead of dipping at
// the midpoint, which is what a linear pair does.
- (void)testEqualPowerSidesSumToConstantPower {
    const uint32_t frames = 1000;
    for (uint32_t frame = 0; frame <= frames; frame++) {
        float out = VibeFadeGainAtFrame(VibeFadeCurveEqualPower, 1.0f, 0.0f, frame, frames);
        float in = VibeFadeGainAtFrame(VibeFadeCurveEqualPower, 0.0f, 1.0f, frame, frames);
        XCTAssertEqualWithAccuracy(out * out + in * in, 1.0f, 1e-5, @"frame %u", frame);
    }
    XCTAssertEqualWithAccuracy(VibeFadeGainAtFrame(VibeFadeCurveEqualPower, 1.0f, 0.0f, frames / 2, frames),
                               sqrtf(0.5f), 1e-5);
}

- (void)testDeclickLengthsAreLinearAndLongerOnesEqualPower {
    XCTAssertEqual(VibeFadeCurveForMilliseconds(kFadeDurationMilliseconds), VibeFadeCurveLinear);
    XCTAssertEqual(VibeFadeCurveForMilliseconds(kFadeDurationMilliseconds - 1), VibeFadeCurveLinear);
    XCTAssertEqual(VibeFadeCurveForMilliseconds(kFadeDurationMilliseconds + 1), VibeFadeCurveEqualPower);
    XCTAssertEqual(VibeFadeCurveForMilliseconds(2000), VibeFadeCurveEqualPower);
}

- (void)testFadeFramesFollowTheSampleRate {
    XCTAssertEqual(VibeFadeFramesForMilliseconds(10, 48000), 480u);
    XCTAssertEqual(VibeFadeFramesForMilliseconds(10, 44100), 441u);
    XCTAssertEqual(VibeFadeFramesForMilliseconds(2000, 96000), 192000u);
    XCTAssertEqual(VibeFadeFramesForMilliseconds(0, 48000), 0u);
}

#pragma mark - The stepped log curve (AudioFX's gates)

- (void)testLogFadeStartsAtTheSourceAndLandsExactlyOnTheTarget {
    XCTAssertEqualWithAccuracy(VibeFadeVolumeOverSteps(1.0f, 0.0f, 0, kFadeSteps), 1.0f, 1e-6);
    XCTAssertEqual(VibeFadeVolumeOverSteps(1.0f, 0.0f, kFadeSteps, kFadeSteps), 0.0f);
    XCTAssertEqual(VibeFadeVolumeOverSteps(0.0f, 1.0f, kFadeSteps, kFadeSteps), 1.0f);
    XCTAssertEqual(VibeFadeVolumeOverSteps(1.0f, 0.25f, kFadeSteps + 7, kFadeSteps), 0.25f);
}

- (void)testLogFadeIsMonotonicAndFiniteThroughSilence {
    float previousOut = 2.0f, previousIn = -1.0f;
    for (int step = 0; step <= kFadeSteps; step++) {
        float out = VibeFadeVolumeOverSteps(1.0f, 0.0f, step, kFadeSteps);
        float in = VibeFadeVolumeOverSteps(0.0f, 1.0f, step, kFadeSteps);
        XCTAssertTrue(isfinite(out) && isfinite(in), @"step %d", step);
        XCTAssertTrue(out >= 0.0f && out <= 1.0f && in >= 0.0f && in <= 1.0f, @"step %d", step);
        XCTAssertLessThan(out, previousOut, @"fade-out step %d rose", step);
        XCTAssertGreaterThan(in, previousIn, @"fade-in step %d fell", step);
        previousOut = out;
        previousIn = in;
    }
}

#pragma mark - The track-change fade length

// The one case the user's crossfade setting applies to.
- (void)testReplacingAnAudiblyPlayingTrackTakesTheCrossfadeSetting {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, YES, NO), 2000u);
    XCTAssertEqual(VibeIncomingFadeMilliseconds(500, YES, NO), 500u);
}

// A first play, or one from pause or stop: nothing is sounding to fade
// against, so transport stays instant however long the setting is.
- (void)testAPlayWithNothingAudibleTakesTheDeclickMinimum {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, NO, NO), kFadeDurationMilliseconds);
}

// The convert swap replaces a track with its own audio at the same position,
// which a crossfade would only dip.
- (void)testTheDeclickFlagOverridesTheSetting {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, YES, YES), kFadeDurationMilliseconds);
}

// The setting can only ever lengthen the fade: below the declick minimum it
// would fade faster than the minimum that stops the click.
- (void)testTheSettingCannotFadeFasterThanTheDeclickMinimum {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(0, YES, NO), kFadeDurationMilliseconds);
    XCTAssertEqual(VibeIncomingFadeMilliseconds(-100, YES, NO), kFadeDurationMilliseconds);
    XCTAssertEqual(VibeIncomingFadeMilliseconds((NSInteger)kFadeDurationMilliseconds, YES, NO),
                   kFadeDurationMilliseconds);
}

// Only the declick minimum, which the UI presents as crossfade off, permits a
// gapless splice; a longer setting asks for overlapped transitions.
- (void)testGaplessArmsOnlyAtTheDeclickMinimum {
    XCTAssertTrue(VibeGaplessArmAllowed(10));
    XCTAssertTrue(VibeGaplessArmAllowed(0));
    XCTAssertFalse(VibeGaplessArmAllowed(500));
    XCTAssertFalse(VibeGaplessArmAllowed(2000));
}

@end
