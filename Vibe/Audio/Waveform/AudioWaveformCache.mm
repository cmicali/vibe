//
//  AudioWaveformCache.mm
//  Vibe
//

#import "AudioWaveformCacheInternal.h"
#import "FilePaths.h"
#import "AudioWaveform.h"
#import "PINCache.h"
#import "PINCache+VibeAudioCache.h"
#import "AudioWaveformLoader.h"
#import "AudioWorkScheduler.h"
#import "PlaceholderFiles.h"

#include <atomic>

#pragma mark - Waveform Cache

@interface VibeWaveformLoadClaim : NSObject
// The standardized path, plus the window for a cue row: one decode per window.
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) AudioWaveformLoader *loader;
@property (atomic, strong) id<VibePlayableItem> deliveryTrack;
@property (nonatomic, strong, nullable) id<VibePlayableItem> retryTrack;
// Bumped every time a request parks on this claim, so the wait timeout armed
// for one parked request cannot fire against the next. Main-confined.
@property (nonatomic) NSUInteger retryGeneration;
@property (atomic, strong, nullable) AudioWorkToken *workToken;
@end

@implementation VibeWaveformLoadClaim
@end

// A claim's key. The standardized path joins a provider's other spelling of
// the file, and the window keeps the windows of one file apart.
static NSString *VibeWaveformClaimKey(id<VibePlayableItem> track) {
    return VibeKeyByAppendingCueWindow(VibeStandardizedAudioOpenPath(track.url), track.cueStart, track.cueEnd);
}

@interface AudioWaveformCache () <AudioWaveformLoaderDelegate>
- (void)finishFailedLoader:(AudioWaveformLoader *)loader
                      claim:(VibeWaveformLoadClaim *)claim;
- (void)settleClaim:(VibeWaveformLoadClaim *)claim;
@end

// How many superseded decodes may keep running in the background at once: a
// detached decode completes, persists, and turns the next request for that
// file into a disk hit. Beyond the cap the oldest is cancelled — with the
// active load this bounds concurrent decodes at three.
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
// Long enough that a slow provider still lands, short enough to be an answer.
static const NSTimeInterval kWaveformClaimWaitSeconds = 20.0;

@implementation AudioWaveformCache {
    __weak AudioWaveformLoader*     _currentLoader;
    // The track _currentLoader is decoding for, so the progressive deliveries
    // can carry it. Main-thread confined, like _currentLoader itself.
    id<VibePlayableItem>            _currentLoadTrack;
    // Superseded loaders still decoding, oldest first. Main-confined, like
    // _currentLoader: the public load/cancel API runs on the main thread.
    NSMutableArray<AudioWaveformLoader *> *_detachedLoaders;
    // Main-confined single-flight ownership. A loader evicted from the UI's
    // detached pool remains here while its uncancellable worker is executing;
    // same-path requests wait for that claim rather than enqueueing duplicates.
    NSMutableDictionary<NSString *, VibeWaveformLoadClaim *> *_claimsByKey;
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
    return [self initWithRootPath:nil];
}

