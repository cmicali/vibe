//
//  AudioLevelAnalyzerTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "AudioLevelAnalyzer.h"

static void VibeTestFillTone(float *samples, NSUInteger count, double sampleRate,
                             double frequency, float polarity) {
    for (NSUInteger frame = 0; frame < count; frame++) {
        samples[frame] = polarity * 0.5f
                * sinf((float)(2.0 * M_PI * frequency * (double)frame / sampleRate));
    }
}

static void VibeTestAddBinTone(float *samples, NSUInteger count, NSUInteger bin,
                               float amplitude) {
    for (NSUInteger frame = 0; frame < count; frame++) {
        samples[frame] += amplitude
                * sinf((float)(2.0 * M_PI * (double)bin * (double)frame
                               / (double)count));
    }
}

static NSUInteger VibeTestStrongestBand(const float levels[kLevelBandCount]) {
    NSUInteger strongest = 0;
    for (NSUInteger band = 1; band < kLevelBandCount; band++) {
        if (levels[band] > levels[strongest]) {
            strongest = band;
        }
    }
    return strongest;
}

@interface AudioLevelAnalyzerTests : XCTestCase
@end

@implementation AudioLevelAnalyzerTests

- (void)testExactBandCenterTonesRouteToEveryBarAtEveryHardwareRate {
    for (NSNumber *rateValue in @[@44100.0, @48000.0, @88200.0, @96000.0,
                                  @176400.0, @192000.0]) {
        double sampleRate = rateValue.doubleValue;
        for (NSUInteger expectedBand = 0; expectedBand < kLevelBandCount;
             expectedBand++) {
            VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
                    sampleRate, VibeAudioLevelNormalizationModeSharedSpectrum);
            XCTAssertNotEqual(analyzer, NULL);
            NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(analyzer);
            NSUInteger low = 0, high = 0;
            VibeLevelBandBinRange(expectedBand, frameCount, sampleRate, &low, &high);
            XCTAssertGreaterThanOrEqual(high - low, 3u);
            double centerHz = sqrt(VibeLevelBandEdgeHz(expectedBand, sampleRate)
                    * VibeLevelBandEdgeHz(expectedBand + 1, sampleRate));
            NSUInteger centerBin = (NSUInteger)llround(
                    centerHz * (double)frameCount / sampleRate);
            centerBin = MAX(low + 1, MIN(centerBin, high - 2));

            NSMutableData *samples = [NSMutableData
                    dataWithLength:frameCount * sizeof(float)];
            VibeTestAddBinTone(samples.mutableBytes, frameCount, centerBin, 0.5f);
            float *channels[] = {samples.mutableBytes};
            float levels[kLevelBandCount] = {0};
            XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                          frameCount, levels), 1u);
            XCTAssertEqual(VibeTestStrongestBand(levels), expectedBand,
                           @"rate %.0f band %lu", sampleRate,
                           (unsigned long)expectedBand);
            XCTAssertGreaterThan(levels[expectedBand], 0.99f);
            VibeAudioLevelAnalyzerDestroy(analyzer);
        }
    }
}

