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
#import "AudioFileOpenRules.h"
#import "AudioWorkScheduler.h"

#include <atomic>

#pragma mark - Waveform Cache

@interface VibeWaveformLoadClaim : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) AudioWaveformLoader *loader;
@property (atomic, strong) NSURL *deliveryURL;
@property (nonatomic, strong, nullable) AudioTrack *retryTrack;
// Bumped every time a request parks on this claim, so the wait timeout armed
// for one parked request cannot fire against the next. Main-confined.
@property (nonatomic) NSUInteger retryGeneration;
@property (atomic, strong, nullable) AudioWorkToken *workToken;
@end

@implementation VibeWaveformLoadClaim
@end

@interface AudioWaveformCache () <AudioWaveformLoaderDelegate>
- (void)finishFailedLoader:(AudioWaveformLoader *)loader
                      claim:(VibeWaveformLoadClaim *)claim;
- (void)settleClaim:(VibeWaveformLoadClaim *)claim;
@end

// How many superseded decodes may keep running in the background at once. A
// skip-ahead or a pager peek used to abort the in-flight decode and throw the
// work away; a detached decode completes, persists, and turns the next
// request for that file into a disk hit. Beyond the cap the oldest is
// genuinely cancelled — with the active load this bounds concurrent decodes
// at three.
static const NSUInteger kMaxDetachedWaveformLoads = 2;
static const NSUInteger kMaxPendingWaveformWork = 4;
static const NSTimeInterval kWaveformAdmissionGraceSeconds = 10.0;

// The cache-key stat plus the serial cache lookup. Small and separate from the
// decodes on purpose: a lookup holds its slot across dispatch_sync to the
// loader queue, and a decode is submitted from INSIDE one, so sharing a
// scheduler lets a burst of lookups fill the pending list and reject or expire
// the decode they themselves asked for — reported to the delegate as the file
// failing to load, when nothing about it failed.
static const NSUInteger kMaxRunningWaveformLookups = 2;

// How long a request may sit parked on another request's path claim before the
// UI is told it is not coming. The claim itself is not bounded — its worker may
// be blocked in an uncancellable stat or open for the process's lifetime — but
// the waveform view must not sit in its loading state forever waiting on it.
// Matches the player's own per-file open timeout in spirit: long enough that a
// slow provider still lands, short enough to be an answer.
static const NSTimeInterval kWaveformClaimWaitSeconds = 20.0;

