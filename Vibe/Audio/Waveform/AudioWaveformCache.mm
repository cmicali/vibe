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
        // first drop). The _waveformCache ivar is only ever read on this
        // serial queue (decode-side writes go through a pointer snapshotted
        // here; PINCache itself is thread-safe), so it is always constructed
        // before first use.
        dispatch_async(_loaderQueue, ^{
            // v4 (BPM analyzer fix): entries carry a format version key;
            // renamed so the budget isn't consumed by unreadable
            // older-version entries waiting for LRU eviction.
            self->_waveformCache = [[PINCache alloc] initWithName:@"audio_waveform_cache_v4"];
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
    [self invalidateWithCompletion:nil];
}

- (void)invalidateWithCompletion:(dispatch_block_t)completion {
    dispatch_async(_loaderQueue, ^{
        [self->_waveformCache removeAllObjects];
        if (completion) {
            completion();
        }
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
    }
    if (cachedWaveform) {
        [self deliverCompleteWaveform:cachedWaveform loader:loader];
        return;
    }
    if (loader.isCancelled) {
        return; // superseded while the cache lookup ran — don't start a decode
    }
    // Decode OFF this serial queue: AVAudioFile's open has no cancellation
    // point and blocks until a cloud placeholder materializes (minutes) — on
    // this queue that wedged every later track's waveform behind it (the
    // decode loop is cancellable per chunk; the open isn't). Same tradeoff as
    // the player's off-queue open in playOnQueue: a truly hung open strands
    // one global-queue worker instead of the pipeline. Overlap is bounded: a
    // superseded loader aborts at its next chunk check.
    PINCache *cache = _waveformCache; // snapshot: the ivar is confined to _loaderQueue
    BOOL normalize = _normalize;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CodableAudioWaveform *waveform = [loader load:track.url.path];
        if (!waveform || !loader.isComplete) {
            // Cancelled, failed, or partial: the UI stays at whatever progress
            // the last in-flight callback reported.
            return;
        }
        if (normalize) {
            waveform.waveform->normalize();
        }
        if (WAVEFORM_CACHE_ENABLED) {
            // Cache even when cancelled — a completed decode is worth keeping
            // for the next play of this track.
            [cache.diskCache setObjectAsync:waveform forKey:cacheKey completion:nil];
        }
        [self deliverCompleteWaveform:waveform loader:loader];
    });
}

// Final 100% delivery (progress ticks go straight from the loader to the
// delegate). The waveform is captured strongly so the C++ buffer stays valid
// when the block runs; cancellation is re-checked on the main thread because
// a cancel (new track selected) may land after the block is enqueued.
- (void)deliverCompleteWaveform:(CodableAudioWaveform *)waveform loader:(AudioWaveformLoader *)loader {
    if (loader.isCancelled) {
        return;
    }
    run_on_main_thread({
        if (!loader.isCancelled) {
            [self.delegate audioWaveform:waveform didLoadData:1];
            // BPM is computed at the end of the decode pass (or carried by a
            // cache hit), so it only ever exists on this final delivery.
            if (waveform.bpm > 0 &&
                [self.delegate respondsToSelector:@selector(audioWaveformCache:didDetectBPM:)]) {
                [self.delegate audioWaveformCache:self didDetectBPM:waveform.bpm];
            }
        }
    });
}

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (!loader.isCancelled) {
        [self.delegate audioWaveform:waveform didLoadData:percentLoaded];
    }
}

@end

