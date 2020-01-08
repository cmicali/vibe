//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformCache.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "BASSAudioWaveformLoader.h"

#pragma mark - Waveform Loader

#pragma mark - Waveform Cache

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
         [_waveformCache removeAllObjects];
    }
    return self;
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
    AudioWaveformOld *waveform = [self->_waveformCache objectForKey:cacheKey];
    if (!waveform) {
        waveform = [loader load:track.url.path];
    }
    if (!loader.isCancelled) {
        if (_normalize) {
            [waveform normalize];
        }
        [self->_waveformCache setObject:waveform forKey:cacheKey];
        run_on_main_thread({
            if (!loader.isCancelled) {
                [self.delegate audioWaveform:waveform didLoadData:1];
            }
        });
    }
}

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(AudioWaveformOld *)waveform didLoadData:(float)percentLoaded {
    [self.delegate audioWaveform:waveform didLoadData:percentLoaded];
}

@end

