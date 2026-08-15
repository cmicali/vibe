//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformCache.h"
#import "AudioWaveform.h"
#import "PINCache.h"
#import "PINCache+VibeAudioCache.h"
#import "AudioTrack.h"
#import "AVFAudioWaveformLoader.h"

#include <atomic>

#pragma mark - Waveform Cache

@interface AudioWaveformCache () <AudioWaveformLoaderDelegate>
@end

// How many superseded decodes may keep running in the background at once. A
// skip-ahead or a pager peek used to abort the in-flight decode and throw the
// work away; a detached decode completes, persists, and turns the next
// request for that file into a disk hit. Beyond the cap the oldest is
// genuinely cancelled — with the active load this bounds concurrent decodes
// at three.
static const NSUInteger kMaxDetachedWaveformLoads = 2;

@implementation AudioWaveformCache {
    dispatch_queue_t                _loaderQueue;
    PINCache*                       _waveformCache;
    __weak AudioWaveformLoader*     _currentLoader;
    // The file _currentLoader is decoding, so the progressive deliveries can
    // carry it. Main-thread confined, like _currentLoader itself.
    NSURL*                          _currentLoadURL;
    // Superseded loaders still decoding, oldest first. Main-confined, like
    // _currentLoader: the public load/cancel API runs on the main thread.
    NSMutableArray<AudioWaveformLoader *> *_detachedLoaders;
    // Bumped by invalidateWithCompletion:. A decode captures it when it
    // starts, skips its disk write if it has moved, and re-checks after the
    // write lands, removing the entry it just wrote if an invalidate raced it.
    // Decodes run on a global queue, so without this an in-flight one could
    // land its write after removeAllObjects and repopulate the emptied cache.
    std::atomic<uint64_t>           _cacheGeneration;
}

+ (NSString *)cacheName {
    // The name embeds the entry format version, so a version bump renames the
    // cache and unreadable older entries waiting for LRU eviction do not
    // consume the byte budget.
    return [NSString stringWithFormat:@"audio_waveform_cache_v%d",
                                      kCodableAudioWaveformVersion];
}

