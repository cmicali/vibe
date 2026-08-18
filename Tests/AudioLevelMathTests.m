//
//  AudioLevelMathTests.m
//  VibeTests
//
//  The tunable half of the reactive equalizer indicator. AudioLevelTap owns an
//  AVAudioEngine tap and cannot be reached from a host-less suite, so these
//  are the decisions that actually shape how the bars look.
//

#import <XCTest/XCTest.h>

#import "AudioLevelMath.h"

@interface AudioLevelMathTests : XCTestCase
@end

@implementation AudioLevelMathTests

#pragma mark - Band bin ranges

// Contiguous, not merely ascending: a band's top IS its neighbour's bottom, so
// no bin drives two bars and none drives none.
- (void)testBandsAreContiguous {
    NSUInteger previousHigh = 0;
    for (NSUInteger b = 0; b < kLevelBandCount; b++) {
        NSUInteger lo = 0, hi = 0;
        VibeLevelBandBinRange(b, 1024, 44100.0, &lo, &hi);
        XCTAssertLessThan(lo, hi, @"band %lu must span at least one bin", (unsigned long)b);
        if (b > 0) {
            XCTAssertEqual(lo, previousHigh, @"band %lu must start where %lu ended",
                           (unsigned long)b, (unsigned long)(b - 1));
        }
        previousHigh = hi;
    }
}

// Bin 0 packs DC and Nyquist in a real FFT, and neither belongs to a band.
- (void)testLowestBandSkipsTheDCBin {
    NSUInteger lo = 0, hi = 0;
    VibeLevelBandBinRange(0, 1024, 44100.0, &lo, &hi);
    XCTAssertGreaterThanOrEqual(lo, 1u);
}

- (void)testTopBandStopsAtNyquist {
    NSUInteger lo = 0, hi = 0;
    VibeLevelBandBinRange(kLevelBandCount - 1, 1024, 48000.0, &lo, &hi);
    XCTAssertLessThanOrEqual(hi, 1024u / 2);
}

// Log spacing: each band must be wider in bins than the one below it, which is
// the whole reason the treble bars are not dead.
- (void)testBandsWidenGeometrically {
    NSUInteger previousWidth = 0;
    for (NSUInteger b = 0; b < kLevelBandCount; b++) {
        NSUInteger lo = 0, hi = 0;
        VibeLevelBandBinRange(b, 2048, 48000.0, &lo, &hi);
        NSUInteger width = hi - lo;
        if (b > 0) {
            XCTAssertGreaterThan(width, previousWidth,
                                 @"band %lu should be wider than its predecessor",
                                 (unsigned long)b);
        }
        previousWidth = width;
    }
}

// The edges are bound from the delivered format, so a rate change must move
// them — a constant here would put the bands in the wrong places silently.
- (void)testBandEdgesFollowSampleRate {
    NSUInteger lo44 = 0, hi44 = 0, lo96 = 0, hi96 = 0;
    VibeLevelBandBinRange(0, 1024, 44100.0, &lo44, &hi44);
    VibeLevelBandBinRange(0, 1024, 96000.0, &lo96, &hi96);
    XCTAssertNotEqual(hi44, hi96);
}

- (void)testDegenerateFormatsStillProduceAUsableRange {
    NSUInteger lo = 0, hi = 0;
    VibeLevelBandBinRange(0, 1024, 0.0, &lo, &hi);
    XCTAssertLessThan(lo, hi);

    VibeLevelBandBinRange(kLevelBandCount - 1, 64, 8000.0, &lo, &hi);
    XCTAssertLessThan(lo, hi);
    XCTAssertLessThanOrEqual(hi, 64u / 2);
}

#pragma mark - Normalization

- (void)testEnergyAtTheReferenceIsFullScale {
    XCTAssertEqualWithAccuracy(VibeLevelNormalize(0.25f, 0.25f), 1.0f, 0.0001);
}

- (void)testEnergyBelowTheWindowFloorsAtZero {
    // Two full dynamic ranges down is well past the floor.
    float reference = 1.0f;
    float energy = reference * powf(10.0f, -2.0f * kLevelDynamicRangeDB / 10.0f);
    XCTAssertEqual(VibeLevelNormalize(energy, reference), 0.0f);
}

- (void)testHalfTheWindowIsHalfTheLevel {
    float reference = 1.0f;
    float energy = reference * powf(10.0f, -(kLevelDynamicRangeDB / 2.0f) / 10.0f);
    XCTAssertEqualWithAccuracy(VibeLevelNormalize(energy, reference), 0.5f, 0.001);
}

