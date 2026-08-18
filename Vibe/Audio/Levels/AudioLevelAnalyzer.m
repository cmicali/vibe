//
//  AudioLevelAnalyzer.m
//  Vibe
//

#import "AudioLevelAnalyzer.h"

#import <Accelerate/Accelerate.h>

enum { kMaximumAnalyzedChannels = 2 };
enum { kMaximumFFTSize = 8192, kLog2MaximumFFTSize = 13 };

struct VibeAudioLevelAnalyzer {
    FFTSetup fftSetup;
    NSUInteger fftCapacity;
    NSUInteger fftSize;
    vDSP_Length log2FFTSize;
    VibeAudioLevelNormalizationMode normalizationMode;
    NSUInteger bandLow[kLevelBandCount];
    NSUInteger bandHigh[kLevelBandCount];
    float sharedEnergyPerOctaveScale[kLevelBandCount];
    float relativeReference[kLevelBandCount];
    float sharedReference;
    double sampleRate;
    NSUInteger channelCount;
    NSUInteger fill;
    float *window;
    float *accum[kMaximumAnalyzedChannels];
    float *windowed;
    float *splitReal;
    float *splitImag;
    float *magnitudes;
    float scratch[];
};

VibeAudioLevelAnalyzer *VibeAudioLevelAnalyzerCreate(
        double sampleRate, VibeAudioLevelNormalizationMode normalizationMode) {
    if (!isfinite(sampleRate) || sampleRate <= 0
            || (normalizationMode != VibeAudioLevelNormalizationModeRelativeActivity
                && normalizationMode != VibeAudioLevelNormalizationModeSharedSpectrum)) {
        return NULL;
    }
    // Window + two input lanes + windowed + the real FFT's three half-sized
    // arrays. One checked allocation keeps every render-thread pointer stable.
    size_t floatCount = kMaximumFFTSize * 4 + (kMaximumFFTSize / 2) * 3;
    if (floatCount > (SIZE_MAX - sizeof(VibeAudioLevelAnalyzer)) / sizeof(float)) {
        return NULL;
    }
    size_t bytes = sizeof(VibeAudioLevelAnalyzer) + floatCount * sizeof(float);
    VibeAudioLevelAnalyzer *analyzer = calloc(1, bytes);
    if (!analyzer) {
        return NULL;
    }
    analyzer->fftCapacity = kMaximumFFTSize;
    analyzer->normalizationMode = normalizationMode;
    analyzer->fftSetup = vDSP_create_fftsetup(kLog2MaximumFFTSize, kFFTRadix2);
    if (!analyzer->fftSetup) {
        free(analyzer);
        return NULL;
    }

    float *cursor = analyzer->scratch;
    analyzer->window = cursor;
    cursor += analyzer->fftCapacity;
    for (NSUInteger channel = 0; channel < kMaximumAnalyzedChannels; channel++) {
        analyzer->accum[channel] = cursor;
        cursor += analyzer->fftCapacity;
    }
    analyzer->windowed = cursor;
    cursor += analyzer->fftCapacity;
    analyzer->splitReal = cursor;
    cursor += analyzer->fftCapacity / 2;
    analyzer->splitImag = cursor;
    cursor += analyzer->fftCapacity / 2;
    analyzer->magnitudes = cursor;
    if (!VibeAudioLevelAnalyzerSetSampleRate(analyzer, sampleRate)) {
        VibeAudioLevelAnalyzerDestroy(analyzer);
        return NULL;
    }
    return analyzer;
}

void VibeAudioLevelAnalyzerDestroy(VibeAudioLevelAnalyzer *analyzer) {
    if (!analyzer) {
        return;
    }
    if (analyzer->fftSetup) {
        vDSP_destroy_fftsetup(analyzer->fftSetup);
    }
    free(analyzer);
}

NSUInteger VibeAudioLevelAnalyzerFFTSize(const VibeAudioLevelAnalyzer *analyzer) {
    return analyzer ? analyzer->fftSize : 0;
}

BOOL VibeAudioLevelAnalyzerSetSampleRate(VibeAudioLevelAnalyzer *analyzer,
                                         double sampleRate) {
    if (!analyzer || !isfinite(sampleRate) || sampleRate <= 0) {
        return NO;
    }
    if (fabs(analyzer->sampleRate - sampleRate) < 0.5) {
        return YES;
    }
    NSUInteger fftSize = VibeLevelFFTSizeForSampleRate(sampleRate);
    if (fftSize > analyzer->fftCapacity) {
        return NO;
    }
    analyzer->sampleRate = sampleRate;
    analyzer->fftSize = fftSize;
    analyzer->log2FFTSize = 0;
    for (NSUInteger value = fftSize; value > 1; value >>= 1) {
        analyzer->log2FFTSize++;
    }
    analyzer->channelCount = 0;
    analyzer->fill = 0;
    vDSP_hann_window(analyzer->window, fftSize, vDSP_HANN_NORM);
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        VibeLevelBandBinRange(band, fftSize, sampleRate,
                              &analyzer->bandLow[band], &analyzer->bandHigh[band]);
        analyzer->sharedEnergyPerOctaveScale[band] =
                VibeLevelEnergyPerOctaveScale(band, sampleRate);
        analyzer->relativeReference[band] = kLevelReferenceFloor;
    }
    analyzer->sharedReference = kLevelReferenceFloor;
    return YES;
}