- (id)init {
    self = [super init];
    if (self) {
        // Utility, not user-initiated. The loader blocks on PINCache's own
        // utility-QoS queues, through a synchronous objectForKey:, and a
        // higher class here merely trips the Thread Performance Checker's
        // priority-inversion warning while stealing P-core time from the start
        // of playback.
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _loaderQueue = dispatch_queue_create("AudioWaveformCache", queueAttributes);
        _cacheGeneration = 0;
        _currentLoader = nil;
        _detachedLoaders = [NSMutableArray array];
        // Create the cache on the loader queue. Constructing it on the main
        // thread would boost PINCache's internal init-time disk scan to
        // user-initiated QoS, which then priority-inverts against our
        // utility-QoS cache calls, and the Thread Performance Checker warns
        // about it on the first drop. The _waveformCache ivar is only ever
        // read on this serial queue — decode-side writes go through a pointer
        // snapshotted here, and PINCache itself is thread-safe — so it is
        // always constructed before first use.
        dispatch_async(_loaderQueue, ^{
            // Why the memory cache goes unused is with the shared policy. The
            // view retains the one live waveform, and a replay re-reads from
            // disk in a few ms on this utility queue.
            self->_waveformCache = [PINCache audioCacheWithName:AudioWaveformCache.cacheName];
        });
    }
    return self;
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

- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion {
    // The serial queue guarantees the cache exists and keeps the blocking
    // enumeration off the caller's thread.
    dispatch_async(_loaderQueue, ^{
        [self->_waveformCache audioDiskUsageWithCompletion:completion];
    });
}

- (void)loadWaveformForTrack:(AudioTrack *)track {
    NSString *path = track.url.path;
    [self detachCurrentLoader];
    // A detached decode of this same file resumes delivering instead of
    // racing a second decode of it: progress ticks pick up at the decode's
    // live position, and the final delivery flows through its original
    // completion.
    for (AudioWaveformLoader *candidate in _detachedLoaders) {
        if (!candidate.isCancelled && !candidate.isComplete
                && [candidate.trackPath isEqualToString:path]) {
            [_detachedLoaders removeObjectIdenticalTo:candidate];
            [candidate reattach];
            _currentLoader = candidate;
            // The reattached decode delivers from here on, so it must deliver
            // under this track's URL and not the one it was detached from.
            _currentLoadURL = track.url;
            return;
        }
    }
    AudioWaveformLoader *loader = [[AVFAudioWaveformLoader alloc] initWithDelegate:self];
    loader.trackPath = path;
    _currentLoader = loader;
    // Captured now rather than read back at delivery. Every delivery carries
    // the URL this waveform was loaded for, so one landing after a track
    // change cannot be stamped on whatever track is current by then.
    NSURL *url = track.url;
    _currentLoadURL = url;
    // The cache key is a file stat, computed off the serial loader queue. A
    // hung network mount could block for minutes and wedge every later track's
    // waveform behind it, which is the same reasoning as the off-queue
    // AVAudioFile open in load:. Out-of-order arrival is fine, because a
    // superseded loader was already cancelled above and its work no-ops.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            // The file cannot be statted; see NSURL+Hash. Skip the load: the
            // view keeps what it shows, and the next play retries.
            LogWarn(@"No cache key for %@ — skipping waveform load", url.path);
            return;
        }
        dispatch_async(self->_loaderQueue, ^{
            [self load:track cacheKey:cacheKey withLoader:loader awaitPersist:NO completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
                if (waveform) {
                    [self deliverCompleteWaveform:waveform loader:loader url:url];
                }
                // nil, meaning cancelled, failed or partial. The UI stays at
                // whatever progress the last in-flight loader callback
                // reported.
                //
                // Finished either way: drop the loader from the detached pool
                // if a later request parked it there.
                run_on_main_thread({
                    [self->_detachedLoaders removeObjectIdenticalTo:loader];
                });
            }];
        });
    });
}

- (void)cancelLoad {
    [self detachCurrentLoader];
}

// Supersedes the active load WITHOUT aborting it: the decode runs on
// detached — deliveries stop, but a completed decode still persists, so the
// next request for that file is a disk hit instead of a re-decode. Beyond
// the cap the oldest detached decode is cancelled outright.
- (void)detachCurrentLoader {
    AudioWaveformLoader *loader = _currentLoader;
    _currentLoader = nil;
    _currentLoadURL = nil;
    if (!loader || loader.isCancelled) {
        return;
    }
    // Detach even a completed loader: isComplete is set on the decode thread
    // BEFORE its final delivery block reaches the main queue, so "complete"
    // can still have a live delivery in flight, and the detach flag is what
    // deliverCompleteWaveform checks on main. Skipping the detach here let
    // that delivery land as a live one on whatever track superseded it.
    [loader detach];
    if (loader.isComplete) {
        return; // nothing to pool — the decode is done and persists on its own
    }
    [_detachedLoaders addObject:loader];
    while (_detachedLoaders.count > kMaxDetachedWaveformLoads) {
        AudioWaveformLoader *oldest = _detachedLoaders.firstObject;
        [oldest cancel];
        [_detachedLoaders removeObjectAtIndex:0];
    }
}

// The lookup-or-decode core, shared by the delegate delivery path above and
// the debug pre-warm path below. It must be called on _loaderQueue, with the
// cache key precomputed off-queue by the caller, since the stat must not block
// this serial queue. The completion fires exactly once — waveform nil on a
// cancelled or failed decode, wasCached YES on a disk hit — either on the
// loader queue, for a hit or an early-out, or on a global utility queue, for a
// fresh decode. awaitPersist defers a fresh decode's completion until the disk
// write lands, which gives the debug pre-warm its done-means-persisted
// guarantee: `file_cache f && kill` must not lose the entry. The delegate path
// passes NO, so UI delivery never queues behind PINDiskCache.
- (void)load:(AudioTrack *)track
    cacheKey:(NSString *)cacheKey
  withLoader:(AudioWaveformLoader *)loader