- (void)testNormalizeIsClampedAndFiniteForHostileInput {
    XCTAssertEqual(VibeLevelNormalize(0.0f, 1.0f), 0.0f);
    XCTAssertEqual(VibeLevelNormalize(-1.0f, 1.0f), 0.0f);
    XCTAssertEqual(VibeLevelNormalize(NAN, 1.0f), 0.0f);
    // Inf is a corrupt decode, not a loud passage: it reads as nothing to show
    // rather than as a bar pinned to full height.
    XCTAssertEqual(VibeLevelNormalize(INFINITY, 1.0f), 0.0f);
    // A reference that never got a real value must not amplify silence.
    XCTAssertEqual(VibeLevelNormalize(1e-12f, NAN), 0.0f);
    // Louder than the reference is clamped, never over-driven.
    XCTAssertEqual(VibeLevelNormalize(100.0f, 1.0f), 1.0f);
}

#pragma mark - The automatic gain reference

- (void)testLouderEnergyBecomesTheReferenceImmediately {
    XCTAssertEqualWithAccuracy(VibeLevelUpdateReference(0.1f, 0.8f, 0.02f), 0.8f, 0.0001);
}

- (void)testQuieterEnergyOnlyDecaysTheReference {
    float reference = VibeLevelUpdateReference(1.0f, 0.0f, 0.02f);
    XCTAssertLessThan(reference, 1.0f);
    // A single hop must not throw the reference away, or every gap between
    // hits would re-normalize and the bars would pump.
    XCTAssertGreaterThan(reference, 0.9f);
}

- (void)testReferenceDecayIsMonotonicAndReachesTheFloor {
    float reference = 1.0f;
    float previous = reference;
    for (int i = 0; i < 2000; i++) {
        reference = VibeLevelUpdateReference(reference, 0.0f, 0.02f);
        XCTAssertLessThanOrEqual(reference, previous);
        previous = reference;
    }
    XCTAssertEqualWithAccuracy(reference, kLevelReferenceFloor, kLevelReferenceFloor * 0.01f);
}

// The floor is what keeps true silence flat instead of amplifying the noise
// floor into a light show.
- (void)testReferenceNeverFallsBelowTheFloor {
    float reference = kLevelReferenceFloor;
    for (int i = 0; i < 100; i++) {
        reference = VibeLevelUpdateReference(reference, 0.0f, 1.0f);
    }
    XCTAssertGreaterThanOrEqual(reference, kLevelReferenceFloor);
    XCTAssertEqual(VibeLevelNormalize(0.0f, reference), 0.0f);
}

// A band carrying nothing but a noise floor must stay DARK. This is the whole
// job of the absolute floor, and the case that motivates its value: the AGC
// divides each band by its own running reference, so without a floor above the
// noise a signal-free band normalizes its own hiss to full scale and the
// emptiest bar reads the brightest. Measured on a pure 220 Hz tone, bands 3 and
// 4 averaged 0.98 before the floor was raised.
- (void)testSignalFreeBandStaysDarkAcrossItsWholeDecay {
    // 16-bit quantization noise, in the unnormalized units the tap works in.
    const float noise = 3.3e-7f;
    float reference = 1.0f;   // the band was loud once, so the floor is reached by decay
    for (int i = 0; i < 4000; i++) {
        reference = VibeLevelUpdateReference(reference, noise, 0.02f);
        XCTAssertEqual(VibeLevelNormalize(noise, reference), 0.0f);
    }
    XCTAssertEqualWithAccuracy(reference, kLevelReferenceFloor, kLevelReferenceFloor * 0.01f);
}

// The converse, and the reason the floor cannot simply be raised without bound:
// the AGC exists so a QUIET track still moves its bars. A band carrying real
// signal reaches full scale on its own peaks at any level, however far down —
// right up to the point its energy crosses the absolute floor.
- (void)testQuietBandStillReachesFullScale {
    // 6.6e3 is a full-scale tone's measured mean band energy; -40 dB from there
    // is 0.66, still well clear of the floor.
    for (float gainDB = 0.0f; gainDB >= -40.0f; gainDB -= 10.0f) {
        float energy = 6.6e3f * powf(10.0f, gainDB / 10.0f);
        float reference = VibeLevelUpdateReference(kLevelReferenceFloor, energy, 0.02f);
        XCTAssertEqualWithAccuracy(VibeLevelNormalize(energy, reference), 1.0f, 0.0001,
                                   @"%.0f dB band should still reach full scale", gainDB);
    }
}