@implementation AudioWaveformCache {
    dispatch_queue_t                _loaderQueue;
    // Two lanes, because the two stages block on different things and must not
    // be able to starve each other. stat and AVAudioFile open have no
    // cancellation point on a wedged mount, so fixed admission slots are the
    // resource bound in both; playback has its own scheduler again.
    AudioWorkScheduler              *_lookupScheduler;   // cache-key stat + cache lookup
    AudioWorkScheduler              *_decodeScheduler;   // AVAudioFile open + decode
    PINCache*                       _waveformCache;
    __weak AudioWaveformLoader*     _currentLoader;
    // The file _currentLoader is decoding, so the progressive deliveries can
    // carry it. Main-thread confined, like _currentLoader itself.
    NSURL*                          _currentLoadURL;
    // Superseded loaders still decoding, oldest first. Main-confined, like
    // _currentLoader: the public load/cancel API runs on the main thread.
    NSMutableArray<AudioWaveformLoader *> *_detachedLoaders;
    // Main-confined single-flight ownership. A loader evicted from the UI's
    // detached pool remains here while its uncancellable worker is executing;
    // same-path requests wait for that claim rather than enqueueing duplicates.
    NSMutableDictionary<NSString *, VibeWaveformLoadClaim *> *_claimsByPath;
    // Bumped by invalidateWithCompletion:. A decode captures it when it
    // starts, skips its disk write if it has moved, and re-checks after the
    // write lands, removing the entry it just wrote if an invalidate raced it.
    // Decodes run on the fixed-slot scheduler, so without this an in-flight one
    // could land its write after removeAllObjects and repopulate the emptied cache.
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
        _lookupScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.waveform.lookup"
                qualityOfService:QOS_CLASS_UTILITY
                maximumRunningCount:kMaxRunningWaveformLookups
                maximumPendingCount:kMaxPendingWaveformWork
                pendingGrace:kWaveformAdmissionGraceSeconds];
        _decodeScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.waveform.decode"
                qualityOfService:QOS_CLASS_UTILITY
                maximumRunningCount:kMaxDetachedWaveformLoads + 1
                maximumPendingCount:kMaxPendingWaveformWork
                pendingGrace:kWaveformAdmissionGraceSeconds];
        _cacheGeneration = 0;
        _currentLoader = nil;
        _detachedLoaders = [NSMutableArray array];
        _claimsByPath = [NSMutableDictionary dictionary];
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
    NSString *path = VibeStandardizedAudioOpenPath(track.url);
    [self detachCurrentLoader];
    VibeWaveformLoadClaim *existing = _claimsByPath[path];
    if (existing) {
        existing.deliveryURL = track.url;
        _currentLoadURL = track.url;
        if (!existing.loader.isCancelled && !existing.loader.isComplete) {
            // A detached decode of this same file resumes delivering instead
            // of racing a second decode: progress picks up at its live point.
            [_detachedLoaders removeObjectIdenticalTo:existing.loader];
            [existing.loader reattach];
            _currentLoader = existing.loader;
        }
        else {
            // Cancellation is permanent on a loader. Park the latest request
            // on its still-running path claim; settleClaim: starts one fresh
            // attempt only after the uncancellable worker really returns.
            existing.retryTrack = track;
            _currentLoader = nil;
            [self armWaitTimeoutForClaim:existing];
        }
        return;
    }
    AudioWaveformLoader *loader = [[AVFAudioWaveformLoader alloc] initWithDelegate:self];
    loader.analysisProvider = self.analysisProvider;
    loader.trackPath = path;
    VibeWaveformLoadClaim *claim = [[VibeWaveformLoadClaim alloc] init];
    claim.path = path;
    claim.loader = loader;
    claim.deliveryURL = track.url;
    _claimsByPath[path] = claim;
    _currentLoader = loader;
    // Captured now rather than read back at delivery. Every delivery carries
    // the URL this waveform was loaded for, so one landing after a track
    // change cannot be stamped on whatever track is current by then.
    NSURL *url = track.url;
    _currentLoadURL = url;
    // The cache key is a file stat, computed off the serial loader queue. A
    // hung network mount could block for minutes and wedge every later track's
    // waveform behind it, which is the same reasoning as the off-queue
    // AVAudioFile open in load:. Out-of-order arrival is safe because each
    // standardized path keeps its claim until the worker settles, while the
    // loader's detached/current state fences UI delivery.
    claim.workToken = [_lookupScheduler submitWork:^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            // The file cannot be statted; see NSURL+Hash. Settle this attempt
            // so a same-file request cannot reattach a loader with no work.
            LogWarn(@"No cache key for %@ — skipping waveform load", url.path);
            [self finishFailedLoader:loader claim:claim];
            [self settleClaim:claim];
            return;
        }
        // Keep this admitted slot through the serial cache lookup. If the
        // local cache itself wedges, at most the scheduler width can wait for
        // it; stats cannot keep feeding an unbounded loader-queue tail.
        dispatch_sync(self->_loaderQueue, ^{
            [self load:track cacheKey:cacheKey withLoader:loader claim:claim
                    awaitPersist:NO completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
                if (waveform) {
                    [self deliverCompleteWaveform:waveform loader:loader claim:claim];
                }
                else if (!loader.isCancelled) {
                    // A failed or partial active load is terminal. Cancellation
                    // means this attempt has already lost ownership and must
                    // not report the superseding request as failed.
                    [self finishFailedLoader:loader claim:claim];
                    return;
                }
                // Finished or cancelled: drop the loader from the detached
                // pool if a later request parked it there.
                run_on_main_thread({
                    [self->_detachedLoaders removeObjectIdenticalTo:loader];
                });
            } settled:^{
                [self settleClaim:claim];
            }];
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        LogWarn(@"Waveform work admission exhausted for %@ (%ld)",
                url.path, (long)failure);
        [self finishFailedLoader:loader claim:claim];
        [self settleClaim:claim];
    }];
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
        // Its claim is the one filed under its own trackPath — the standardized
        // path both were created from. Identity is still checked, because a
        // later request for that path may have settled this claim and filed a
        // new one under the same key.
        VibeWaveformLoadClaim *claim = _claimsByPath[oldest.trackPath];
        if (claim.loader != oldest) {
            claim = nil;
        }
        if ([claim.workToken cancelIfPending]) {
            // It never entered stat/open/decode, and its block was removed
            // from the app-owned pending set without being dispatched.
            [self settleClaim:claim];
        }
    }
}

