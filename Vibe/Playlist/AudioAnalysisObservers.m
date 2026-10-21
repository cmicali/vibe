//
//  AudioAnalysisObservers.m
//  Vibe
//

#import "AudioAnalysisObservers.h"

#include <math.h>

@implementation AudioBPMAnalyzer (WaveformObserver)

+ (AudioWaveformObserver *)waveformObserver {
    static AudioWaveformObserver *observer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        observer = [[AudioWaveformObserver alloc] initWithIdentifier:@"bpm"
                sinkFactory:^id<AudioWaveformSink>(double sampleRate, NSRange window) {
            return [[AudioBPMAnalyzer alloc] initWithSampleRate:sampleRate];
        }];
    });
    return observer;
}

- (id)waveformResult {
    return @([self finish]);
}

// A bad tempo degrades to unknown: it is no reason to drop good waveform data.
+ (float)tempoInResults:(NSDictionary<NSString *, id> *)results {
    id tempo = results[AudioBPMAnalyzer.waveformObserver.identifier];
    float bpm = [tempo isKindOfClass:NSNumber.class] ? [tempo floatValue] : 0;
    return isfinite(bpm) && bpm > 0 ? bpm : 0;
}

@end

@implementation AudioKeyAnalyzer (WaveformObserver)

+ (AudioWaveformObserver *)waveformObserver {
    static AudioWaveformObserver *observer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        observer = [[AudioWaveformObserver alloc] initWithIdentifier:@"key"
                sinkFactory:^id<AudioWaveformSink>(double sampleRate, NSRange window) {
            return [[AudioKeyAnalyzer alloc] initWithSampleRate:sampleRate];
        }];
    });
    return observer;
}

- (id)waveformResult {
    return @([self finish]);
}

// TRAP: 0 is C major, so an absent or unreadable key must answer
// VibeMusicalKeyNone, never the 0 a message to nil returns.
+ (VibeMusicalKey)keyInResults:(NSDictionary<NSString *, id> *)results {
    id key = results[AudioKeyAnalyzer.waveformObserver.identifier];
    double value = [key isKindOfClass:NSNumber.class] ? [key doubleValue] : NAN;
    return value >= 0 && value < 24 && value == floor(value) ? (VibeMusicalKey)value : VibeMusicalKeyNone;
}

@end
