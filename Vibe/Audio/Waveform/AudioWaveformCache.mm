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
        // v2: entries carry a format version key; renamed so the budget isn't
        // consumed by unreadable v1 entries waiting for LRU eviction.
        _waveformCache = [[PINCache alloc] initWithName:@"audio_waveform_cache_v2"];
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
    NSString *cacheKey = track.cacheKey;
    CodableAudioWaveform *cachedWaveform = nil;
    BOOL fromCache = NO;
    if (WAVEFORM_CACHE_ENABLED) {
        cachedWaveform = [self->_waveformCache objectForKey:cacheKey];
        fromCache = (cachedWaveform != nil);
    }
    if (!cachedWaveform) {
        cachedWaveform = [loader load:track.url.path];
        if (cachedWaveform && loader.isComplete) {
            if (_normalize) {
                cachedWaveform.waveform->normalize();
            }
            if (WAVEFORM_CACHE_ENABLED) {
                [self->_waveformCache setObjectAsync:cachedWaveform forKey:cacheKey completion:nil];
            }
        }
    }
    // Only report 100% when the waveform is actually complete — either pulled
    // from cache, or freshly loaded without read errors. Partial loads leave
    // the UI at whatever progress its last in-flight callback reported.
    BOOL waveformComplete = cachedWaveform != nil && (fromCache || loader.isComplete);
    if (waveformComplete && !loader.isCancelled) {
        // Capture cachedWaveform strongly so it outlives this stack frame and
        // the waveform pointer remains valid when the block executes on the main thread.
        CodableAudioWaveform *liveWaveform = cachedWaveform;
        run_on_main_thread({
            // Re-check on the main thread: a cancel (new track selected) may
            // have landed after this block was enqueued.
            if (!loader.isCancelled) {
                [self.delegate audioWaveform:liveWaveform didLoadData:1];
            }
        });
    }
}

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (!loader.isCancelled) {
        [self.delegate audioWaveform:waveform didLoadData:percentLoaded];
    }
}

@end

