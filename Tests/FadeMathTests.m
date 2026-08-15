//
//  FadeMathTests.m
//  VibeTests
//
//  The fade curves, the cadence, and the rule that picks a track change's fade
//  length. AudioPlayer's node fades and AudioFX's send gates both step through
//  these, and neither class is reachable from a host-less suite — an
//  AVAudioEngine is the other side of the line this suite draws — so the
//  header is where their shared arithmetic can actually be asserted.
//

#import <XCTest/XCTest.h>
#import "FadeMath.h"

@interface FadeMathTests : XCTestCase
@end

@implementation FadeMathTests

#pragma mark - The declick (log) curve

- (void)testLogFadeStartsAtTheSourceAndLandsExactlyOnTheTarget {
    XCTAssertEqualWithAccuracy(VibeFadeVolumeOverSteps(1.0f, 0.0f, 0, kFadeSteps), 1.0f, 1e-6);
    // Exactly, not approximately: the final step is what leaves a paused node
    // at true silence and a resumed one at true unity.
    XCTAssertEqual(VibeFadeVolumeOverSteps(1.0f, 0.0f, kFadeSteps, kFadeSteps), 0.0f);
    XCTAssertEqual(VibeFadeVolumeOverSteps(0.0f, 1.0f, kFadeSteps, kFadeSteps), 1.0f);
}

- (void)testLogFadeIsMonotonicInBothDirections {
    float previous = VibeFadeVolumeOverSteps(1.0f, 0.0f, 0, kFadeSteps);
    for (int step = 1; step <= kFadeSteps; step++) {
        float volume = VibeFadeVolumeOverSteps(1.0f, 0.0f, step, kFadeSteps);
        XCTAssertLessThan(volume, previous, @"fade-out step %d rose", step);
        previous = volume;
    }
    previous = VibeFadeVolumeOverSteps(0.0f, 1.0f, 0, kFadeSteps);
    for (int step = 1; step <= kFadeSteps; step++) {
        float volume = VibeFadeVolumeOverSteps(0.0f, 1.0f, step, kFadeSteps);
        XCTAssertGreaterThan(volume, previous, @"fade-in step %d fell", step);
        previous = volume;
    }
}

// The floor is what keeps the log interpolation defined through silence: a
// literal zero endpoint would make the ratio 0 or infinite.
- (void)testLogFadeStaysFiniteAndInRangeThroughSilence {
    for (int step = 0; step <= kFadeSteps; step++) {
        float out = VibeFadeVolumeOverSteps(1.0f, 0.0f, step, kFadeSteps);
        float in = VibeFadeVolumeOverSteps(0.0f, 1.0f, step, kFadeSteps);
        XCTAssertTrue(isfinite(out), @"step %d", step);
        XCTAssertTrue(isfinite(in), @"step %d", step);
        XCTAssertGreaterThanOrEqual(out, 0.0f);
        XCTAssertLessThanOrEqual(out, 1.0f);
        XCTAssertGreaterThanOrEqual(in, 0.0f);
        XCTAssertLessThanOrEqual(in, 1.0f);
    }
}

- (void)testAStepPastTheEndClampsToTheTarget {
    XCTAssertEqual(VibeFadeVolumeOverSteps(1.0f, 0.25f, kFadeSteps + 7, kFadeSteps), 0.25f);
    XCTAssertEqual(VibeCrossfadeVolumeOverSteps(1.0f, 0.25f, kFadeSteps + 7, kFadeSteps), 0.25f);
}

#pragma mark - The crossfade (equal-power) curve

// The reason this curve exists: two complementary sides must sum to about
// unity POWER, so a long crossfade holds level instead of dipping to
// near-silence at the midpoint, which is what a linear or log pair does.
- (void)testCrossfadeSidesSumToConstantPower {
    const int steps = 100;
    for (int step = 0; step <= steps; step++) {
        float out = VibeCrossfadeVolumeOverSteps(1.0f, 0.0f, step, steps);
        float in = VibeCrossfadeVolumeOverSteps(0.0f, 1.0f, step, steps);
        XCTAssertEqualWithAccuracy(out * out + in * in, 1.0f, 1e-5, @"step %d", step);
    }
}

- (void)testCrossfadeMidpointSitsWellAboveTheLogCurves {
    const int steps = 100;
    float equalPower = VibeCrossfadeVolumeOverSteps(1.0f, 0.0f, steps / 2, steps);
    float log = VibeFadeVolumeOverSteps(1.0f, 0.0f, steps / 2, steps);
    XCTAssertEqualWithAccuracy(equalPower, sqrtf(0.5f), 1e-5);
    XCTAssertGreaterThan(equalPower, log);
}

#pragma mark - Curve selection by length

- (void)testDeclickLengthsTakeTheLogCurveAndLongerOnesEqualPower {
    const int steps = 10;
    XCTAssertEqual(VibeFadeVolumeForFadeLength(kFadeDurationMilliseconds, 1.0f, 0.0f, 5, steps),
                   VibeFadeVolumeOverSteps(1.0f, 0.0f, 5, steps));
    XCTAssertEqual(VibeFadeVolumeForFadeLength(kFadeDurationMilliseconds - 1, 1.0f, 0.0f, 5, steps),
                   VibeFadeVolumeOverSteps(1.0f, 0.0f, 5, steps));
    XCTAssertEqual(VibeFadeVolumeForFadeLength(kFadeDurationMilliseconds + 1, 1.0f, 0.0f, 5, steps),
                   VibeCrossfadeVolumeOverSteps(1.0f, 0.0f, 5, steps));
    XCTAssertEqual(VibeFadeVolumeForFadeLength(2000, 1.0f, 0.0f, 5, steps),
                   VibeCrossfadeVolumeOverSteps(1.0f, 0.0f, 5, steps));
}

