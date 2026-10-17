//
//  WaveformLevelMathTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "WaveformLevelMath.h"

@interface WaveformLevelMathTests : XCTestCase
@end

@implementation WaveformLevelMathTests

// The RMS at the given fraction of full scale.
static float RMSAtFraction(float fraction) {
    return fraction * kVibeWaveformFullScaleRMS;
}

- (void)testZeroGainIsThePlainMapping {
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(RMSAtFraction(0.5f), kVibeWaveformFullScaleRMS, 0), 0.5f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(RMSAtFraction(0.1f), kVibeWaveformFullScaleRMS, 0), 0.1f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(RMSAtFraction(1.0f), kVibeWaveformFullScaleRMS, 0), 1.0f, 1e-6f);
    XCTAssertEqual(VibeWaveformBarLevel(RMSAtFraction(1.7f), kVibeWaveformFullScaleRMS, 0), 1.0f);
    XCTAssertEqual(VibeWaveformBarLevel(0, kVibeWaveformFullScaleRMS, 0), 0);
    XCTAssertEqual(VibeWaveformBarLevel(-1, kVibeWaveformFullScaleRMS, 0), 0);
}

- (void)testGainScalesTheLevelAndClampsAtFullScale {
    float quiet = RMSAtFraction(0.1f);
    XCTAssertGreaterThan(VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 6), VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 0));
    XCTAssertLessThan(VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, -6), VibeWaveformBarLevel(quiet, kVibeWaveformFullScaleRMS, 0));
    XCTAssertEqual(VibeWaveformBarLevel(RMSAtFraction(0.5f), kVibeWaveformFullScaleRMS, 12), 1.0f);
    XCTAssertEqual(VibeWaveformBarLevel(RMSAtFraction(1.0f), kVibeWaveformFullScaleRMS, 12), 1.0f);
    XCTAssertLessThanOrEqual(VibeWaveformBarLevel(RMSAtFraction(4), kVibeWaveformFullScaleRMS, -12), 1.0f);
}

// A bar to one 6 dB under it is 2 at 0 dB, measured below the clamp so only
// the curve speaks.
- (void)testGainDownExpandsAndGainUpCompressesTheRange {
    float loud = RMSAtFraction(0.2f);
    float softer = RMSAtFraction(0.1f);
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
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(RMSAtFraction(0.02f), kVibeWaveformFullScaleRMS, 24)
                               / VibeWaveformBarLevel(RMSAtFraction(0.01f), kVibeWaveformFullScaleRMS, 24), sqrtf(2.0f), 1e-4f);
}

// A quiet track's loudest column draws full height at 0 dB, with the gain
// still applied over normalization — the bend included.
- (void)testAQuietNormalizedReferenceDrawsTheLoudestColumnFull {
    float loudest = RMSAtFraction(0.5f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loudest, kVibeWaveformFullScaleRMS, 0), 0.5f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loudest, loudest, 0), 1.0f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(RMSAtFraction(0.25f), loudest, 0), 0.5f, 1e-6f);
    XCTAssertEqualWithAccuracy(VibeWaveformBarLevel(loudest, loudest, -6),
                               powf(powf(10, -6.0f / 20), exp2f(6.0f / 24)), 1e-5f);
    XCTAssertEqual(VibeWaveformBarLevel(loudest, loudest, 6), 1.0f);
}

