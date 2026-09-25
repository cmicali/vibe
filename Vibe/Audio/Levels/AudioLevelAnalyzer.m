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
    BOOL usesSharedSpectrum;   // shared or balanced
    BOOL usesRelativeActivity; // relative or balanced
    float windowDuration;      // one FFT window, in seconds
    NSUInteger bandLow[kLevelBandCount];
    NSUInteger bandHigh[kLevelBandCount];
    float sharedEnergyPerOctaveScale[kLevelBandCount];
    float relativeReference[kLevelBandCount];
    float sharedReference;
    double sampleRate;
    NSUInteger channelCount;
    NSUInteger fill;
    // The windows analyzed since the last summary: their count, each band's
    // summed energy per octave and its largest normalized activity level.
    NSUInteger pendingWindows;
    float pendingSharedEnergy[kLevelBandCount];
    float pendingRelativePeak[kLevelBandCount];
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
                && normalizationMode != VibeAudioLevelNormalizationModeSharedSpectrum
                && normalizationMode != VibeAudioLevelNormalizationModeBalancedSpectrum)) {
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
    analyzer->usesSharedSpectrum = normalizationMode != VibeAudioLevelNormalizationModeRelativeActivity;
    analyzer->usesRelativeActivity = normalizationMode != VibeAudioLevelNormalizationModeSharedSpectrum;
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
    analyzer->windowDuration = (float)((double)fftSize / sampleRate);
    analyzer->log2FFTSize = 0;
    for (NSUInteger value = fftSize; value > 1; value >>= 1) {
        analyzer->log2FFTSize++;
    }
    analyzer->channelCount = 0;
    vDSP_hann_window(analyzer->window, fftSize, vDSP_HANN_NORM);
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        VibeLevelBandBinRange(band, fftSize, sampleRate,
                              &analyzer->bandLow[band], &analyzer->bandHigh[band]);
        analyzer->sharedEnergyPerOctaveScale[band] =
                VibeLevelEnergyPerOctaveScale(band, sampleRate);
    }
    VibeAudioLevelAnalyzerReset(analyzer);
    return YES;
}

// The vDSP calls the compiler cannot check: Accelerate attributes them with
// nothing, and they allocate nothing and block on nothing.
VIBE_REALTIME_UNCHECKED_BEGIN
static void VibeAudioLevelAnalyzerMeasureFrame(
        VibeAudioLevelAnalyzer *analyzer,
        float spectrumEnergy[kLevelBandCount],
        float activityEnergy[kLevelBandCount]) CA_REALTIME_API {
    BOOL balancedSpectrum = analyzer->normalizationMode == VibeAudioLevelNormalizationModeBalancedSpectrum;
    BOOL measuresSpectrum = analyzer->usesSharedSpectrum;
    BOOL measuresActivity = analyzer->usesRelativeActivity;
    float channelSpectrumEnergy[kLevelBandCount][kMaximumAnalyzedChannels] = {{0}};
    float channelActivityEnergy[kLevelBandCount][kMaximumAnalyzedChannels] = {{0}};
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
            if (measuresSpectrum) {
                vDSP_sve(analyzer->magnitudes + low, 1, &spectralEnergy, high - low);
                channelSpectrumEnergy[band][channel] = VibeLevelScaleFFTEnergy(
                        spectralEnergy, analyzer->fftSize);
                if (balancedSpectrum) {
                    float meanEnergy = spectralEnergy / (float)(high - low);
                    channelActivityEnergy[band][channel] = VibeLevelScaleFFTEnergy(
                            meanEnergy, analyzer->fftSize);
                }
            }
            else {
                vDSP_meanv(analyzer->magnitudes + low, 1, &spectralEnergy,
                           high - low);
                channelActivityEnergy[band][channel] = VibeLevelScaleFFTEnergy(
                        spectralEnergy, analyzer->fftSize);
            }
        }
    }

    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        if (measuresSpectrum) {
            float combined = VibeLevelMeanChannelEnergy(
                    channelSpectrumEnergy[band], analyzer->channelCount);
            spectrumEnergy[band] = combined
                    * analyzer->sharedEnergyPerOctaveScale[band];
        }
        if (measuresActivity) {
            activityEnergy[band] = VibeLevelMeanChannelEnergy(
                    channelActivityEnergy[band], analyzer->channelCount);
        }
    }
}
VIBE_REALTIME_END

