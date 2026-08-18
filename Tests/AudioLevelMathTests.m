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

- (void)testBassForwardNominalEdgesAreExplicit {
    const double expected[] = {40.0, 100.0, 250.0, 800.0, 4000.0, 20000.0};
    for (NSUInteger edge = 0; edge <= kLevelBandCount; edge++) {
        XCTAssertEqual(kLevelBandEdgesHz[edge], expected[edge]);
        XCTAssertEqual(VibeLevelBandEdgeHz(edge, 48000.0), expected[edge]);
    }
}

- (void)testSharedSpectrumIsTheShippingDefault {
    XCTAssertEqual(kLevelDefaultNormalizationMode,
                   VibeAudioLevelNormalizationModeSharedSpectrum);
}

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

// A half-open band starts at the first bin center on or above its lower edge.
// These exact grids cover every output-rate family the analyzer supports.
- (void)testBandEdgesUseExactBinCenterMembershipAtEveryHardwareRate {
    const double rates[] = {44100.0, 48000.0, 88200.0, 96000.0,
                            176400.0, 192000.0};
    const NSUInteger expected[][kLevelBandCount + 1] = {
        {2, 5, 12, 38, 186, 929},
        {2, 5, 11, 35, 171, 854},
        {2, 5, 12, 38, 186, 929},
        {2, 5, 11, 35, 171, 854},
        {2, 5, 12, 38, 186, 929},
        {2, 5, 11, 35, 171, 854},
    };
    for (NSUInteger rateIndex = 0;
         rateIndex < sizeof(rates) / sizeof(rates[0]); rateIndex++) {
        double rate = rates[rateIndex];
        NSUInteger fftSize = VibeLevelFFTSizeForSampleRate(rate);
        double binWidth = rate / (double)fftSize;
        for (NSUInteger edge = 0; edge <= kLevelBandCount; edge++) {
            NSUInteger bin = VibeLevelBandEdgeBin(edge, fftSize, rate);
            double edgeHz = VibeLevelBandEdgeHz(edge, rate);
            XCTAssertEqual(bin, expected[rateIndex][edge],
                           @"rate %.0f edge %lu", rate, (unsigned long)edge);
            XCTAssertGreaterThanOrEqual((double)bin * binWidth, edgeHz);
            XCTAssertLessThan((double)(bin - 1) * binWidth, edgeHz);
        }
    }
}

- (void)testLowestBandExcludesCentersBelowFortyHertz {
    for (NSNumber *rateValue in @[@44100.0, @48000.0, @88200.0, @96000.0,
                                  @176400.0, @192000.0]) {
        double rate = rateValue.doubleValue;
        NSUInteger fftSize = VibeLevelFFTSizeForSampleRate(rate);
        NSUInteger lo = 0, hi = 0;
        VibeLevelBandBinRange(0, fftSize, rate, &lo, &hi);
        XCTAssertGreaterThanOrEqual((double)lo * rate / (double)fftSize,
                                    kLevelBandEdgesHz[0]);
        XCTAssertLessThan((double)(lo - 1) * rate / (double)fftSize,
                          kLevelBandEdgesHz[0]);
    }
}

- (void)testTopBandIncludesEveryCenterBelowTheAudibleCeiling {
    for (NSNumber *rateValue in @[@44100.0, @48000.0, @88200.0, @96000.0,
                                  @176400.0, @192000.0]) {
        double rate = rateValue.doubleValue;
        NSUInteger fftSize = VibeLevelFFTSizeForSampleRate(rate);
        NSUInteger lo = 0, hi = 0;
        VibeLevelBandBinRange(kLevelBandCount - 1, fftSize, rate, &lo, &hi);
        XCTAssertLessThan((double)(hi - 1) * rate / (double)fftSize,
                          kLevelBandEdgesHz[kLevelBandCount]);
        XCTAssertGreaterThanOrEqual((double)hi * rate / (double)fftSize,
                                    kLevelBandEdgesHz[kLevelBandCount]);
        XCTAssertLessThan(hi, fftSize / 2);
    }
}

