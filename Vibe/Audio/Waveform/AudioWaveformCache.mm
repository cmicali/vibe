//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformCache.h"
#import "AudioWaveform.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AVFAudioWaveformLoader.h"

#include <atomic>

#pragma mark - Waveform Cache

#define WAVEFORM_CACHE_ENABLED 1

@interface AudioWaveformCache () <AudioWaveformLoaderDelegate>
@end

@implementation AudioWaveformCache {
    dispatch_queue_t                _loaderQueue;
    PINCache*                       _waveformCache;
    __weak AudioWaveformLoader*     _currentLoader;
    // Bumped by invalidate. A decode captures it when it starts and skips its
    // disk write if it moved — decodes run on a global queue, so an in-flight
    // one could otherwise land its setObjectAsync: after removeAllObjects and
    // repopulate the emptied cache.
    std::atomic<uint64_t>           _cacheGeneration;
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
        _cacheGeneration = 0;
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
        self->_cacheGeneration.fetch_add(1, std::memory_order_relaxed);
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
    // Captured now, not read back at delivery: the BPM delivery carries the
    // URL this waveform was loaded for, so a final delivery that lands after
    // a track change can't be stamped on whatever track is current by then.
    NSURL *url = track.url;
    dispatch_async(_loaderQueue, ^{
        [self load:track withLoader:loader awaitPersist:NO completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
            if (waveform) {
                [self deliverCompleteWaveform:waveform loader:loader url:url];
            }
            // nil (cancelled, failed, or partial): the UI stays at whatever
            // progress the last in-flight loader callback reported.
        }];
    });
}

// Lookup-or-decode core, shared by the delegate delivery path above and the
// debug pre-warm path below. Must be called on _loaderQueue. The completion
// fires exactly once — waveform nil on a cancelled/failed decode, wasCached
// YES on a disk hit — on the loader queue (hit / early-out) or a global
// utility queue (fresh decode). awaitPersist defers a fresh decode's
// completion until the disk write lands (the debug pre-warm's done-means-
// persisted guarantee: `file_cache f && kill` must not lose the entry); the
// delegate path passes NO so UI delivery never queues behind PINDiskCache.
- (void)load:(AudioTrack *)track
  withLoader:(AudioWaveformLoader *)loader
awaitPersist:(BOOL)awaitPersist
  completion:(void (^)(CodableAudioWaveform *waveform, BOOL wasCached))completion {
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
        completion(cachedWaveform, YES);
        return;
    }
    if (loader.isCancelled) {
        completion(nil, NO); // superseded while the cache lookup ran — don't start a decode
        return;
    }
    // Decode OFF this serial queue: AVAudioFile's open has no cancellation
    // point and blocks until a cloud placeholder materializes (minutes) — on
    // this queue that wedged every later track's waveform behind it (the
    // decode loop is cancellable per chunk; the open isn't). Same tradeoff as
    // the player's off-queue open in playOnQueue: a truly hung open strands
    // one global-queue worker instead of the pipeline. Overlap is bounded: a
    // superseded loader aborts at its next chunk check.
    PINCache *cache = _waveformCache; // snapshot: the ivar is confined to _loaderQueue
    uint64_t generation = _cacheGeneration.load(std::memory_order_relaxed);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CodableAudioWaveform *waveform = [loader load:track.url.path];
        if (!waveform || !loader.isComplete) {
            completion(nil, NO); // cancelled, failed, or partial
            return;
        }
        if (WAVEFORM_CACHE_ENABLED &&
            generation == self->_cacheGeneration.load(std::memory_order_relaxed)) {
            // Cache even when cancelled — a completed decode is worth keeping
            // for the next play of this track. Skipped when an invalidate
            // arrived after this decode started: the write would repopulate
            // the just-emptied cache. The completion below is still valid
            // either way — the waveform itself is fine, only the persist is.
            if (awaitPersist) {
                [cache.diskCache setObjectAsync:waveform forKey:cacheKey
                                      completion:^(PINDiskCache *diskCache, NSString *key, id<NSCoding> object) {
                    completion(waveform, NO);
                }];
                return;
            }
            [cache.diskCache setObjectAsync:waveform forKey:cacheKey completion:nil];
        }
        completion(waveform, NO);
    });
}

// Final 100% delivery (progress ticks go straight from the loader to the
// delegate). The waveform is captured strongly so the C++ buffer stays valid
// when the block runs; cancellation is re-checked on the main thread because
// a cancel (new track selected) may land after the block is enqueued.
- (void)deliverCompleteWaveform:(CodableAudioWaveform *)waveform loader:(AudioWaveformLoader *)loader url:(NSURL *)url {
    if (loader.isCancelled) {
        return;
    }
    run_on_main_thread({
        if (!loader.isCancelled) {
            [self.delegate audioWaveform:waveform didLoadData:1];
            // BPM is computed at the end of the decode pass (or carried by a
            // cache hit), so it only ever exists on this final delivery.
            if (waveform.bpm > 0 &&
                [self.delegate respondsToSelector:@selector(audioWaveformCache:didDetectBPM:forURL:)]) {
                [self.delegate audioWaveformCache:self didDetectBPM:waveform.bpm forURL:url];
            }
        }
    });
}

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (!loader.isCancelled) {
        [self.delegate audioWaveform:waveform didLoadData:percentLoaded];
    }
}

#if DEBUG

#pragma mark - Debug: per-file cache control

- (void)cacheWaveformForURL:(NSURL *)url completion:(void (^)(BOOL, BOOL, float))completion {
    AudioTrack *track = [AudioTrack withURL:url];
    // A private loader, never assigned to _currentLoader: the UI's in-flight
    // load isn't cancelled, and no delegate progress/delivery fires — this
    // path reports through the completion instead (typed nil delegate local
    // dodges -Wnonnull).
    id<AudioWaveformLoaderDelegate> noDelegate = nil;
    AudioWaveformLoader *loader = [[AVFAudioWaveformLoader alloc] initWithDelegate:noDelegate];
    dispatch_async(_loaderQueue, ^{
        [self load:track withLoader:loader awaitPersist:YES completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
            float bpm = waveform.bpm; // nil → 0
            run_on_main_thread({ if (completion) completion(waveform != nil, wasCached, bpm); });
        }];
    });
}

- (void)clearCachedWaveformForURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    AudioTrack *track = [AudioTrack withURL:url];
    dispatch_async(_loaderQueue, ^{
        NSString *cacheKey = track.cacheKey;
        BOOL present = [self->_waveformCache.diskCache containsObjectForKey:cacheKey];
        [self->_waveformCache.diskCache removeObjectForKey:cacheKey];
        run_on_main_thread({ if (completion) completion(present); });
    });
}

#endif

@end