#pragma mark - Cadence

- (void)testTheDeclickLengthKeepsTheFixedStepCount {
    XCTAssertEqual(VibeFadeStepsForMilliseconds(kFadeDurationMilliseconds), kFadeSteps);
    XCTAssertEqual(VibeFadeStepMicrosecondsForMilliseconds(kFadeDurationMilliseconds),
                   kFadeStepMicroseconds);
}

// A one-step ramp snaps straight to the target, which is the click the fade
// exists to avoid — so the step count rounds UP.
- (void)testShortFadesPastTheDeclickLengthNeverCollapseToOneStep {
    for (uint64_t ms = kFadeDurationMilliseconds + 1; ms <= 19; ms++) {
        XCTAssertGreaterThan(VibeFadeStepsForMilliseconds(ms), 1, @"%llu ms", ms);
    }
}

- (void)testLongFadesHoldRoughlyTenMillisecondsPerStep {
    // The tunable that keeps a 2s crossfade smooth rather than ten audible
    // stairs. Ten steps for 100ms, two hundred for 2s.
    XCTAssertEqual(VibeFadeStepsForMilliseconds(100), 10);
    XCTAssertEqual(VibeFadeStepsForMilliseconds(500), 50);
    XCTAssertEqual(VibeFadeStepsForMilliseconds(2000), 200);
    XCTAssertEqual(VibeFadeStepMicrosecondsForMilliseconds(2000), 10000);
    XCTAssertEqual(VibeFadeStepMicrosecondsForMilliseconds(500), 10000);
}

// steps x stepMicroseconds must actually come to the requested length, or a
// crossfade's two sides drift apart from each other.
- (void)testCadenceMultipliesBackOutToTheRequestedLength {
    const uint64_t lengths[] = { 11, 20, 100, 250, 500, 1000, 2000 };
    for (size_t i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        uint64_t ms = lengths[i];
        uint64_t total = (uint64_t)VibeFadeStepsForMilliseconds(ms)
                * VibeFadeStepMicrosecondsForMilliseconds(ms);
        XCTAssertEqualWithAccuracy((double)total, (double)ms * 1000, (double)ms * 100,
                                   @"%llu ms", ms);
    }
}

#pragma mark - The track-change fade length

// The one case the user's crossfade setting applies to.
- (void)testReplacingAnAudiblyPlayingTrackTakesTheCrossfadeSetting {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, YES, NO, NO), 2000u);
    XCTAssertEqual(VibeIncomingFadeMilliseconds(500, YES, NO, NO), 500u);
}

// A first play, or one from pause or stop: nothing is sounding to fade
// against, so transport stays instant however long the setting is.
- (void)testAPlayWithNothingAudibleTakesTheDeclickMinimum {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, NO, NO, NO), kFadeDurationMilliseconds);
}

// The convert swap replaces a track with its own audio at the same position,
// which a crossfade would only dip.
- (void)testTheDeclickFlagOverridesTheSetting {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, YES, YES, NO), kFadeDurationMilliseconds);
}

// A crossfade-length retire would let the queued splice start sounding on the
// retiring node mid-crossfade, doubled under the incoming track.
- (void)testAQueuedGaplessSegmentForcesTheDeclickMinimum {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(2000, YES, NO, YES), kFadeDurationMilliseconds);
}

// The setting can only ever lengthen the fade: below the declick minimum it
// would fade faster than the minimum that stops the click.
- (void)testTheSettingCannotFadeFasterThanTheDeclickMinimum {
    XCTAssertEqual(VibeIncomingFadeMilliseconds(0, YES, NO, NO), kFadeDurationMilliseconds);
    XCTAssertEqual(VibeIncomingFadeMilliseconds(-100, YES, NO, NO), kFadeDurationMilliseconds);
    XCTAssertEqual(VibeIncomingFadeMilliseconds((NSInteger)kFadeDurationMilliseconds, YES, NO, NO),
                   kFadeDurationMilliseconds);
}

// Whatever the length resolves to, it must select a curve that terminates on
// the target — the two headers are used together and their agreement is the
// property that matters.
- (void)testEveryResolvedLengthLandsOnSilence {
    const NSInteger settings[] = { 0, 10, 500, 2000 };
    const BOOL flags[] = { NO, YES };
    for (size_t s = 0; s < sizeof(settings) / sizeof(settings[0]); s++) {
        for (size_t a = 0; a < 2; a++) {
            for (size_t d = 0; d < 2; d++) {
                for (size_t q = 0; q < 2; q++) {
                    uint64_t ms = VibeIncomingFadeMilliseconds(settings[s], flags[a],
                                                               flags[d], flags[q]);
                    int steps = VibeFadeStepsForMilliseconds(ms);
                    XCTAssertEqual(VibeFadeVolumeForFadeLength(ms, 1.0f, 0.0f, steps, steps), 0.0f);
                    XCTAssertGreaterThanOrEqual(ms, kFadeDurationMilliseconds);
                }
            }
        }
    }
}

@end
