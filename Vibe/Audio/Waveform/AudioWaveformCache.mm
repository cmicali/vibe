//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformCache.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AVFAudioWaveformLoader.h"

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
        // Utility, not user-initiated: the loader blocks on PINCache's own
        // utility-QoS queues (sync objectForKey:), and a higher class here
        // just trips the Thread Performance Checker's priority-inversion
        // warning while stealing P-core time from playback start.
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _loaderQueue = dispatch_queue_create("AudioWaveformCache", queueAttributes);
        _normalize = NO;
        _currentLoader = nil;
        // Create the cache on the loader queue: constructing it on the main
        // thread would boost PINCache's internal init-time disk scan to
        // user-initiated QoS, which then priority-inverts against our
        // utility-QoS cache calls (Thread Performance Checker warning at
        // first drop). Every cache use is on this serial queue, so ordering
        // is guaranteed.
        dispatch_async(_loaderQueue, ^{
            // v2: entries carry a format version key; renamed so the budget
            // isn't consumed by unreadable v1 entries waiting for LRU
            // eviction.
            self->_waveformCache = [[PINCache alloc] initWithName:@"audio_waveform_cache_v2"];
            self->_waveformCache.diskCache.byteLimit = 64 * 1024 * 1024; // 64mb disk cache limit
            self->_waveformCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
            // The memory cache is deliberately unused (load: reads and writes
            // diskCache directly): on macOS PINMemoryCache never evicts, so it
            // would pin ~64KB per unique track played for the app's lifetime.
            // The view retains the one live waveform; replays re-read from
            // disk in a few ms on this utility queue.
            if (!WAVEFORM_CACHE_ENABLED) {
                [self->_waveformCache removeAllObjects];
            }
        });
    }
    return self;
}

- (void)invalidate {
    dispatch_async(_loaderQueue, ^{
        [self->_waveformCache removeAllObjects];
    });
}

- (void)loadWaveformForTrack:(AudioTrack *)track {
    [_currentLoader cancel];
    AudioWaveformLoader *loader = [[AVFAudioWaveformLoader alloc] initWithDelegate:self];
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
        cachedWaveform = (CodableAudioWaveform *)[self->_waveformCache.diskCache objectForKey:cacheKey];
        // PINCache unarchives without secure coding, so a corrupt/tampered
        // entry with a different root class decodes cleanly and would crash
        // (unrecognized selector) at first use — on every play of this track,
        // since nothing would ever evict it. Same guard as the metadata cache.
        if (cachedWaveform && ![cachedWaveform isKindOfClass:[CodableAudioWaveform class]]) {
            [self->_waveformCache.diskCache removeObjectForKey:cacheKey];
            cachedWaveform = nil;
        }
        fromCache = (cachedWaveform != nil);
    }
    if (!cachedWaveform) {
        cachedWaveform = [loader load:track.url.path];
        if (cachedWaveform && loader.isComplete) {
            if (_normalize) {
                cachedWaveform.waveform->normalize();
            }
            if (WAVEFORM_CACHE_ENABLED) {
                [self->_waveformCache.diskCache setObjectAsync:cachedWaveform forKey:cacheKey completion:nil];
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