// The chosen regions grow in linear bandwidth while reserving three bars for
// everything below 800 Hz.
- (void)testBassForwardBandsWidenInBinCount {
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

- (void)testSharedSpectrumScaleExpressesEveryBandAsEnergyPerOctave {
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        double octaveWidth = log2(kLevelBandEdgesHz[band + 1]
                                  / kLevelBandEdgesHz[band]);
        float scale = VibeLevelEnergyPerOctaveScale(band, 48000.0);
        XCTAssertEqualWithAccuracy(octaveWidth * scale, 1.0, 0.000001,
                                   @"band %lu", (unsigned long)band);
    }
    XCTAssertEqualWithAccuracy(VibeLevelEnergyPerOctaveScale(0, 48000.0),
                               VibeLevelEnergyPerOctaveScale(1, 48000.0),
                               0.000001);
    XCTAssertEqualWithAccuracy(VibeLevelEnergyPerOctaveScale(3, 48000.0),
                               VibeLevelEnergyPerOctaveScale(4, 48000.0),
                               0.000001);
    XCTAssertGreaterThan(VibeLevelEnergyPerOctaveScale(0, 48000.0),
                         VibeLevelEnergyPerOctaveScale(4, 48000.0));
    XCTAssertEqual(VibeLevelEnergyPerOctaveScale(kLevelBandCount, 48000.0),
                   0.0f);
}

// The edges are bound from the delivered format, so a rate change must move
// them — a constant here would put the bands in the wrong places silently.
- (void)testBandBinRangesFollowSampleRate {
    NSUInteger lo44 = 0, hi44 = 0, lo96 = 0, hi96 = 0;
    VibeLevelBandBinRange(0, 1024, 44100.0, &lo44, &hi44);
    VibeLevelBandBinRange(0, 1024, 96000.0, &lo96, &hi96);
    XCTAssertNotEqual(hi44, hi96);
}

- (void)testAudibleBandEdgesDoNotStretchAtHighSampleRates {
    for (NSUInteger edge = 0; edge <= kLevelBandCount; edge++) {
        XCTAssertEqualWithAccuracy(VibeLevelBandEdgeHz(edge, 48000.0),
                                   VibeLevelBandEdgeHz(edge, 192000.0), 0.001);
    }
}

#pragma mark - Analysis cadence and energy

- (void)testFFTWindowDurationIsStableAcrossHardwareRates {
    for (NSNumber *rateValue in @[@44100.0, @48000.0, @88200.0, @96000.0,
                                  @176400.0, @192000.0]) {
        double rate = rateValue.doubleValue;
        double duration = (double)VibeLevelFFTSizeForSampleRate(rate) / rate;
        XCTAssertGreaterThan(duration, 0.040);
        XCTAssertLessThan(duration, 0.047);
    }
}

- (void)testTapRequestsTheMinimumDocumentedDuration {
    XCTAssertEqual(VibeLevelTapBufferFrameCount(44100.0), 4410u);
    XCTAssertEqual(VibeLevelTapBufferFrameCount(48000.0), 4800u);
    XCTAssertEqual(VibeLevelTapBufferFrameCount(192000.0), 19200u);
}

- (void)testFFTEnergyScalingIsFrameSizeIndependent {
    // Equivalent FFTs have raw squared magnitude proportional to N^2.
    float at2048 = VibeLevelScaleFFTEnergy(2048.0f * 2048.0f, 2048);
    float at8192 = VibeLevelScaleFFTEnergy(8192.0f * 8192.0f, 8192);
    XCTAssertEqualWithAccuracy(at2048, at8192, 0.0001);
}

- (void)testChannelEnergyCombinationPreservesAntiphaseStereo {
    // Magnitude-squared spectra for +x and -x are identical. Averaging those
    // spectra must preserve the tone rather than downmixing it to zero.
    float antiphaseEnergy[] = {0.25f, 0.25f};
    XCTAssertEqualWithAccuracy(VibeLevelMeanChannelEnergy(antiphaseEnergy, 2),
                               0.25f, 0.0001);
}

