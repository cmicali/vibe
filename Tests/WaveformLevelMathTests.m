//
//  WaveformLevelMathTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "WaveformLevelMath.h"

@interface WaveformLevelMathTests : XCTestCase
@end

@implementation WaveformLevelMathTests

// The mean square whose RMS sits at the given fraction of full scale.
static float MeanSquareAtFraction(float fraction) {
    float rms = fraction * kVibeWaveformFullScaleRMS;
    return rms * rms;
}

// 0 dB is the mapping every style drew before the setting existed: RMS
// against the full-scale reference, clamped at 1.
- (void)testZeroGainIsThePlainMapping {
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(0.5f), kVibeWaveformFullScaleRMS, 0), 0.5f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(0.1f), kVibeWaveformFullScaleRMS, 0), 0.1f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(1.0f), kVibeWaveformFullScaleRMS, 0), 1.0f, 1e-6f);
    XCTAssertEqual(VibeWaveformBarLevel(MeanSquareAtFraction(1.7f), kVibeWaveformFullScaleRMS, 0), 1.0f);
    XCTAssertEqual(VibeWaveformBarLevel(0, kVibeWaveformFullScaleRMS, 0), 0);
    XCTAssertEqual(VibeWaveformBarLevel(-1, kVibeWaveformFullScaleRMS, 0), 0);
}

// Up grows a bar into the ceiling, down shrinks it, and the clamp holds at
// every gain.
- (void)testGainScalesTheLevelAndClampsAtFullScale {
    float quiet = MeanSquareAtFraction(0.1f);
    XCTAssertGreaterThan(VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 6), VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 0));
    XCTAssertLessThan(VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, -6), VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 0));
    XCTAssertEqual(VibeWaveformBarLevel(MeanSquareAtFraction(0.5f), kVibeWaveformFullScaleRMS, 12), 1.0f);
    XCTAssertEqual(VibeWaveformBarLevel(MeanSquareAtFraction(1.0f), kVibeWaveformFullScaleRMS, 12), 1.0f);
    XCTAssertLessThanOrEqual(VibeWaveformBarLevel(MeanSquareAtFraction(4), kVibeWaveformFullScaleRMS, -12), 1.0f);
}

// The second half of the setting: the ratio between a loud bar and one 6 dB
// under it is 2 at 0 dB, wider with the gain down (expansion) and narrower
// with it up (compression) — measured below the clamp so only the curve
// speaks.
- (void)testGainDownExpandsAndGainUpCompressesTheRange {
    float loud = MeanSquareAtFraction(0.2f);
    float softer = MeanSquareAtFraction(0.1f);
    float plain = VibeWaveformBarLevel(loud, kVibeWaveformFullScaleRMS, 0) / VibeWaveformBarLevel(softer, kVibeWaveformFullScaleRMS, 0);
    float down = VibeWaveformBarLevel(loud, kVibeWaveformFullScaleRMS, -6) / VibeWaveformBarLevel(softer, kVibeWaveformFullScaleRMS, -6);
    float up = VibeWaveformBarLevel(loud, kVibeWaveformFullScaleRMS, 6) / VibeWaveformBarLevel(softer, kVibeWaveformFullScaleRMS, 6);
    XCTAssertEqualWithAccuracy(plain, 2.0f, 1e-5f);
    XCTAssertGreaterThan(down, plain);
    XCTAssertLessThan(up, plain);
    // 24 dB of gain doubles or halves the exponent, so at -24 the ratio of a
    // 6 dB step is 2^2 and at +24 it is 2^0.5 — probed 20 dB quieter there,
    // where +24 dB of gain still leaves both bars under the clamp.
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loud, kVibeWaveformFullScaleRMS, -24) / VibeWaveformBarLevel(softer, kVibeWaveformFullScaleRMS, -24), 4.0f, 1e-4f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(0.02f), kVibeWaveformFullScaleRMS, 24)
                               / VibeWaveformBarLevel(MeanSquareAtFraction(0.01f), kVibeWaveformFullScaleRMS, 24), sqrtf(2.0f), 1e-4f);
}

// Normalize hands the fill the track's loudest column as the reference: that
// column draws full height at 0 dB whatever its level, everything else in
// proportion, and the gain still applies over it — the bend included.
- (void)testANormalizedReferenceDrawsTheLoudestColumnFull {
    float loudest = MeanSquareAtFraction(2.0f);  // pegged against the fixed reference
    float reference = sqrtf(loudest);
    XCTAssertEqual(VibeWaveformBarLevel(loudest, kVibeWaveformFullScaleRMS, 0), 1.0f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loudest, reference, 0), 1.0f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(1.0f), reference, 0), 0.5f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loudest, reference, -6),
                               powf(powf(10, -6.0f / 20), exp2f(6.0f / 24)), 1e-5f);
    XCTAssertEqual(VibeWaveformBarLevel(loudest, reference, 6), 1.0f);
}

- (void)testLevelIsMonotonicInEnergyAtEveryGain {
    for (float gain = -12; gain <= 12; gain += 3) {
        float previous = 0;
        for (float fraction = 0.05f; fraction <= 2.0f; fraction += 0.05f) {
            float level = VibeWaveformBarLevel(MeanSquareAtFraction(fraction), kVibeWaveformFullScaleRMS, gain);
            XCTAssertGreaterThanOrEqual(level, previous, @"gain %g, fraction %g", gain, fraction);
            XCTAssertLessThanOrEqual(level, 1.0f);
            previous = level;
        }
    }
}

@end