- (instancetype)initWithRootPath:(NSString *)rootPath {
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
        // A neighbor's wedged stat must never hold the playing lookup's slots.
        _previewScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.waveform.preview"
                qualityOfService:QOS_CLASS_UTILITY
                maximumRunningCount:1
                maximumPendingCount:2
                pendingGrace:kWaveformAdmissionGraceSeconds];
        _detailScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.waveform.detail"
                qualityOfService:QOS_CLASS_UTILITY
                maximumRunningCount:1
                maximumPendingCount:1
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
        _claimsByKey = [NSMutableDictionary dictionary];
        // Created on the loader queue: on main, PINCache's init-time disk scan
        // would run at user-initiated QoS and priority-invert against the
        // utility-QoS cache calls. The ivar is read only on this serial queue,
        // so it exists before first use; decode-side writes go through a
        // pointer snapshotted here.
        dispatch_async(_loaderQueue, ^{
            // Views retain their live waveforms. Replays read the disk cache
            // without pinning every entry in PINMemoryCache.
            self->_waveformCache = [PINCache audioCacheWithName:AudioWaveformCache.cacheName rootPath:rootPath];
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

- (void)loadWaveformForTrack:(id<VibePlayableItem>)track {
    NSString *key = VibeWaveformClaimKey(track);
    // On main, so a provider reading main-confined settings (the mac's theme)
    // is never called off it.
    VibeWaveformAnalysis analysis = self.analysisProvider ? self.analysisProvider() : (VibeWaveformAnalysis){};
    [self detachCurrentLoader];
    VibeWaveformLoadClaim *existing = _claimsByKey[key];
    if (existing) {
        existing.deliveryTrack = track;
        _currentLoadTrack = track;
        // A decode without the bands or an observer this request asks for,
        // as when 3-Band is chosen or detection turned on mid-load, is stopped
        // rather than reattached or waited out: it would persist an entry this
        // very request misses on.
        VibeWaveformAnalysis running = existing.loader.analysis;
        BOOL answers = VibeWaveformAnalysisCovers(running.bands, VibeWaveformObserverIdentifiers(running), analysis);
        if (!answers) {
            [existing.loader cancel];
        }
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
            if (!answers && [existing.workToken cancelIfPending]) {
                [self settleClaim:existing];
            }
        }
        return;
    }
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] initWithDelegate:self];
    loader.analysis = analysis;
    loader.claimKey = key;
    loader.cueStart = track.cueStart;
    loader.cueEnd = track.cueEnd;
    VibeWaveformLoadClaim *claim = [[VibeWaveformLoadClaim alloc] init];
    claim.key = key;
    claim.loader = loader;
    claim.deliveryTrack = track;
    _claimsByKey[key] = claim;
    _currentLoader = loader;
    // Captured now rather than read back at delivery. Every delivery carries
    // the track this waveform was loaded for, so one landing after a track
    // change cannot be stamped on whatever track is current by then.
    NSURL *url = track.url;
    _currentLoadTrack = track;
    // The cache key is a file stat, computed off the serial loader queue. A
    // hung network mount could block for minutes and wedge every later track's
    // waveform behind it, which is the same reasoning as the off-queue
    // AudioFileHandle open in load:. Out-of-order arrival is safe because each
    // standardized path keeps its claim until the worker settles, while the
    // loader's detached/current state fences UI delivery.
    claim.workToken = [_lookupScheduler submitWork:^{
        // Per window: a cue row's waveform, tempo and key are its own.
        NSString *cacheKey = VibeKeyByAppendingCueWindow(track.cacheKey, track.cueStart, track.cueEnd);
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

// Called on the serial loader queue by both cache readers.
- (CodableAudioWaveform *)waveformForCacheKey:(NSString *)cacheKey
                                  analysis:(VibeWaveformAnalysis)analysis {
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
    // An entry decoded without the bands, or without a result for an
    // observer this request lists, is a miss for it, and that decode replaces
    // it with one that has them. Every other request takes it, so no entry is
    // ever invalidated for what it lacks.
    if (cachedWaveform && !VibeWaveformAnalysisCovers(cachedWaveform.waveform->hasBands(),
                                                      cachedWaveform.results.allKeys, analysis)) {
        cachedWaveform = nil;
    }
    return cachedWaveform;
}

- (AudioWorkToken *)cachedWaveformForTrack:(id<VibePlayableItem>)track
                   completion:(void (^)(CodableAudioWaveform *))completion {
    VibeWaveformAnalysis analysis = self.analysisProvider ? self.analysisProvider() : (VibeWaveformAnalysis){};
    uint64_t generation = _cacheGeneration.load(std::memory_order_relaxed);
    return [_previewScheduler submitWork:^{
        NSString *cacheKey = VibeKeyByAppendingCueWindow(track.cacheKey, track.cueStart, track.cueEnd);
        __block CodableAudioWaveform *waveform = nil;
        if (cacheKey) {
            dispatch_sync(self->_loaderQueue, ^{
                waveform = [self waveformForCacheKey:cacheKey analysis:analysis];
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL current = generation == self->_cacheGeneration.load(std::memory_order_relaxed);
            completion(current ? waveform : nil);
            if (current && waveform) {
                [self deliverResults:waveform forTrack:track];
            }
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        completion(nil);
    }];
}

- (AudioWorkToken *)loadDetailBlocks:(NSIndexSet *)blocks
                            forTrack:(id<VibePlayableItem>)track
                            waveform:(CodableAudioWaveform *)waveform
                          completion:(dispatch_block_t)completion {
    NSURL *url = track.url;
    NSUInteger cueStart = track.cueStart, cueEnd = track.cueEnd;
    blocks = [blocks copy];
    return [_detailScheduler submitWork:^{
        // A stat, on this lane: it can wait on a provider. A remote
        // placeholder answers dataless too.
        if (url && ![PlaceholderFiles isDatalessFile:url]) {
            AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] initWithDelegate:self];
            loader.cueStart = cueStart;
            loader.cueEnd = cueEnd;
            [loader loadDetailBlocks:blocks ofFile:url.path intoWaveform:waveform];
        }
        dispatch_async(dispatch_get_main_queue(), completion);
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        completion();
    }];
}

- (void)cancelLoad {
    [self detachCurrentLoader];
}

// Supersedes the active load without aborting it; see cancelLoad.
- (void)detachCurrentLoader {
    AudioWaveformLoader *loader = _currentLoader;
    _currentLoader = nil;
    _currentLoadTrack = nil;
    if (!loader || loader.isCancelled) {
        return;
    }
    // TRAP: detach even a completed loader. isComplete is set on the decode
    // thread BEFORE its final delivery reaches main, where
    // deliverCompleteWaveform checks the detach flag; skipped, that delivery
    // lands live on whatever track superseded it.
    [loader detach];
    if (loader.isComplete) {
        return; // nothing to pool — the decode is done and persists on its own
    }
    [_detachedLoaders addObject:loader];
    while (_detachedLoaders.count > kMaxDetachedWaveformLoads) {
        AudioWaveformLoader *oldest = _detachedLoaders.firstObject;
        [oldest cancel];
        [_detachedLoaders removeObjectAtIndex:0];
        // Its claim is the one filed under its own claimKey — the key both
        // were created from. Identity is still checked, because a later
        // request for that key may have settled this claim and filed a new
        // one under it.
        VibeWaveformLoadClaim *claim = _claimsByKey[oldest.claimKey];
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
    id<VibePlayableItem> waitingTrack = claim.deliveryTrack;
    __weak AudioWaveformCache *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kWaveformClaimWaitSeconds * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
        AudioWaveformCache *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_claimsByKey[claim.key] != claim
                || claim.retryGeneration != generation || !claim.retryTrack) {
            return; // settled, restarted, or superseded by a newer request
        }
        // Only while this parked request is still the one on screen. A track
        // change moved on and took the loading state with it.
        id<VibePlayableItem> current = strongSelf->_currentLoadTrack;
        if (!current || ![VibeWaveformClaimKey(current) isEqualToString:claim.key]) {
            return;
        }
        LogWarn(@"Waveform: gave up waiting %.0fs for the in-flight load of %@",
                kWaveformClaimWaitSeconds, claim.key.lastPathComponent);
        // Dropped rather than left parked: the claim outlives this wait, and a
        // retry it started later would deliver a waveform for a track the user
        // has been told has none.
        claim.retryTrack = nil;
        strongSelf->_currentLoadTrack = nil;
        if ([strongSelf.delegate respondsToSelector:
                @selector(audioWaveformCache:didFailToLoadForTrack:)]) {
            [strongSelf.delegate audioWaveformCache:strongSelf didFailToLoadForTrack:waitingTrack];
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
        if (self->_claimsByKey[claim.key] != claim) {
            return;
        }
        [self->_claimsByKey removeObjectForKey:claim.key];
        [self->_detachedLoaders removeObjectIdenticalTo:claim.loader];
        claim.workToken = nil;

        id<VibePlayableItem> retryTrack = claim.retryTrack;
        id<VibePlayableItem> current = self->_currentLoadTrack;
        BOOL retryIsCurrent = retryTrack && current
                && [VibeWaveformClaimKey(current) isEqualToString:claim.key];
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
        self->_currentLoadTrack = nil;
        if ([self.delegate respondsToSelector:
                @selector(audioWaveformCache:didFailToLoadForTrack:)]) {
            [self.delegate audioWaveformCache:self didFailToLoadForTrack:claim.deliveryTrack];
        }
    });
}

// The lookup-or-decode core, shared by the delegate delivery path above and
// the debug pre-warm path (AudioWaveformCache+Debug.mm). It must be called on
// _loaderQueue, with the cache key precomputed off-queue by the caller, since
// the stat must not block this serial queue. A hit or early-out completes on
// this queue; a decode completes on its worker; admission failure runs on
// main. A caller that removes pending work owns its settlement. nil means
// failed, cancelled, or decoded from another version than cacheKey names, and
// wasCached marks a disk hit. awaitPersist waits for
// the cache-write attempt before completion. Invalidation can suppress it.
// The delegate path passes NO to deliver before that write.
- (void)load:(id<VibePlayableItem>)track
    cacheKey:(NSString *)cacheKey
  withLoader:(AudioWaveformLoader *)loader
       claim:(VibeWaveformLoadClaim *)claim
awaitPersist:(BOOL)awaitPersist
  completion:(void (^)(CodableAudioWaveform *waveform, BOOL wasCached))completion
     settled:(dispatch_block_t)settled {
    CodableAudioWaveform *cachedWaveform = [self waveformForCacheKey:cacheKey analysis:loader.analysis];
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
    // Decode off this serial queue. AudioFileHandle's open and the cache-key stat
    // have no cancellation point on a wedged mount, so both use the work
    // scheduler's fixed slots. A blocked file keeps its slot and its same-path
    // loader claim; detached-loader reattachment above therefore never
    // multiplies it.
    PINCache *cache = _waveformCache; // snapshot: the ivar is confined to _loaderQueue
    uint64_t generation = _cacheGeneration.load(std::memory_order_relaxed);
    AudioWorkToken *decodeToken = [_decodeScheduler submitWork:^{
        CodableAudioWaveform *waveform = [loader load:track.url.path];
        // TRAP: the version is checked here, at completion, never at the
        // decode's start. The key was taken before the open, and a download
        // can install another version while this decode reads it. The re-key
        // has retired the item's memo by now, so its key names the version
        // the file holds. A stale result is neither filed nor delivered,
        // since its bytes may be either version's. A current load decodes
        // once more under the new key, through the claim's retry.
        BOOL stale = waveform && loader.isComplete
                && ![VibeKeyByAppendingCueWindow(track.cacheKey, track.cueStart, track.cueEnd) isEqualToString:cacheKey];
        if (stale && !loader.isCancelled) {
            LogInfo(@"Waveform of %@ finished on another version than its key's; decoding again",
                    track.url.lastPathComponent);
            [loader cancel];
            if (claim) {
                run_on_main_thread({ claim.retryTrack = claim.deliveryTrack; });
            }
        }
        if (!waveform || !loader.isComplete || stale) {
            completion(nil, NO); // cancelled, failed, partial, or stale
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
        id<VibePlayableItem> track = claim.deliveryTrack;
        // Detached is checked here, on delivery, not at enqueue: a reattach
        // that lands first correctly turns this back into a live delivery.
        if (!loader.isCancelled && !loader.isDetached) {
            [self.delegate audioWaveform:waveform didLoadData:1 forTrack:track];
        }
        // Completed results remain valid for their window after cancellation.
        // The receiver matches playlist rows by sourceKey before installing them.
        [self deliverResults:waveform forTrack:track];
    });
}

// On the main thread, from the loader's throttled progress callback. A new
// load detaches the old loader before taking _currentLoadTrack (cancel is cap
// eviction's, not the track change's), so the track here always belongs to
// the loader that is still delivering.
- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    if (!loader.isCancelled && !loader.isDetached && _currentLoadTrack) {
        [self.delegate audioWaveform:waveform didLoadData:percentLoaded forTrack:_currentLoadTrack];
    }
}

- (void)deliverResults:(CodableAudioWaveform *)waveform forTrack:(id<VibePlayableItem>)track {
    if (waveform.results.count &&
        [self.delegate respondsToSelector:@selector(audioWaveformCache:didLoadResults:forTrack:)]) {
        [self.delegate audioWaveformCache:self didLoadResults:waveform.results forTrack:track];
    }
}

@end