- (void)testChannelEnergyCombinationSanitizesCorruptInputs {
    float energies[] = {NAN, INFINITY};
    XCTAssertEqual(VibeLevelMeanChannelEnergy(energies, 2), 0.0f);
    XCTAssertEqual(VibeLevelScaleFFTEnergy(NAN, 2048), 0.0f);
    XCTAssertEqual(VibeLevelScaleFFTEnergy(INFINITY, 2048), 0.0f);
    XCTAssertEqual(VibeLevelScaleFFTEnergy(1.0f, 0), 0.0f);
}

- (void)testDegenerateZeroRateStillProducesAUsableRange {
    NSUInteger lo = 0, hi = 0;
    VibeLevelBandBinRange(0, 1024, 0.0, &lo, &hi);
    XCTAssertLessThan(lo, hi);
}

- (void)testLowSampleRatesKeepEveryBandContiguousAndScaled {
    for (NSNumber *rateValue in @[@8000.0, @16000.0, @22050.0,
                                  @32000.0, @40000.0]) {
        double sampleRate = rateValue.doubleValue;
        NSUInteger fftSize = VibeLevelFFTSizeForSampleRate(sampleRate);
        NSUInteger previousHigh = 0;
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            NSUInteger lo = 0, hi = 0;
            VibeLevelBandBinRange(band, fftSize, sampleRate, &lo, &hi);
            XCTAssertLessThan(lo, hi, @"Band %lu at %.0f Hz must not be empty",
                              (unsigned long)band, sampleRate);
            XCTAssertLessThanOrEqual(hi, fftSize / 2,
                                     @"Band %lu at %.0f Hz exceeds Nyquist",
                                     (unsigned long)band, sampleRate);
            if (band > 0) {
                XCTAssertEqual(lo, previousHigh,
                               @"Band %lu at %.0f Hz must meet its predecessor",
                               (unsigned long)band, sampleRate);
            }

            float scale = VibeLevelEnergyPerOctaveScale(band, sampleRate);
            XCTAssertTrue(isfinite(scale),
                          @"Band %lu at %.0f Hz needs a finite scale",
                          (unsigned long)band, sampleRate);
            XCTAssertGreaterThan(scale, 0.0f,
                                 @"Band %lu at %.0f Hz needs a positive scale",
                                 (unsigned long)band, sampleRate);
            previousHigh = hi;
        }
    }
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
// job of the absolute floor, and the case that motivates its value: in
// relative-activity mode, the AGC divides each band by its own running
// reference. Without a floor above the noise, a signal-free band normalizes
// its own hiss to full scale and the emptiest bar reads the brightest. Measured
// on a pure 220 Hz tone, bands 3 and 4 averaged 0.98 before the floor was raised.
- (void)testSignalFreeBandStaysDarkAcrossItsWholeDecay {
    // Approximate 16-bit quantization noise after FFT-size normalization.
    const float noise = 1e-10f;
    float reference = 1.0f;   // the band was loud once, so the floor is reached by decay
    for (int i = 0; i < 4000; i++) {
        reference = VibeLevelUpdateReference(reference, noise, 0.02f);
        XCTAssertEqual(VibeLevelNormalize(noise, reference), 0.0f);
    }
    XCTAssertEqualWithAccuracy(reference, kLevelReferenceFloor, kLevelReferenceFloor * 0.01f);
}

// The converse, and the reason the floor cannot simply be raised without bound:
// relative-activity mode relies on the per-band AGC so a QUIET track still
// moves its bars. A band carrying real signal reaches full scale on its own
// peaks at any level, however far down — right up to the point its energy
// crosses the absolute floor.
- (void)testQuietBandStillReachesFullScale {
    // A full-scale tone's mean depends on band width; 0.05 is representative.
    // Forty dB below it remains above the stable reference floor.
    for (float gainDB = 0.0f; gainDB >= -40.0f; gainDB -= 10.0f) {
        float energy = 0.05f * powf(10.0f, gainDB / 10.0f);
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

@end