- (void)testFirstAndLastAudibleBinCentersRouteToTheOuterBars {
    for (NSNumber *rateValue in @[@44100.0, @48000.0, @88200.0, @96000.0,
                                  @176400.0, @192000.0]) {
        double sampleRate = rateValue.doubleValue;
        NSUInteger fftSize = VibeLevelFFTSizeForSampleRate(sampleRate);
        NSUInteger firstBin = 0, unused = 0;
        NSUInteger lastBandLow = 0, lastBandHigh = 0;
        VibeLevelBandBinRange(0, fftSize, sampleRate, &firstBin, &unused);
        VibeLevelBandBinRange(kLevelBandCount - 1, fftSize, sampleRate,
                              &lastBandLow, &lastBandHigh);
        const NSUInteger bins[] = {firstBin, lastBandHigh - 1};
        const NSUInteger expectedBands[] = {0, kLevelBandCount - 1};
        for (NSUInteger index = 0; index < sizeof(bins) / sizeof(bins[0]); index++) {
            VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
                    sampleRate, VibeAudioLevelNormalizationModeSharedSpectrum);
            NSMutableData *samples = [NSMutableData
                    dataWithLength:fftSize * sizeof(float)];
            VibeTestAddBinTone(samples.mutableBytes, fftSize, bins[index], 0.5f);
            float *channels[] = {samples.mutableBytes};
            float levels[kLevelBandCount];
            XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                          fftSize, levels), 1u);
            XCTAssertEqual(VibeTestStrongestBand(levels), expectedBands[index],
                           @"rate %.0f bin %lu", sampleRate,
                           (unsigned long)bins[index]);
            XCTAssertGreaterThan(levels[expectedBands[index]], 0.99f);
            VibeAudioLevelAnalyzerDestroy(analyzer);
        }
    }
}

- (void)testHannWindowedDCDoesNotReachEitherNormalizationMode {
    const VibeAudioLevelNormalizationMode modes[] = {
        VibeAudioLevelNormalizationModeRelativeActivity,
        VibeAudioLevelNormalizationModeSharedSpectrum,
    };
    for (NSNumber *rateValue in @[@44100.0, @48000.0, @88200.0, @96000.0,
                                  @176400.0, @192000.0]) {
        double sampleRate = rateValue.doubleValue;
        for (NSUInteger modeIndex = 0;
             modeIndex < sizeof(modes) / sizeof(modes[0]); modeIndex++) {
            VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
                    sampleRate, modes[modeIndex]);
            NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(analyzer);
            NSMutableData *samples = [NSMutableData
                    dataWithLength:frameCount * sizeof(float)];
            float *values = samples.mutableBytes;
            for (NSUInteger frame = 0; frame < frameCount; frame++) {
                values[frame] = 0.5f;
            }
            float *channels[] = {values};
            float levels[kLevelBandCount] = {0};
            XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                          frameCount, levels), 1u);
            for (NSUInteger band = 0; band < kLevelBandCount; band++) {
                XCTAssertEqual(levels[band], 0.0f,
                               @"rate %.0f mode %lu band %lu", sampleRate,
                               (unsigned long)modes[modeIndex], (unsigned long)band);
            }
            VibeAudioLevelAnalyzerDestroy(analyzer);
        }
    }
}

- (void)testNormalizationModesExposeRelativeActivityOrSharedSpectrum {
    const double sampleRate = 48000.0;
    VibeAudioLevelAnalyzer *relative = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeRelativeActivity);
    VibeAudioLevelAnalyzer *shared = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeSharedSpectrum);
    NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(relative);
    NSMutableData *samples = [NSMutableData dataWithLength:frameCount * sizeof(float)];
    float *values = samples.mutableBytes;
    // The first two bands have identical octave widths, isolating the modes'
    // private-versus-shared reference behavior from width compensation.
    VibeTestAddBinTone(values, frameCount, 3, 0.5f);
    VibeTestAddBinTone(values, frameCount, 7, 0.05f);
    float *channels[] = {values};
    float relativeLevels[kLevelBandCount] = {0};
    float sharedLevels[kLevelBandCount] = {0};

    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(relative, channels, 1,
                                                  frameCount, relativeLevels), 1u);
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(shared, channels, 1,
                                                  frameCount, sharedLevels), 1u);
    XCTAssertGreaterThan(relativeLevels[0], 0.99f);
    XCTAssertGreaterThan(relativeLevels[1], 0.99f);
    XCTAssertGreaterThan(sharedLevels[0], 0.99f);
    float twentyDBDown = 1.0f - 20.0f / kLevelDynamicRangeDB;
    XCTAssertEqualWithAccuracy(sharedLevels[1], twentyDBDown, 0.01f);
    XCTAssertGreaterThan(relativeLevels[1], sharedLevels[1] + 0.6f);

    VibeAudioLevelAnalyzerDestroy(relative);
    VibeAudioLevelAnalyzerDestroy(shared);
}

