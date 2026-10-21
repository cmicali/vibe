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

// Identified as "bpm", the archive's name for the tempo since format 6.
@property (class, readonly) AudioWaveformObserver *waveformObserver;

// The tempo in a decode's results, or 0 when it is absent or undetectable.
+ (float)tempoInResults:(NSDictionary<NSString *, NSNumber *> *)results;

@end

@interface AudioKeyAnalyzer (WaveformObserver) <AudioWaveformSink>

// Identified as "key", the archive's name for the key since format 6.
@property (class, readonly) AudioWaveformObserver *waveformObserver;

// The key in a decode's results, or VibeMusicalKeyNone when it is absent or
// undetectable.
+ (VibeMusicalKey)keyInResults:(NSDictionary<NSString *, NSNumber *> *)results;

@end

NS_ASSUME_NONNULL_END