// A parked request waits on a claim whose worker may be blocked in an
// uncancellable stat or open, which nothing in this process can end. The claim
// stays — that is the whole point, so the path keeps its single owner — but the
// waveform view must not hold its loading state on it indefinitely. After
// kWaveformClaimWaitSeconds the wait, not the claim, is given up: the delegate
// gets its terminal failure and the view leaves the loading state, while the
// worker keeps its slot until it returns and settleClaim: cleans up as usual.
//
// Main thread. The generation is what keeps one parked request's timeout from
// firing against the request that replaced it.
- (void)armWaitTimeoutForClaim:(VibeWaveformLoadClaim *)claim {
    NSUInteger generation = ++claim.retryGeneration;
    NSURL *waitingURL = claim.deliveryURL;
    __weak AudioWaveformCache *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kWaveformClaimWaitSeconds * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
        AudioWaveformCache *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_claimsByPath[claim.path] != claim
                || claim.retryGeneration != generation || !claim.retryTrack) {
            return; // settled, restarted, or superseded by a newer request
        }
        // Only while this parked request is still the one on screen. A track
        // change moved on and took the loading state with it.
        if (![VibeStandardizedAudioOpenPath(strongSelf->_currentLoadURL)
                isEqualToString:claim.path]) {
            return;
        }
        LogWarn(@"Waveform: gave up waiting %.0fs for the in-flight load of %@",
                kWaveformClaimWaitSeconds, claim.path.lastPathComponent);
        // Dropped rather than left parked: the claim outlives this wait, and a
        // retry it started later would deliver a waveform for a track the user
        // has been told has none.
        claim.retryTrack = nil;
        strongSelf->_currentLoadURL = nil;
        if ([strongSelf.delegate respondsToSelector:
                @selector(audioWaveformCache:didFailToLoadForURL:)]) {
            [strongSelf.delegate audioWaveformCache:strongSelf didFailToLoadForURL:waitingURL];
        }
    });
}

// Ends path ownership only when the current worker has settled, or when
// app-owned pending work was removed before dispatch. A same-path request
// which arrived after permanent loader cancellation is restarted exactly once.
- (void)settleClaim:(VibeWaveformLoadClaim *)claim {
    if (!claim) {
        return;
    }
    run_on_main_thread({
        if (self->_claimsByPath[claim.path] != claim) {
            return;
        }
        [self->_claimsByPath removeObjectForKey:claim.path];
        [self->_detachedLoaders removeObjectIdenticalTo:claim.loader];
        claim.workToken = nil;

        AudioTrack *retryTrack = claim.retryTrack;
        BOOL retryIsCurrent = retryTrack
                && [VibeStandardizedAudioOpenPath(self->_currentLoadURL) isEqualToString:claim.path];
        if (retryIsCurrent) {
            [self loadWaveformForTrack:retryTrack];
        }
    });
}

// Makes failure terminal before returning to the main thread. A same-file
// request can race this cleanup; cancellation keeps it from reattaching the
// dead loader, and the identity check keeps a superseding load untouched.
- (void)finishFailedLoader:(AudioWaveformLoader *)loader
                      claim:(VibeWaveformLoadClaim *)claim {
    [loader cancel];
    run_on_main_thread({
        BOOL wasCurrent = self->_currentLoader == loader;
        [self->_detachedLoaders removeObjectIdenticalTo:loader];
        if (!wasCurrent) {
            return;
        }
        self->_currentLoader = nil;
        self->_currentLoadURL = nil;
        if ([self.delegate respondsToSelector:
                @selector(audioWaveformCache:didFailToLoadForURL:)]) {
            [self.delegate audioWaveformCache:self didFailToLoadForURL:claim.deliveryURL];
        }
    });
}

// The lookup-or-decode core, shared by the delegate delivery path above and
// the debug pre-warm path below. It must be called on _loaderQueue, with the
// cache key precomputed off-queue by the caller, since the stat must not block
// this serial queue. The completion fires exactly once — waveform nil on a
// cancelled or failed decode, wasCached YES on a disk hit — either on the
// loader queue, for a hit or an early-out, or on a scheduler worker, for a
// fresh decode. awaitPersist defers a fresh decode's completion until the disk
// write lands, which gives the debug pre-warm its done-means-persisted
// guarantee: `file_cache f && kill` must not lose the entry. The delegate path
// passes NO, so UI delivery never queues behind PINDiskCache.
- (void)load:(AudioTrack *)track
    cacheKey:(NSString *)cacheKey
  withLoader:(AudioWaveformLoader *)loader
       claim:(VibeWaveformLoadClaim *)claim