- (void)testSharedSpectrumPreservesRelativeEnergyAcrossSeparateWindowsInEitherOrder {
    const double sampleRate = 48000.0;
    for (NSNumber *weakTrebleFirstValue in @[@NO, @YES]) {
        BOOL weakTrebleFirst = weakTrebleFirstValue.boolValue;
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
                sampleRate, VibeAudioLevelNormalizationModeSharedSpectrum);
        NSUInteger window = VibeAudioLevelAnalyzerFFTSize(analyzer);
        NSMutableData *samples = [NSMutableData
                dataWithLength:window * 2 * sizeof(float)];
        float *values = samples.mutableBytes;
        float *bassWindow = values + (weakTrebleFirst ? window : 0);
        float *trebleWindow = values + (weakTrebleFirst ? 0 : window);
        VibeTestAddBinTone(bassWindow, window, 3, 0.5f);
        VibeTestAddBinTone(trebleWindow, window, 400, 0.05f);
        float *channels[] = {values};
        float levels[kLevelBandCount] = {0};

        XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                      window * 2, levels), 2u);
        XCTAssertGreaterThan(levels[0], 0.99f);
        float weakToStrong = 0.01f
                * VibeLevelEnergyPerOctaveScale(4, sampleRate)
                / VibeLevelEnergyPerOctaveScale(0, sampleRate);
        float expected = VibeLevelNormalize(weakToStrong, 1.0f);
        XCTAssertEqualWithAccuracy(levels[4], expected, 0.01f,
                                   @"weak-first %d", weakTrebleFirst);
        VibeAudioLevelAnalyzerDestroy(analyzer);
    }
}

- (void)testSharedSpectrumTimeAverageKeepsEqualPerOctaveEnergiesComparable {
    const double sampleRate = 48000.0;
    for (NSNumber *trebleFirstValue in @[@NO, @YES]) {
        BOOL trebleFirst = trebleFirstValue.boolValue;
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
                sampleRate, VibeAudioLevelNormalizationModeSharedSpectrum);
        NSUInteger window = VibeAudioLevelAnalyzerFFTSize(analyzer);
        NSMutableData *samples = [NSMutableData
                dataWithLength:window * 2 * sizeof(float)];
        float *values = samples.mutableBytes;
        float *bassWindow = values + (trebleFirst ? window : 0);
        float *trebleWindow = values + (trebleFirst ? 0 : window);
        VibeTestAddBinTone(bassWindow, window, 3, 0.5f);
        float trebleAmplitude = 0.5f * sqrtf(
                VibeLevelEnergyPerOctaveScale(0, sampleRate)
                / VibeLevelEnergyPerOctaveScale(4, sampleRate));
        VibeTestAddBinTone(trebleWindow, window, 400, trebleAmplitude);
        float *channels[] = {values};
        float levels[kLevelBandCount] = {0};

        XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                      window * 2, levels), 2u);
        // These bars summarize equal energy density over the whole callback;
        // they do not claim the two tones occupied the same FFT window.
        XCTAssertGreaterThan(levels[0], 0.99f);
        XCTAssertEqualWithAccuracy(levels[4], levels[0], 0.01f,
                                   @"treble-first %d", trebleFirst);
        VibeAudioLevelAnalyzerDestroy(analyzer);
    }
}

