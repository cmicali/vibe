//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformCache.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "BASSAudioWaveformLoader.h"

#pragma mark - Waveform Cache

#define WAVEFORM_CACHE_ENABLED 1

@interface AudioWaveformCache () <AudioWaveformLoaderDelegate>
@end

@implementation AudioWaveformCache {
    dispatch_queue_t                _loaderQueue;
    PINCache*                       _waveformCache;
    __weak AudioWaveformLoader*     _currentLoader;
    BOOL                            _normalize;
}

- (id)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _loaderQueue = dispatch_queue_create("AudioWaveformCache", queueAttributes);
        _waveformCache = [[PINCache alloc] initWithName:@"audio_waveform_cache"];
        _waveformCache.diskCache.byteLimit = 64 * 1024 * 1024; // 64mb disk cache limit
        _waveformCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
        _normalize = NO;
        _currentLoader = nil;
        if (!WAVEFORM_CACHE_ENABLED) {
            [self invalidate];
        }
    }
    return self;
}

- (void)invalidate {
    [_waveformCache removeAllObjects];
}

- (void)loadWaveformForTrack:(AudioTrack *)track {
    [_currentLoader cancel];
    AudioWaveformLoader *loader = [[BASSAudioWaveformLoader alloc] initWithDelegate:self];
     _currentLoader = loader;
    dispatch_async(_loaderQueue, ^{
        [self load:track withLoader:loader];
    });
}

- (void)load:(AudioTrack *)track withLoader:(AudioWaveformLoader *)loader {
    NSString *cacheKey = track.calculateFileHash;
    AudioWaveform *waveform;
    CodableAudioWaveform *cachedWaveform;
    if (WAVEFORM_CACHE_ENABLED) {
        cachedWaveform = [self->_waveformCache objectForKey:cacheKey];
    }
    if (cachedWaveform) {
        waveform = cachedWaveform.waveform;
    }
    else {
        waveform = [loader load:track.url.path];
        if (loader.isComplete) {
            if (_normalize) {
                waveform->normalize();
            }
            if (WAVEFORM_CACHE_ENABLED) {
                cachedWaveform = [[CodableAudioWaveform alloc] initWithWaveform:waveform];
                [self->_waveformCache setObject:cachedWaveform forKey:cacheKey];
            }
        }
    }
    if (!loader.isCancelled) {
        run_on_main_thread({
            if (!loader.isCancelled) {
                [self.delegate audioWaveform:waveform didLoadData:1];
            }
        });
    }
}

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (!loader.isCancelled) {
        [self.delegate audioWaveform:waveform didLoadData:percentLoaded];
    }
}

@end

