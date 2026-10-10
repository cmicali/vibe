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

- (void)testZeroGainIsThePlainMapping {
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(0.5f), kVibeWaveformFullScaleRMS, 0), 0.5f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(0.1f), kVibeWaveformFullScaleRMS, 0), 0.1f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(1.0f), kVibeWaveformFullScaleRMS, 0), 1.0f, 1e-6f);
    XCTAssertEqual(VibeWaveformBarLevel(MeanSquareAtFraction(1.7f), kVibeWaveformFullScaleRMS, 0), 1.0f);
    XCTAssertEqual(VibeWaveformBarLevel(0, kVibeWaveformFullScaleRMS, 0), 0);
    XCTAssertEqual(VibeWaveformBarLevel(-1, kVibeWaveformFullScaleRMS, 0), 0);
}

- (void)testGainScalesTheLevelAndClampsAtFullScale {
    float quiet = MeanSquareAtFraction(0.1f);
    XCTAssertGreaterThan(VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 6), VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 0));
    XCTAssertLessThan(VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, -6), VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 0));
    XCTAssertEqual(VibeWaveformBarLevel(MeanSquareAtFraction(0.5f), kVibeWaveformFullScaleRMS, 12), 1.0f);
    XCTAssertEqual(VibeWaveformBarLevel(MeanSquareAtFraction(1.0f), kVibeWaveformFullScaleRMS, 12), 1.0f);
    XCTAssertLessThanOrEqual(VibeWaveformBarLevel(MeanSquareAtFraction(4), kVibeWaveformFullScaleRMS, -12), 1.0f);
}

// A bar to one 6 dB under it is 2 at 0 dB, measured below the clamp so only
// the curve speaks.
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

// A quiet track's loudest column draws full height at 0 dB, with the gain
// still applied over normalization — the bend included.
- (void)testAQuietNormalizedReferenceDrawsTheLoudestColumnFull {
    float loudest = MeanSquareAtFraction(0.5f);
    float reference = sqrtf(loudest);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loudest, kVibeWaveformFullScaleRMS, 0), 0.5f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loudest, reference, 0), 1.0f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(MeanSquareAtFraction(0.25f), reference, 0), 0.5f, 1e-6f);
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

#pragma mark - Spectrum

static const float kPureRGB[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};

#define AssertRGB(rgb, r, g, b) do { \
    XCTAssertEqualWithAccuracy((rgb)[0], (r), 1e-5f); \
    XCTAssertEqualWithAccuracy((rgb)[1], (g), 1e-5f); \
    XCTAssertEqualWithAccuracy((rgb)[2], (b), 1e-5f); \
} while (0)

// A lone band is its primary, whatever its level.
- (void)testSpectrumLoneBandIsItsPrimary {
    float rgb[3];
    const float levels[] = {0.05f, 0.5f, 1.0f};
    for (size_t i = 0; i < sizeof(levels) / sizeof(levels[0]); i++) {
        float level = levels[i];
        VibeSpectrumColor((const float[]){level, 0, 0}, kPureRGB, rgb);
        AssertRGB(rgb, 1, 0, 0);
        VibeSpectrumColor((const float[]){0, 0, level}, kPureRGB, rgb);
        AssertRGB(rgb, 0, 0, 1);
    }
}

// Low and high alike make the additive sum, a purple no single tone makes,
// and a louder band leads by its energy.
- (void)testSpectrumMixesAdditivelyByEnergy {
    float rgb[3];
    VibeSpectrumColor((const float[]){0.6f, 0, 0.6f}, kPureRGB, rgb);
    AssertRGB(rgb, 1, 0, 1);
    VibeSpectrumColor((const float[]){1, 0, 0.5f}, kPureRGB, rgb);
    AssertRGB(rgb, 1, 0, 0.25f);
    VibeSpectrumColor((const float[]){-1, 0.5f, 0}, kPureRGB, rgb);
    AssertRGB(rgb, 0, 1, 0);
}

// Silence is the primaries' plain mean, a gray that reads on either
// background. A dim palette stays as dim as its primaries, so a light
// appearance's darker set keeps reading on white.
- (void)testSpectrumKeepsThePrimariesBrightness {
    float rgb[3];
    VibeSpectrumColor((const float[]){0, 0, 0}, kPureRGB, rgb);
    AssertRGB(rgb, 1.0f / 3, 1.0f / 3, 1.0f / 3);
    const float dim[3][3] = {{0.5f, 0, 0}, {0, 0.5f, 0}, {0, 0, 0.5f}};
    VibeSpectrumColor((const float[]){1, 0, 1}, dim, rgb);
    AssertRGB(rgb, 0.5f, 0, 0.5f);
}

@end