awaitPersist:(BOOL)awaitPersist
  completion:(void (^)(CodableAudioWaveform *waveform, BOOL wasCached))completion {
    CodableAudioWaveform *cachedWaveform =
            (CodableAudioWaveform *)[self->_waveformCache.diskCache objectForKey:cacheKey];
    // PINCache unarchives without secure coding, so a corrupt or tampered
    // entry with a different root class decodes cleanly and would crash with
    // an unrecognized selector at first use — on every play of this track,
    // since nothing would ever evict it. The metadata cache uses the same
    // guard.
    if (cachedWaveform && ![cachedWaveform isKindOfClass:[CodableAudioWaveform class]]) {
        [self->_waveformCache.diskCache removeObjectForKey:cacheKey];
        cachedWaveform = nil;
    }
    if (cachedWaveform) {
        // A hit finishes this loader as surely as a decode does; without the
        // mark, a detach pools it and a same-file re-request reattaches a
        // loader that will never deliver again.
        loader.isComplete = YES;
        completion(cachedWaveform, YES);
        return;
    }
    if (loader.isCancelled) {
        completion(nil, NO); // superseded while the cache lookup ran — don't start a decode
        return;
    }
    // Decode off this serial queue. AVAudioFile's open has no cancellation
    // point and blocks for minutes until a cloud placeholder materializes; on
    // this queue that would wedge every later track's waveform behind it. The
    // decode loop is cancellable per chunk, but the open is not. It is the
    // same tradeoff as the player's off-queue open in playOnQueue:, where a
    // truly hung open strands one global-queue worker rather than the
    // pipeline. Overlap is bounded, because a superseded loader aborts at its
    // next chunk check.
    PINCache *cache = _waveformCache; // snapshot: the ivar is confined to _loaderQueue
    uint64_t generation = _cacheGeneration.load(std::memory_order_relaxed);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CodableAudioWaveform *waveform = [loader load:track.url.path];
        if (!waveform || !loader.isComplete) {
            completion(nil, NO); // cancelled, failed, or partial
            return;
        }
        if (!awaitPersist) {
            // Deliver before persisting, so UI delivery never queues behind
            // PINDiskCache. The waveform is valid whatever the persist below
            // decides.
            completion(waveform, NO);
        }
        // Cache even when cancelled: a completed decode is worth keeping for
        // the next play of this track. It is skipped when an invalidate
        // arrived after this decode started, since the write would repopulate
        // the just-emptied cache. The write is synchronous and the generation
        // is re-checked after it lands, because removeAllObjects takes
        // PINDiskCache's lock directly rather than queueing behind pending
        // writes, so an invalidate can slip between the check and the write.
        // The compensating remove is what makes the header's
        // cannot-repopulate guarantee hold.
        if (generation == self->_cacheGeneration.load(std::memory_order_relaxed)) {
            [cache.diskCache setObject:waveform forKey:cacheKey];
            if (generation != self->_cacheGeneration.load(std::memory_order_relaxed)) {
                [cache.diskCache removeObjectForKey:cacheKey];
            }
        }
        if (awaitPersist) {
            completion(waveform, NO);
        }
    });
}