- (void)testSharedReferenceDecayCoversEveryWindowInTheCallback {
    const double sampleRate = 48000.0;
    VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeSharedSpectrum);
    NSUInteger window = VibeAudioLevelAnalyzerFFTSize(analyzer);
    NSMutableData *strong = [NSMutableData dataWithLength:window * sizeof(float)];
    VibeTestAddBinTone(strong.mutableBytes, window, 7, 0.5f);
    float *strongChannels[] = {strong.mutableBytes};
    float levels[kLevelBandCount];
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, strongChannels, 1,
                                                  window, levels), 1u);

    const NSUInteger quietWindowCount = 8;
    NSMutableData *quiet = [NSMutableData
            dataWithLength:window * quietWindowCount * sizeof(float)];
    float *quietValues = quiet.mutableBytes;
    for (NSUInteger index = 0; index < quietWindowCount; index++) {
        VibeTestAddBinTone(quietValues + index * window, window, 7, 0.05f);
    }
    float *quietChannels[] = {quietValues};
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(
            analyzer, quietChannels, 1, window * quietWindowCount, levels),
            quietWindowCount);

    float elapsed = (float)((double)(window * quietWindowCount) / sampleRate);
    float decayedReferenceRatio = expf(-elapsed / kLevelReferenceDecaySeconds);
    float expected = VibeLevelNormalize(0.01f, decayedReferenceRatio);
    XCTAssertEqualWithAccuracy(levels[1], expected, 0.01f);
    VibeAudioLevelAnalyzerDestroy(analyzer);
}

- (void)testConsumeOverwritesOneCallbackResultAndLeavesZeroWindowOutputUntouched {
    const VibeAudioLevelNormalizationMode modes[] = {
        VibeAudioLevelNormalizationModeRelativeActivity,
        VibeAudioLevelNormalizationModeSharedSpectrum,
    };
    for (NSUInteger modeIndex = 0;
         modeIndex < sizeof(modes) / sizeof(modes[0]); modeIndex++) {
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(48000.0,
                                                                        modes[modeIndex]);
        NSUInteger window = VibeAudioLevelAnalyzerFFTSize(analyzer);
        NSMutableData *bass = [NSMutableData dataWithLength:window * sizeof(float)];
        NSMutableData *treble = [NSMutableData dataWithLength:window * sizeof(float)];
        VibeTestAddBinTone(bass.mutableBytes, window, 3, 0.5f);
        float trebleAmplitude = 0.5f * sqrtf(
                VibeLevelEnergyPerOctaveScale(0, 48000.0)
                / VibeLevelEnergyPerOctaveScale(4, 48000.0));
        VibeTestAddBinTone(treble.mutableBytes, window, 400, trebleAmplitude);
        float levels[kLevelBandCount] = {-1, -1, -1, -1, -1};
        float *bassChannels[] = {bass.mutableBytes};
        float *trebleChannels[] = {treble.mutableBytes};

        XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, bassChannels, 1,
                                                      window, levels), 1u);
        XCTAssertGreaterThan(levels[0], 0.99f);
        XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, trebleChannels, 1,
                                                      window, levels), 1u);
        XCTAssertLessThan(levels[0], 0.01f);
        XCTAssertGreaterThan(levels[4], 0.99f);

        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            levels[band] = 0.37f;
        }
        XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, bassChannels, 1,
                                                      window / 2, levels), 0u);
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            XCTAssertEqual(levels[band], 0.37f);
        }
        VibeAudioLevelAnalyzerDestroy(analyzer);
    }
}

- (void)testSharedSpectrumIsStableAcrossHardwareRates {
    float baseline[kLevelBandCount] = {0};
    BOOL hasBaseline = NO;
    for (NSNumber *rateValue in @[@44100.0, @48000.0, @88200.0, @96000.0,
                                  @176400.0, @192000.0]) {
        double sampleRate = rateValue.doubleValue;
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
                sampleRate, VibeAudioLevelNormalizationModeSharedSpectrum);
        NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(analyzer);
        NSUInteger strongBin = (NSUInteger)llround(3445.3125 * frameCount / sampleRate);
        NSUInteger weakBin = strongBin * 2;
        NSMutableData *samples = [NSMutableData dataWithLength:frameCount * sizeof(float)];
        VibeTestAddBinTone(samples.mutableBytes, frameCount, strongBin, 0.5f);
        VibeTestAddBinTone(samples.mutableBytes, frameCount, weakBin, 0.05f);
        float *channels[] = {samples.mutableBytes};
        float levels[kLevelBandCount] = {0};
        XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                      frameCount, levels), 1u);
        if (!hasBaseline) {
            memcpy(baseline, levels, sizeof(baseline));
            hasBaseline = YES;
        }
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            XCTAssertEqualWithAccuracy(levels[band], baseline[band], 0.002f,
                                       @"rate %.0f band %lu", sampleRate,
                                       (unsigned long)band);
        }
        VibeAudioLevelAnalyzerDestroy(analyzer);
    }
}