// What the render does with the analyzer: plain memory and math, checked.
VIBE_REALTIME_CHECKED_BEGIN
void VibeAudioLevelAnalyzerReset(VibeAudioLevelAnalyzer *analyzer) CA_REALTIME_API {
    if (!analyzer) {
        return;
    }
    analyzer->fill = 0;
    analyzer->pendingWindows = 0;
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        analyzer->relativeReference[band] = kLevelReferenceFloor;
        analyzer->pendingSharedEnergy[band] = 0;
        analyzer->pendingRelativePeak[band] = 0;
    }
    analyzer->sharedReference = kLevelReferenceFloor;
}

NSUInteger VibeAudioLevelAnalyzerConsume(VibeAudioLevelAnalyzer *analyzer,
                                         float * const *channels,
                                         NSUInteger channelCount,
                                         NSUInteger frameCount) CA_REALTIME_API {
    if (!analyzer || !channels || frameCount == 0) {
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
        if (analyzer->fill < analyzer->fftSize) {
            continue;
        }
        float spectrumEnergy[kLevelBandCount] = {0};
        float activityEnergy[kLevelBandCount] = {0};
        VibeAudioLevelAnalyzerMeasureFrame(analyzer, spectrumEnergy,
                                            activityEnergy);
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            if (analyzer->usesSharedSpectrum) {
                analyzer->pendingSharedEnergy[band] += spectrumEnergy[band];
            }
            if (analyzer->usesRelativeActivity) {
                analyzer->relativeReference[band] = VibeLevelUpdateReference(
                        analyzer->relativeReference[band], activityEnergy[band],
                        analyzer->windowDuration);
                float level = VibeLevelNormalize(
                        activityEnergy[band], analyzer->relativeReference[band]);
                analyzer->pendingRelativePeak[band] = MAX(analyzer->pendingRelativePeak[band], level);
            }
        }
        analyzer->pendingWindows++;
        analyzer->fill = 0;
        windows++;
    }
    return windows;
}

NSUInteger VibeAudioLevelAnalyzerSummarize(VibeAudioLevelAnalyzer *analyzer,
                                           float callbackLevels[kLevelBandCount]) CA_REALTIME_API {
    if (!analyzer || !callbackLevels || analyzer->pendingWindows == 0) {
        return 0;
    }
    NSUInteger windows = analyzer->pendingWindows;
    BOOL balancedSpectrum = analyzer->normalizationMode == VibeAudioLevelNormalizationModeBalancedSpectrum;
    if (analyzer->usesSharedSpectrum) {
        float meanEnergy[kLevelBandCount];
        float strongest = 0;
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            meanEnergy[band] = analyzer->pendingSharedEnergy[band] / (float)windows;
            strongest = MAX(strongest, meanEnergy[band]);
        }
        analyzer->sharedReference = VibeLevelUpdateReference(
                analyzer->sharedReference, strongest, analyzer->windowDuration * (float)windows);
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            float sharedLevel = VibeLevelNormalize(meanEnergy[band],
                                                    analyzer->sharedReference);
            callbackLevels[band] = balancedSpectrum
                    ? VibeLevelBalancedSpectrumLevel(sharedLevel,
                                                     analyzer->pendingRelativePeak[band])
                    : sharedLevel;
        }
    }
    else {
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            callbackLevels[band] = analyzer->pendingRelativePeak[band];
        }
    }
    analyzer->pendingWindows = 0;
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        analyzer->pendingSharedEnergy[band] = 0;
        analyzer->pendingRelativePeak[band] = 0;
    }
    return windows;
}
VIBE_REALTIME_END