// The final, 100% delivery; progress ticks go straight from the loader to the
// delegate. The waveform is captured strongly so that the C++ buffer stays
// valid when the block runs, and cancellation is re-checked on the main
// thread, because a cancel from a newly selected track may land after the
// block is enqueued.
- (void)deliverCompleteWaveform:(CodableAudioWaveform *)waveform loader:(AudioWaveformLoader *)loader url:(NSURL *)url {
    if ((loader.isCancelled || loader.isDetached) && waveform.bpm <= 0 && waveform.key < 0) {
        return;
    }
    run_on_main_thread({
        // Detached is checked here, on delivery, not at enqueue: a reattach
        // that lands first correctly turns this back into a live delivery.
        if (!loader.isCancelled && !loader.isDetached) {
            [self.delegate audioWaveform:waveform didLoadData:1 forURL:url];
        }
        // The BPM and key are computed at the end of the decode pass, or
        // carried by a cache hit, so they only ever exist on this final
        // delivery. They are delivered even when the load was cancelled: a
        // cancelled but complete decode still persisted values valid for its
        // file, and the delegate matches the URL against its playlist rather
        // than the current track. Dropping them here would leave the analyzed
        // track without them until its next play, purely because the cancel
        // won a race.
        if (waveform.bpm > 0 &&
            [self.delegate respondsToSelector:@selector(audioWaveformCache:didDetectBPM:forURL:)]) {
            [self.delegate audioWaveformCache:self didDetectBPM:waveform.bpm forURL:url];
        }
        if (waveform.key >= 0 &&
            [self.delegate respondsToSelector:@selector(audioWaveformCache:didDetectKey:forURL:)]) {
            [self.delegate audioWaveformCache:self didDetectKey:waveform.key forURL:url];
        }
    });
}

// On the main thread, from the loader's throttled progress callback. A new
// load cancels the old loader before taking _currentLoadURL, so the URL here
// always belongs to the loader that is still delivering.
- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (!loader.isCancelled && !loader.isDetached && _currentLoadURL) {
        [self.delegate audioWaveform:waveform didLoadData:percentLoaded forURL:_currentLoadURL];
    }
}

#if DEBUG

#pragma mark - Debug: per-file cache control

- (void)cacheWaveformForURL:(NSURL *)url completion:(void (^)(BOOL, BOOL, float, NSInteger))completion {
    AudioTrack *track = [AudioTrack withURL:url];
    // A private loader, never assigned to _currentLoader. The UI's in-flight
    // load is not cancelled, and no delegate progress or delivery fires; this
    // path reports through the completion instead. The typed nil delegate
    // local dodges -Wnonnull.
    id<AudioWaveformLoaderDelegate> noDelegate = nil;
    AudioWaveformLoader *loader = [[AVFAudioWaveformLoader alloc] initWithDelegate:noDelegate];
    // The key is computed off the loader queue; see loadWaveformForTrack:.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            LogWarn(@"No cache key for %@ — cannot cache waveform", url.path);
            run_on_main_thread({ if (completion) completion(NO, NO, 0, -1); });
            return;
        }
        dispatch_async(self->_loaderQueue, ^{
            [self load:track cacheKey:cacheKey withLoader:loader awaitPersist:YES completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
                float bpm = waveform.bpm; // nil → 0
                // Explicitly -1 for nil: messaging nil returns 0, which as a
                // key would read as C major.
                NSInteger key = waveform ? waveform.key : -1;
                run_on_main_thread({ if (completion) completion(waveform != nil, wasCached, bpm, key); });
            }];
        });
    });
}

- (void)clearCachedWaveformForURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    AudioTrack *track = [AudioTrack withURL:url];
    // The key is computed off the loader queue; see loadWaveformForTrack:.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            // The file cannot be statted, so its entry cannot be resolved
            // anyway: the key derives from the current size and mtime.
            LogWarn(@"No cache key for %@ — cannot clear waveform entry", url.path);
            run_on_main_thread({ if (completion) completion(NO); });
            return;
        }
        dispatch_async(self->_loaderQueue, ^{
            BOOL present = [self->_waveformCache.diskCache containsObjectForKey:cacheKey];
            [self->_waveformCache.diskCache removeObjectForKey:cacheKey];
            run_on_main_thread({ if (completion) completion(present); });
        });
    });
}

#endif

@end