- (void)testLevelIsMonotonicInEnergyAtEveryGain {
    for (float gain = -12; gain <= 12; gain += 3) {
        float previous = 0;
        for (float fraction = 0.05f; fraction <= 2.0f; fraction += 0.05f) {
            float level = VibeWaveformBarLevel(RMSAtFraction(fraction), kVibeWaveformFullScaleRMS, gain);
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

- (void)testSpectrumMixesAdditivelyByEnergy {
    float rgb[3];
    VibeSpectrumColor((const float[]){0.6f, 0, 0.6f}, kPureRGB, rgb);
    AssertRGB(rgb, 1, 0, 1);
    VibeSpectrumColor((const float[]){1, 0, 0.5f}, kPureRGB, rgb);
    AssertRGB(rgb, 1, 0, 0.0625f);
    VibeSpectrumColor((const float[]){4, 0, 2}, kPureRGB, rgb);
    AssertRGB(rgb, 1, 0, 0.0625f);
    VibeSpectrumColor((const float[]){-1, 0.5f, 0}, kPureRGB, rgb);
    AssertRGB(rgb, 0, 1, 0);
}

#pragma mark - Sections

static const float kNoShares[3] = {1, 1, 1};

static void SetColumn(float *meanSquares, NSUInteger j, float low, float mid, float high) {
    meanSquares[j * 3] = low;
    meanSquares[j * 3 + 1] = mid;
    meanSquares[j * 3 + 2] = high;
}

- (void)testSectionsSplitWhereTheMixChanges {
    float columns[kVibeWaveformSectionColumns * 3];
    for (NSUInteger j = 0; j < kVibeWaveformSectionColumns; j++) {
        // A light shimmer on each side, so neither side is uniform already.
        float shimmer = j % 2 ? 0.05f : 0;
        if (j < 200) {
            SetColumn(columns, j, 1, 0, shimmer);
        } else {
            SetColumn(columns, j, shimmer, 0, 1);
        }
    }
    NSUInteger starts[kVibeWaveformSectionColumns];
    XCTAssertEqual(VibeWaveformSectionStarts(columns, kVibeWaveformSectionColumns, kNoShares, starts), 2u);
    XCTAssertEqual(starts[0], 0u);
    XCTAssertEqual(starts[1], 200u);
}

// Kick and hats alternating every column cost the same split or not, so a
// section never follows the beat.
- (void)testSectionsDoNotFollowTheBeat {
    float columns[kVibeWaveformSectionColumns * 3];
    for (NSUInteger j = 0; j < kVibeWaveformSectionColumns; j++) {
        SetColumn(columns, j, j % 2 ? 0 : 1, 0, j % 2 ? 1 : 0);
    }
    NSUInteger starts[kVibeWaveformSectionColumns];
    XCTAssertEqual(VibeWaveformSectionStarts(columns, kVibeWaveformSectionColumns, kNoShares, starts), 1u);
}

// A fill of two columns cannot pay for a section of the minimum length, so it
// joins its neighbors. Silence joins whatever surrounds it.
- (void)testSectionsOutlastAFillAndSilence {
    float columns[kVibeWaveformSectionColumns * 3];
    for (NSUInteger j = 0; j < kVibeWaveformSectionColumns; j++) {
        BOOL blip = j >= 100 && j < 102;
        BOOL silent = j >= 300 && j < 340;
        SetColumn(columns, j, silent || blip ? 0 : 1, blip ? 1 : 0, 0);
    }
    NSUInteger starts[kVibeWaveformSectionColumns];
    XCTAssertEqual(VibeWaveformSectionStarts(columns, kVibeWaveformSectionColumns, kNoShares, starts), 1u);
}

// The mix weighs each band against its share, as the colors do.
- (void)testSectionsWeighTheBandsByTheirShares {
    float columns[kVibeWaveformSectionColumns * 3];
    for (NSUInteger j = 0; j < kVibeWaveformSectionColumns; j++) {
        SetColumn(columns, j, 1, 0, j < 256 ? 0 : 0.1f);
    }
    NSUInteger starts[kVibeWaveformSectionColumns];
    XCTAssertEqual(VibeWaveformSectionStarts(columns, kVibeWaveformSectionColumns, kNoShares, starts), 1u,
                   @"highs at a tenth of the lows' energy barely move the mix");
    const float halfHighs[3] = {1, 1, 0.5f};
    XCTAssertEqual(VibeWaveformSectionStarts(columns, kVibeWaveformSectionColumns, halfHighs, starts), 2u,
                   @"at half the share the highs count four times over");
    XCTAssertEqual(starts[1], 256u);
}

// Quiet hats, then a kick every fourth cell over them: the split is the
// first kick, though most cells after it are as quiet as the hats.
- (void)testSplitLandsOnTheFirstHitBackIn {
    float levels[200 * 3];
    for (NSUInteger i = 0; i < 200; i++) {
        BOOL kick = i >= 77 && (i - 77) % 4 == 0;
        levels[i * 3] = kick ? 1 : 0.02f;
        levels[i * 3 + 1] = 0.05f;
        levels[i * 3 + 2] = 0.1f;
    }
    XCTAssertEqual(VibeWaveformSectionSplit(levels, 200), 77u);
    XCTAssertEqual(VibeWaveformSectionSplit(levels, 1), 0u);
}

// Spectrum's peak shape is absent at rest zoom, whole at deep zoom, and
// halfway an octave in.
- (void)testSpectrumPeakShapeFadesInAsColumnsNarrow {
    XCTAssertEqual(VibeSpectrumPeakShapeWeight(0.5), 0);
    XCTAssertEqual(VibeSpectrumPeakShapeWeight(0.02), 0);
    XCTAssertEqualWithAccuracy(VibeSpectrumPeakShapeWeight(0.01), 0.5, 1e-9);
    XCTAssertEqual(VibeSpectrumPeakShapeWeight(0.005), 1);
    XCTAssertEqual(VibeSpectrumPeakShapeWeight(0.001), 1);
    XCTAssertEqual(VibeSpectrumPeakShapeWeight(0), 0, @"no column, no shape");
}

// Half a second a column until a track would need more than the grid holds.
- (void)testSectionColumnsAreHalfASecondUntilTheGridFills {
    double rate = 44100;
    XCTAssertEqual(VibeWaveformSectionFramesPerColumn(60 * rate, rate), 0.5 * rate);
    XCTAssertEqual(VibeWaveformSectionFramesPerColumn(256 * rate, rate), 0.5 * rate);
    XCTAssertEqual(VibeWaveformSectionFramesPerColumn(3600 * rate, rate), 3600 * rate / (double)kVibeWaveformSectionColumns);
}

- (void)testSpectrumKeepsThePrimariesBrightness {
    float rgb[3];
    VibeSpectrumColor((const float[]){0, 0, 0}, kPureRGB, rgb);
    AssertRGB(rgb, 1.0f / 3, 1.0f / 3, 1.0f / 3);
    const float dim[3][3] = {{0.5f, 0, 0}, {0, 0.5f, 0}, {0, 0, 0.5f}};
    VibeSpectrumColor((const float[]){1, 0, 1}, dim, rgb);
    AssertRGB(rgb, 0.5f, 0, 0.5f);
}

@end