// Below the floor the bar rolls off rather than cutting out, which is what
// makes a fade-out fall smoothly instead of snapping dark at a threshold.
- (void)testBelowTheFloorTheLevelRollsOffRatherThanCutting {
    float previous = 1.0f;
    for (float scale = 1.0f; scale >= 1e-4f; scale *= 0.5f) {
        float energy = kLevelReferenceFloor * scale;
        float level = VibeLevelNormalize(energy, kLevelReferenceFloor);
        XCTAssertLessThanOrEqual(level, previous);
        previous = level;
    }
    XCTAssertEqual(previous, 0.0f);
}

- (void)testReferenceSanitizesHostileInput {
    XCTAssertGreaterThanOrEqual(VibeLevelUpdateReference(NAN, 0.0f, 0.02f), kLevelReferenceFloor);
    XCTAssertGreaterThanOrEqual(VibeLevelUpdateReference(1.0f, NAN, 0.02f), kLevelReferenceFloor);
    XCTAssertEqualWithAccuracy(VibeLevelUpdateReference(1.0f, 0.0f, NAN), 1.0f, 0.0001);
    XCTAssertEqualWithAccuracy(VibeLevelUpdateReference(1.0f, 0.0f, 0.0f), 1.0f, 0.0001);
}

#pragma mark - The envelope

// The asymmetry is the point: a transient arrives at once and leaves slowly.
- (void)testAttackIsFasterThanRelease {
    float dt = 1.0f / 60.0f;
    float rise = VibeLevelEnvelope(0.0f, 1.0f, dt, kLevelAttackSeconds, kLevelReleaseSeconds);
    float fall = 1.0f - VibeLevelEnvelope(1.0f, 0.0f, dt, kLevelAttackSeconds, kLevelReleaseSeconds);
    XCTAssertGreaterThan(rise, fall);
}

- (void)testEnvelopeConvergesOnItsTarget {
    float value = 0.0f;
    for (int i = 0; i < 600; i++) {
        value = VibeLevelEnvelope(value, 0.75f, 1.0f / 60.0f,
                                  kLevelAttackSeconds, kLevelReleaseSeconds);
    }
    XCTAssertEqualWithAccuracy(value, 0.75f, 0.001);
}

- (void)testEnvelopeNeverOvershoots {
    float value = 0.0f;
    for (int i = 0; i < 300; i++) {
        value = VibeLevelEnvelope(value, 1.0f, 1.0f / 60.0f,
                                  kLevelAttackSeconds, kLevelReleaseSeconds);
        XCTAssertLessThanOrEqual(value, 1.0f);
        XCTAssertGreaterThanOrEqual(value, 0.0f);
    }
}

// Time-constant based, so the same wall-clock span lands in the same place
// whatever the display rate — a 60 Hz phone and a 120 Hz one must agree.
- (void)testEnvelopeIsFrameRateIndependent {
    float slow = VibeLevelEnvelope(0.0f, 1.0f, 1.0f / 60.0f,
                                   kLevelAttackSeconds, kLevelReleaseSeconds);
    float fast = 0.0f;
    for (int i = 0; i < 2; i++) {
        fast = VibeLevelEnvelope(fast, 1.0f, 1.0f / 120.0f,
                                 kLevelAttackSeconds, kLevelReleaseSeconds);
    }
    XCTAssertEqualWithAccuracy(slow, fast, 0.005);
}

- (void)testEnvelopeSanitizesHostileInput {
    XCTAssertGreaterThan(VibeLevelEnvelope(NAN, 0.5f, 1.0f / 60.0f,
                                           kLevelAttackSeconds, kLevelReleaseSeconds), 0.0f);
    // A NaN target is sanitized to 0 and then EASED toward, not snapped to:
    // one corrupt frame must not drop the bar to the floor.
    float decayed = VibeLevelEnvelope(0.5f, NAN, 1.0f / 60.0f,
                                      kLevelAttackSeconds, kLevelReleaseSeconds);
    XCTAssertGreaterThanOrEqual(decayed, 0.0f);
    XCTAssertLessThan(decayed, 0.5f);
    // A zero or negative frame time snaps rather than dividing by zero.
    XCTAssertEqual(VibeLevelEnvelope(0.0f, 0.5f, 0.0f,
                                     kLevelAttackSeconds, kLevelReleaseSeconds), 0.5f);
}

@end