- (void)testOneAnalyzerRebindsToADeliveredRateChangeWithoutAllocation {
    VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
            48000.0, VibeAudioLevelNormalizationModeRelativeActivity);
    XCTAssertTrue(VibeAudioLevelAnalyzerSetSampleRate(analyzer, 192000.0));
    NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(analyzer);
    XCTAssertEqual(frameCount, 8192u);
    NSMutableData *samples = [NSMutableData dataWithLength:frameCount * sizeof(float)];
    VibeTestFillTone(samples.mutableBytes, frameCount, 192000.0, 1000.0, 1.0f);
    float *channels[] = {samples.mutableBytes};
    float levels[kLevelBandCount] = {0};
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                  frameCount, levels), 1u);
    XCTAssertEqual(VibeTestStrongestBand(levels), 3u);
    XCTAssertGreaterThan(levels[3], 0.9f);
    VibeAudioLevelAnalyzerDestroy(analyzer);
}

- (void)testAntiphaseStereoMatchesInPhaseStereo {
    const double sampleRate = 48000.0;
    VibeAudioLevelAnalyzer *inPhase = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeRelativeActivity);
    VibeAudioLevelAnalyzer *antiphase = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeRelativeActivity);
    NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(inPhase);
    NSMutableData *positive = [NSMutableData dataWithLength:frameCount * sizeof(float)];
    NSMutableData *negative = [NSMutableData dataWithLength:frameCount * sizeof(float)];
    VibeTestFillTone(positive.mutableBytes, frameCount, sampleRate, 220.0, 1.0f);
    VibeTestFillTone(negative.mutableBytes, frameCount, sampleRate, 220.0, -1.0f);

    float *sameChannels[] = {positive.mutableBytes, positive.mutableBytes};
    float *oppositeChannels[] = {positive.mutableBytes, negative.mutableBytes};
    float sameLevels[kLevelBandCount] = {0};
    float oppositeLevels[kLevelBandCount] = {0};
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(inPhase, sameChannels, 2,
                                                  frameCount, sameLevels), 1u);
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(antiphase, oppositeChannels, 2,
                                                  frameCount, oppositeLevels), 1u);
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        XCTAssertEqualWithAccuracy(oppositeLevels[band], sameLevels[band], 0.0001,
                                   @"band %lu", (unsigned long)band);
    }
    XCTAssertGreaterThan(sameLevels[VibeTestStrongestBand(sameLevels)], 0.9f);
    VibeAudioLevelAnalyzerDestroy(inPhase);
    VibeAudioLevelAnalyzerDestroy(antiphase);
}

- (void)testArbitraryCallbackChunksMatchOneCompleteWindow {
    const double sampleRate = 48000.0;
    VibeAudioLevelAnalyzer *whole = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeRelativeActivity);
    VibeAudioLevelAnalyzer *chunked = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeRelativeActivity);
    NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(whole);
    NSMutableData *samples = [NSMutableData dataWithLength:frameCount * sizeof(float)];
    VibeTestFillTone(samples.mutableBytes, frameCount, sampleRate, 4000.0, 1.0f);

    float *wholeChannels[] = {samples.mutableBytes};
    float wholeLevels[kLevelBandCount] = {0};
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(whole, wholeChannels, 1,
                                                  frameCount, wholeLevels), 1u);

    const NSUInteger chunkSizes[] = {7, 113, 509, 31, 877, 211, 300};
    NSUInteger offset = 0;
    NSUInteger chunkIndex = 0;
    NSUInteger windows = 0;
    float chunkedLevels[kLevelBandCount] = {0};
    while (offset < frameCount) {
        NSUInteger requested = chunkSizes[chunkIndex++
                % (sizeof(chunkSizes) / sizeof(chunkSizes[0]))];
        NSUInteger count = MIN(requested, frameCount - offset);
        float *channel = (float *)samples.mutableBytes + offset;
        float *channels[] = {channel};
        windows += VibeAudioLevelAnalyzerConsume(chunked, channels, 1, count,
                                                  chunkedLevels);
        offset += count;
    }
    XCTAssertEqual(windows, 1u);
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        XCTAssertEqualWithAccuracy(chunkedLevels[band], wholeLevels[band], 0.0001,
                                   @"band %lu", (unsigned long)band);
    }
    VibeAudioLevelAnalyzerDestroy(whole);
    VibeAudioLevelAnalyzerDestroy(chunked);
}

