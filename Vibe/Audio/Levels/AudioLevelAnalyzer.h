//
//  AudioLevelAnalyzer.h
//  Vibe
//
//  Pure, preallocated FFT analysis. It knows nothing about AVAudioEngine,
//  publication, or views and is therefore usable by the host-less test suite.
//

#import "AudioLevelMath.h"

typedef struct VibeAudioLevelAnalyzer VibeAudioLevelAnalyzer;

NS_ASSUME_NONNULL_BEGIN

// Allocates every FFT and scratch resource up front. The normalization mode is
// immutable; switching modes replaces the analyzer. Returns NULL on any
// failure; consume performs no allocation, logging, Objective-C messaging or
// locking and is suitable for an audio render callback.
VibeAudioLevelAnalyzer * _Nullable VibeAudioLevelAnalyzerCreate(
        double sampleRate, VibeAudioLevelNormalizationMode normalizationMode);
void VibeAudioLevelAnalyzerDestroy(VibeAudioLevelAnalyzer * _Nullable analyzer);

// Rebinds window length, fixed-Hz bins and AGC state when the tap's delivered
// rate changes. Scratch and FFT weights are already sized for the maximum, so
// this is allocation-free and render-thread safe. A same-rate call is a no-op.
BOOL VibeAudioLevelAnalyzerSetSampleRate(VibeAudioLevelAnalyzer *analyzer,
                                         double sampleRate);

NSUInteger VibeAudioLevelAnalyzerFFTSize(const VibeAudioLevelAnalyzer *analyzer);

// Consumes non-interleaved float channels, preserving at most the stereo pair
// the app's master bus supplies. Returns the number of complete fixed-time
// windows analyzed. A nonzero return overwrites all five `callbackLevels` with
// this call's result; a zero return leaves them untouched. Relative activity
// reports the maximum normalized level seen per band. Shared spectrum converts
// each band's summed energy to energy per octave, averages it over the completed
// windows, then advances its one reference for the full analyzed duration and
// normalizes all five once.
NSUInteger VibeAudioLevelAnalyzerConsume(VibeAudioLevelAnalyzer *analyzer,
                                         float * _Nonnull const * _Nonnull channels,
                                         NSUInteger channelCount,
                                         NSUInteger frameCount,
                                         float callbackLevels[_Nonnull kLevelBandCount]);

NS_ASSUME_NONNULL_END