static void VibeAudioLevelAnalyzerMeasureFrame(VibeAudioLevelAnalyzer *analyzer,
                                                float energy[kLevelBandCount]) {
    float channelEnergy[kLevelBandCount][kMaximumAnalyzedChannels] = {{0}};
    for (NSUInteger channel = 0; channel < analyzer->channelCount; channel++) {
        vDSP_vmul(analyzer->accum[channel], 1, analyzer->window, 1,
                  analyzer->windowed, 1, analyzer->fftSize);
        DSPSplitComplex split = {analyzer->splitReal, analyzer->splitImag};
        vDSP_ctoz((const DSPComplex *)analyzer->windowed, 2, &split, 1,
                  analyzer->fftSize / 2);
        vDSP_fft_zrip(analyzer->fftSetup, &split, 1, analyzer->log2FFTSize,
                      kFFTDirection_Forward);
        split.realp[0] = 0;
        split.imagp[0] = 0;
        vDSP_zvmags(&split, 1, analyzer->magnitudes, 1,
                    analyzer->fftSize / 2);

        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            NSUInteger low = analyzer->bandLow[band];
            NSUInteger high = analyzer->bandHigh[band];
            float spectralEnergy = 0;
            if (analyzer->normalizationMode
                    == VibeAudioLevelNormalizationModeSharedSpectrum) {
                vDSP_sve(analyzer->magnitudes + low, 1, &spectralEnergy, high - low);
            }
            else {
                vDSP_meanv(analyzer->magnitudes + low, 1, &spectralEnergy,
                           high - low);
            }
            channelEnergy[band][channel] = VibeLevelScaleFFTEnergy(
                    spectralEnergy, analyzer->fftSize);
        }
    }

    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        float combined = VibeLevelMeanChannelEnergy(channelEnergy[band],
                                                      analyzer->channelCount);
        energy[band] = analyzer->normalizationMode
                        == VibeAudioLevelNormalizationModeSharedSpectrum
                ? combined * analyzer->sharedEnergyPerOctaveScale[band]
                : combined;
    }
}

NSUInteger VibeAudioLevelAnalyzerConsume(VibeAudioLevelAnalyzer *analyzer,
                                         float * const *channels,
                                         NSUInteger channelCount,
                                         NSUInteger frameCount,
                                         float callbackLevels[kLevelBandCount]) {
    if (!analyzer || !channels || !callbackLevels || frameCount == 0) {
        return 0;
    }
    NSUInteger analyzedChannels = MIN(channelCount, (NSUInteger)kMaximumAnalyzedChannels);
    if (analyzedChannels == 0) {
        return 0;
    }
    for (NSUInteger channel = 0; channel < analyzedChannels; channel++) {
        if (!channels[channel]) {
            return 0;
        }
    }
    if (analyzer->channelCount != analyzedChannels) {
        analyzer->channelCount = analyzedChannels;
        analyzer->fill = 0;
    }

    BOOL sharedSpectrum = analyzer->normalizationMode
            == VibeAudioLevelNormalizationModeSharedSpectrum;
    float relativePeakLevels[kLevelBandCount] = {0};
    float sharedEnergySum[kLevelBandCount] = {0};
    float windowDuration = (float)((double)analyzer->fftSize / analyzer->sampleRate);
    NSUInteger windows = 0;
    NSUInteger consumed = 0;
    while (consumed < frameCount) {
        NSUInteger take = MIN(analyzer->fftSize - analyzer->fill,
                              frameCount - consumed);
        for (NSUInteger channel = 0; channel < analyzedChannels; channel++) {
            memcpy(analyzer->accum[channel] + analyzer->fill,
                   channels[channel] + consumed, take * sizeof(float));
        }
        analyzer->fill += take;
        consumed += take;
        if (analyzer->fill == analyzer->fftSize) {
            float energy[kLevelBandCount];
            VibeAudioLevelAnalyzerMeasureFrame(analyzer, energy);
            if (sharedSpectrum) {
                for (NSUInteger band = 0; band < kLevelBandCount; band++) {
                    sharedEnergySum[band] += energy[band];
                }
            }
            else {
                for (NSUInteger band = 0; band < kLevelBandCount; band++) {
                    analyzer->relativeReference[band] = VibeLevelUpdateReference(
                            analyzer->relativeReference[band], energy[band],
                            windowDuration);
                    float level = VibeLevelNormalize(
                            energy[band], analyzer->relativeReference[band]);
                    relativePeakLevels[band] = MAX(relativePeakLevels[band], level);
                }
            }
            analyzer->fill = 0;
            windows++;
        }
    }

    if (sharedSpectrum && windows > 0) {
        float meanEnergy[kLevelBandCount];
        float strongest = 0;
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            meanEnergy[band] = sharedEnergySum[band] / (float)windows;
            strongest = MAX(strongest, meanEnergy[band]);
        }
        analyzer->sharedReference = VibeLevelUpdateReference(
                analyzer->sharedReference, strongest, windowDuration * (float)windows);
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            callbackLevels[band] = VibeLevelNormalize(meanEnergy[band],
                                                       analyzer->sharedReference);
        }
    }
    else if (windows > 0) {
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            callbackLevels[band] = relativePeakLevels[band];
        }
    }
    return windows;
}
