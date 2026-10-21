//
//  AudioAnalysisObservers.h
//  Vibe
//
//  Vibe's binding of the tempo and key analyzers to the waveform decode.
//  Each analyzer is its own sink, and each shell attaches the observers its
//  settings ask for. Neither analyzer nor the loader imports the other.
//

#import "AudioBPMAnalyzer.h"
#import "AudioKeyAnalyzer.h"
#import "AudioWaveformObserver.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioBPMAnalyzer (WaveformObserver) <AudioWaveformSink>

// Identified as "bpm". Its result is the tempo, an NSNumber.
@property (class, readonly) AudioWaveformObserver *waveformObserver;

// The tempo in a decode's results, or 0 when it is absent or undetectable.
+ (float)tempoInResults:(NSDictionary<NSString *, id> *)results;

@end

@interface AudioKeyAnalyzer (WaveformObserver) <AudioWaveformSink>

// Identified as "key". Its result is the key, an NSNumber.
@property (class, readonly) AudioWaveformObserver *waveformObserver;

// The key in a decode's results, or VibeMusicalKeyNone when it is absent or
// undetectable.
+ (VibeMusicalKey)keyInResults:(NSDictionary<NSString *, id> *)results;

@end

NS_ASSUME_NONNULL_END