- (void)testOneLargeCallbackPreservesPeaksFromEveryWindow {
    const double sampleRate = 48000.0;
    VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
            sampleRate, VibeAudioLevelNormalizationModeRelativeActivity);
    NSUInteger window = VibeAudioLevelAnalyzerFFTSize(analyzer);
    NSMutableData *samples = [NSMutableData dataWithLength:window * 2 * sizeof(float)];
    float *values = samples.mutableBytes;
    VibeTestFillTone(values, window, sampleRate, 220.0, 1.0f);
    VibeTestFillTone(values + window, window, sampleRate, 6000.0, 1.0f);
    float *channels[] = {values};
    float levels[kLevelBandCount] = {0};
    XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                  window * 2, levels), 2u);
    XCTAssertGreaterThan(levels[1], 0.9f);
    XCTAssertGreaterThan(levels[4], 0.9f);
    VibeAudioLevelAnalyzerDestroy(analyzer);
}

- (void)testCorruptSamplesProduceFiniteLevelsInBothModes {
    const VibeAudioLevelNormalizationMode modes[] = {
        VibeAudioLevelNormalizationModeRelativeActivity,
        VibeAudioLevelNormalizationModeSharedSpectrum,
    };
    for (NSUInteger modeIndex = 0;
         modeIndex < sizeof(modes) / sizeof(modes[0]); modeIndex++) {
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(48000.0,
                                                                        modes[modeIndex]);
        NSUInteger frameCount = VibeAudioLevelAnalyzerFFTSize(analyzer);
        NSMutableData *samples = [NSMutableData dataWithLength:frameCount * sizeof(float)];
        float *values = samples.mutableBytes;
        for (NSUInteger frame = 0; frame < frameCount; frame++) {
            values[frame] = frame % 2 == 0 ? NAN : INFINITY;
        }
        float *channels[] = {values};
        float levels[kLevelBandCount] = {0};
        XCTAssertEqual(VibeAudioLevelAnalyzerConsume(analyzer, channels, 1,
                                                      frameCount, levels), 1u);
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            XCTAssertTrue(isfinite(levels[band]));
            XCTAssertEqual(levels[band], 0.0f);
        }
        VibeAudioLevelAnalyzerDestroy(analyzer);
    }
}

- (void)testHostileConfigurationFailsClosedWithoutDamagingAnAnalyzer {
    XCTAssertEqual(VibeAudioLevelAnalyzerCreate(
            NAN, VibeAudioLevelNormalizationModeRelativeActivity), NULL);
    XCTAssertEqual(VibeAudioLevelAnalyzerCreate(
            48000.0, (VibeAudioLevelNormalizationMode)NSNotFound), NULL);

    VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(
            48000.0, VibeAudioLevelNormalizationModeSharedSpectrum);
    XCTAssertNotEqual(analyzer, NULL);
    XCTAssertFalse(VibeAudioLevelAnalyzerSetSampleRate(analyzer, NAN));
    XCTAssertEqual(VibeAudioLevelAnalyzerFFTSize(analyzer), 2048u);
    VibeAudioLevelAnalyzerDestroy(analyzer);
}

@end
