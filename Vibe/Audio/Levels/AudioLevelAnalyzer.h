//
//  AudioLevelAnalyzer.h
//  Vibe
//
//  Pure, preallocated FFT analysis, with no pipeline, publication or view
//  knowledge, so the host-less suite tests it.
//

#import "AudioLevelMath.h"
#import <CoreAudioTypes/CoreAudioBaseTypes.h>

typedef struct VibeAudioLevelAnalyzer VibeAudioLevelAnalyzer;

NS_ASSUME_NONNULL_BEGIN

// Allocates everything up front; NULL on any failure. The normalization mode
// is immutable.
VibeAudioLevelAnalyzer * _Nullable VibeAudioLevelAnalyzerCreate(
        double sampleRate, VibeAudioLevelNormalizationMode normalizationMode);
void VibeAudioLevelAnalyzerDestroy(VibeAudioLevelAnalyzer * _Nullable analyzer);

// Rebinds window length, fixed-Hz bins and references to a rate; for create
// and the tests, since a meter's rate is fixed. Allocation-free; a same-rate
// call is a no-op.
BOOL VibeAudioLevelAnalyzerSetSampleRate(VibeAudioLevelAnalyzer *analyzer,
                                         double sampleRate);

NSUInteger VibeAudioLevelAnalyzerFFTSize(const VibeAudioLevelAnalyzer *analyzer);

// Forgets the partial window, the pending summary and every reference, so
// the next window is analyzed as the first. Render-thread safe.
void VibeAudioLevelAnalyzerReset(VibeAudioLevelAnalyzer *analyzer) CA_REALTIME_API;

// At most the stereo pair. Each window that fills is analyzed in the call that
// filled it and folded into the next summary. Returns the windows analyzed.
NSUInteger VibeAudioLevelAnalyzerConsume(VibeAudioLevelAnalyzer *analyzer,
                                         float * _Nonnull const * _Nonnull channels,
                                         NSUInteger channelCount,
                                         NSUInteger frameCount) CA_REALTIME_API;

// Summarizes and clears the windows analyzed since the last call: returns
// their number, and with any overwrites all five `callbackLevels`. The
// per-mode rules are Levels/AGENTS.md's.
NSUInteger VibeAudioLevelAnalyzerSummarize(VibeAudioLevelAnalyzer *analyzer,
                                           float callbackLevels[_Nonnull kLevelBandCount]) CA_REALTIME_API;

NS_ASSUME_NONNULL_END
