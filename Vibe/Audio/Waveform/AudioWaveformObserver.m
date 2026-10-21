//
//  AudioWaveformObserver.m
//  Vibe
//

#import "AudioWaveformObserver.h"

@implementation AudioWaveformObserver {
    AudioWaveformSinkFactory _sinkFactory;
}

- (instancetype)initWithIdentifier:(NSString *)identifier sinkFactory:(AudioWaveformSinkFactory)sinkFactory {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _sinkFactory = [sinkFactory copy];
    }
    return self;
}

- (id<AudioWaveformSink>)sinkForSampleRate:(double)sampleRate window:(NSRange)window {
    return _sinkFactory(sampleRate, window);
}

@end
