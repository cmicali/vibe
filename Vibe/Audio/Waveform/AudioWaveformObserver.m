//
//  AudioWaveformObserver.m
//  Vibe
//

#import "AudioWaveformObserver.h"

static NSMutableSet<NSString *> *sIdentifiers;

@implementation AudioWaveformObserver {
    AudioWaveformSinkFactory _sinkFactory;
}

- (instancetype)initWithIdentifier:(NSString *)identifier sinkFactory:(AudioWaveformSinkFactory)sinkFactory {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _sinkFactory = [sinkFactory copy];
        @synchronized (AudioWaveformObserver.class) {
            if (!sIdentifiers) {
                sIdentifiers = [NSMutableSet set];
            }
            [sIdentifiers addObject:_identifier];
        }
    }
    return self;
}

- (id<AudioWaveformSink>)sinkForSampleRate:(double)sampleRate window:(NSRange)window {
    return _sinkFactory(sampleRate, window);
}

+ (NSSet<NSString *> *)identifiers {
    @synchronized (AudioWaveformObserver.class) {
        return sIdentifiers ? [sIdentifiers copy] : [NSSet set];
    }
}

@end
