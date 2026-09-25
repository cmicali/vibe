//
//  AudioLevelAnalyzer.h
//  Vibe
//
//  Pure, preallocated FFT analysis. It knows nothing about the render pipeline,
//  publication, or views and is therefore usable by the host-less test suite.
//

#import "AudioLevelMath.h"
#import <CoreAudioTypes/CoreAudioBaseTypes.h>

typedef struct VibeAudioLevelAnalyzer VibeAudioLevelAnalyzer;

NS_ASSUME_NONNULL_BEGIN

// Allocates every FFT and scratch resource up front. The normalization mode is
// immutable; switching modes replaces the analyzer. Returns NULL on any
// failure; consume performs no allocation, logging, Objective-C messaging or
// locking and is suitable for an audio render callback.
VibeAudioLevelAnalyzer * _Nullable VibeAudioLevelAnalyzerCreate(
        double sampleRate, VibeAudioLevelNormalizationMode normalizationMode);
void VibeAudioLevelAnalyzerDestroy(VibeAudioLevelAnalyzer * _Nullable analyzer);

// Rebinds window length, fixed-Hz bins and AGC state to a sample rate; the
// create path and the tests are its callers, since a meter's rate is fixed. Scratch and FFT weights are already sized for the maximum, so
// this is allocation-free and render-thread safe. A same-rate call is a no-op.
BOOL VibeAudioLevelAnalyzerSetSampleRate(VibeAudioLevelAnalyzer *analyzer,
                                         double sampleRate);

NSUInteger VibeAudioLevelAnalyzerFFTSize(const VibeAudioLevelAnalyzer *analyzer);

// Forgets the partial window, the windows awaiting a summary and every
// running reference, so the next window is analyzed as the first: what a
// fresh install of the meter needs, or its next publication carries the
// audio before the install. Allocation-free and render-thread safe.
void VibeAudioLevelAnalyzerReset(VibeAudioLevelAnalyzer *analyzer) CA_REALTIME_API;

// Consumes non-interleaved float channels, preserving at most the stereo pair
// the app's master bus supplies: the frames join the partial window, and each
// window that fills is analyzed at once, in the call that filled it, its
// result folded into the summary the next VibeAudioLevelAnalyzerSummarize
// publishes. Returns the number of windows this call analyzed.
NSUInteger VibeAudioLevelAnalyzerConsume(VibeAudioLevelAnalyzer *analyzer,
                                         float * _Nonnull const * _Nonnull channels,
                                         NSUInteger channelCount,
                                         NSUInteger frameCount) CA_REALTIME_API;

// The summary of every window analyzed since the last summary, which it
// clears: returns their number, and with one or more overwrites all five
// `callbackLevels`; with none it leaves them untouched. Relative activity
// reports the maximum normalized level seen per band, each band's private
// reference having advanced per window. Shared spectrum converts each band's
// summed energy to energy per octave, averages it over the windows, then
// advances its one reference for the full analyzed duration and normalizes
// all five once. Balanced spectrum computes both summaries from one FFT per
// window and lets gated relative activity assist the shared result.
NSUInteger VibeAudioLevelAnalyzerSummarize(VibeAudioLevelAnalyzer *analyzer,
                                           float callbackLevels[_Nonnull kLevelBandCount]) CA_REALTIME_API;

NS_ASSUME_NONNULL_END
