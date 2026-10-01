//
//  FadeMathTests.m
//  VibeTests
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
        // Exactly: a paused voice lands at true silence, a resumed one at unity.
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

// The render suite's bound: a 0.25-amplitude signal steps under 0.002 per sample.
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

- (void)testReplacingAnAudiblyPlayingTrackTakesTheCrossfadeSetting {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, YES, NO), 2000u);
    XCTAssertEqual(VibeIncomingFadeMilliseconds(500, YES, NO), 500u);
}

- (void)testAPlayWithNothingAudibleTakesTheDeclickMinimum {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, NO, NO), kFadeDurationMilliseconds);
}

// The convert swap replaces a track with its own audio, which a crossfade would only dip.
- (void)testTheDeclickFlagOverridesTheSetting {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, YES, YES), kFadeDurationMilliseconds);
}

- (void)testTheSettingCannotFadeFasterThanTheDeclickMinimum {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(0, YES, NO), kFadeDurationMilliseconds);
    XCTAssertEqual(VibeIncomingFadeMilliseconds(-100, YES, NO), kFadeDurationMilliseconds);
    XCTAssertEqual(VibeIncomingFadeMilliseconds((NSInteger)kFadeDurationMilliseconds, YES, NO),
                   kFadeDurationMilliseconds);
}

// The declick minimum is what the UI presents as crossfade off.
- (void)testGaplessArmsOnlyAtTheDeclickMinimum {
    XCTAssertTrue(VibeGaplessArmAllowed(10, NO));
    XCTAssertTrue(VibeGaplessArmAllowed(0, NO));
    XCTAssertFalse(VibeGaplessArmAllowed(500, NO));
    XCTAssertFalse(VibeGaplessArmAllowed(2000, NO));
}

// The next window of the same file is one recording: a crossfade would
// overlap it with itself.
- (void)testGaplessArmsIntoTheNextWindowOfTheFileWhateverTheCrossfade {
    XCTAssertTrue(VibeGaplessArmAllowed(2000, YES));
    XCTAssertTrue(VibeGaplessArmAllowed(10, YES));
}

@end