awaitPersist:(BOOL)awaitPersist
  completion:(void (^)(CodableAudioWaveform *waveform, BOOL wasCached))completion
     settled:(dispatch_block_t)settled {
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
        if (settled) {
            settled();
        }
        return;
    }
    if (loader.isCancelled) {
        completion(nil, NO); // superseded while the cache lookup ran — don't start a decode
        if (settled) {
            settled();
        }
        return;
    }
    // Decode off this serial queue. AVAudioFile's open and the cache-key stat
    // have no cancellation point on a wedged mount, so both use the work
    // scheduler's fixed slots. A blocked file keeps its slot and its same-path
    // loader claim; detached-loader reattachment above therefore never
    // multiplies it.
    PINCache *cache = _waveformCache; // snapshot: the ivar is confined to _loaderQueue
    uint64_t generation = _cacheGeneration.load(std::memory_order_relaxed);
    AudioWorkToken *decodeToken = [_decodeScheduler submitWork:^{
        CodableAudioWaveform *waveform = [loader load:track.url.path];
        if (!waveform || !loader.isComplete) {
            completion(nil, NO); // cancelled, failed, or partial
            if (settled) {
                settled();
            }
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
        if (settled) {
            settled();
        }
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        LogWarn(@"Waveform decode admission exhausted for %@ (%ld)",
                track.url.path, (long)failure);
        completion(nil, NO);
        if (settled) {
            settled();
        }
    }];
    claim.workToken = decodeToken;
    // A cancel landing between the check above and here leaves a pending decode
    // nothing wants. Removing it while it is still app-owned releases the
    // loader and the track it captured immediately; once it is running, it owns
    // its own cancellation checks and settles normally.
    if (loader.isCancelled && [decodeToken cancelIfPending]) {
        completion(nil, NO);
        if (settled) {
            settled();
        }
    }
}

// The final, 100% delivery; progress ticks go straight from the loader to the
// delegate. The waveform is captured strongly so that the C++ buffer stays
// valid when the block runs, and cancellation is re-checked on the main
// thread, because a cancel from a newly selected track may land after the
// block is enqueued.
- (void)deliverCompleteWaveform:(CodableAudioWaveform *)waveform
                         loader:(AudioWaveformLoader *)loader
                          claim:(VibeWaveformLoadClaim *)claim {
    run_on_main_thread({
        NSURL *url = claim.deliveryURL;
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
    loader.analysisProvider = self.analysisProvider;
    // The key is computed off the loader queue; see loadWaveformForTrack:.
    [_lookupScheduler submitWork:^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            LogWarn(@"No cache key for %@ — cannot cache waveform", url.path);
            run_on_main_thread({ if (completion) completion(NO, NO, 0, -1); });
            return;
        }
        dispatch_sync(self->_loaderQueue, ^{
            [self load:track cacheKey:cacheKey withLoader:loader claim:nil
                    awaitPersist:YES completion:^(CodableAudioWaveform *waveform, BOOL wasCached) {
                float bpm = waveform.bpm; // nil → 0
                // Explicitly -1 for nil: messaging nil returns 0, which as a
                // key would read as C major.
                NSInteger key = waveform ? waveform.key : -1;
                run_on_main_thread({ if (completion) completion(waveform != nil, wasCached, bpm, key); });
            } settled:nil];
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        LogWarn(@"Waveform cache admission exhausted for %@ (%ld)",
                url.path, (long)failure);
        if (completion) completion(NO, NO, 0, -1);
    }];
}

- (void)clearCachedWaveformForURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    AudioTrack *track = [AudioTrack withURL:url];
    // The key is computed off the loader queue; see loadWaveformForTrack:.
    [_lookupScheduler submitWork:^{
        NSString *cacheKey = track.cacheKey;
        if (!cacheKey) {
            // The file cannot be statted, so its entry cannot be resolved
            // anyway: the key derives from the current size and mtime.
            LogWarn(@"No cache key for %@ — cannot clear waveform entry", url.path);
            run_on_main_thread({ if (completion) completion(NO); });
            return;
        }
        dispatch_sync(self->_loaderQueue, ^{
            BOOL present = [self->_waveformCache.diskCache containsObjectForKey:cacheKey];
            [self->_waveformCache.diskCache removeObjectForKey:cacheKey];
            run_on_main_thread({ if (completion) completion(present); });
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        LogWarn(@"Waveform clear admission exhausted for %@ (%ld)",
                url.path, (long)failure);
        if (completion) completion(NO);
    }];
}

#endif

@end
