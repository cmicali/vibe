//
//  AudioTrackMetadataLoader.m
//  Vibe
//

#import "AudioTrackMetadataLoaderInternal.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioLoadingConfiguration.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "MetadataScanOrderRules.h"
#import "MetadataRetryRules.h"
#import "MetadataParseCoordinator.h"

#include <os/lock.h>

// One scan row's record, from its stage-1 cache check through stage-2
// materialization: a plain record, never a pre-built operation. The lane
// submits at most one materialization request at a time, so everything
// still pending remains re-rankable.
@interface MetadataScanEntry : NSObject <MetadataScanOrderCandidate>
@property (nonatomic, strong) AudioTrack *track;
@property (nonatomic, copy) NSURL *url;
// The playlist row this sweep queued the track from, the comparator's
// equal-rank tie-break: without it the tail of the lane downloads in
// stage-1 completion order, which reads as random.
@property (nonatomic) NSUInteger playlistIndex;
// A retry after a failed materialization. It stays at the bottom of the lane
// however the neighborhood moves, so re-ranking cannot promote a known-bad
// file back in front of tracks that have not been tried at all.
@property (nonatomic) BOOL deferred;
@end

@implementation MetadataScanEntry
@end

@interface AudioTrackMetadataLoader ()
- (AudioTrackMetadata *)parseAndCacheMetadataForTrack:(AudioTrack *)track;
- (void)serveWaitersFromCache:(NSArray<AudioTrack *> *)waiters owner:(AudioTrack *)owner;
- (NSArray<AudioTrack *> *)installCopiesOfMetadata:(AudioTrackMetadata *)metadata
                                           onTracks:(NSArray<AudioTrack *> *)tracks;
- (void)publishTrack:(AudioTrack *)track
    expectedMetadata:(AudioTrackMetadata *)expectedMetadata;
@end

@implementation AudioTrackMetadataLoader {
    // Weak, since the owner strongly holds its current loader, and re-read at
    // use time rather than snapshotted. The owner constructs its PINCache
    // asynchronously, and a snapshot taken too early would freeze a nil cache
    // for this loader's lifetime: zero reads and writes, silently.
    __weak AudioTrackMetadataCache* _owner;
    NSOperationQueue* _queue;
    // An identity set of the tracks this loader has queued. It is deliberately
    // its own per-loader marker rather than an inference from non-nil
    // track.metadata, because a failed parse, with parsedOK == NO, must stay
    // eligible for a re-parse by a later loader: the file may have downloaded
    // since. Either way it lives in a single context and needs no locking.
    // Scan loaders touch it only inside load:'s one setup op, and the priority
    // lane touches it only on main, since loadPriorityTrack: runs on the caller's
    // thread, always main, and the completion removal is dispatched to main.
    NSMutableSet<AudioTrack *>* _queuedTracks;
    // A later lifecycle edge arrived while the priority request was still
    // waiting for its yielded delivery. The delivery consumes this marker and
    // retries only then, so a didStartPlaying: edge cannot be lost behind it.
    NSMutableSet<AudioTrack *>* _priorityRetryRequestedTracks;
    // Yielded requests whose later lifecycle edge arrived before the cache's
    // hold release. Retired priority loaders keep this set until that release.
    NSMutableSet<AudioTrack *>* _priorityParkedTracks;
    BOOL _isScanLane;
    // Every scan cache miss takes this provider-independent path. Entries stay
    // app-owned until one exact pick is atomically registered with the shared
    // materialization coordinator.
    NSMutableArray<MetadataScanEntry *>* _pendingMaterializations;
    // Admission-exhausted entries waiting for their bounded eligibility edge.
    // A set makes cancellation observable to the delayed block and keeps the
    // debug pending count honest while no coordinator request exists.
    NSMutableSet<MetadataScanEntry *>* _delayedScanRetryEntries;
    BOOL _scanMaterializationInFlight;
    BOOL _scanDispatchKickPending;
    // Bumped by every pending-list or neighborhood mutation. The picker works
    // outside the lock, then verifies this snapshot before removing its choice.
    NSUInteger _scanOrderGeneration;
    // The setup barrier flips this only after every cache check ahead of it
    // has settled, so no audio-file work can steal a worker from stage 1.
    BOOL _stageOneFinished;
    NSArray<NSURL *>* _neighborhood;   // rank order; empty until a screen names one
    // This local gate prevents a yielded scan request from resubmitting until
    // the shell's matching foreground-open settlement. The central hold owns
    // the provider-independent admission and cancellation edge.
    BOOL _backgroundMaterializationHeld;
    // Materialization failures per file path, hold cancellations excluded. The
    // budget is what keeps a transient provider error from costing the row its
    // tags for the rest of the sweep without letting a dead file retry forever.
    // Guarded by _materializationLock; bounded by the playlist's failing tracks.
    NSMutableDictionary<NSString *, NSNumber *> *_materializationAttemptsByPath;
    NSUInteger _materializationMaximumAttempts;
    os_unfair_lock _materializationLock;
    AudioFileMaterializationCoordinator *_materializationCoordinator;
    dispatch_queue_t _materializationCallbackQueue;
    NSMutableSet<AudioFileMaterializationRequestToken *> *_liveMaterializationTokens;
    AudioFileMaterializationRequestToken *_scanMaterializationToken;
    BOOL _retiring;
    dispatch_block_t _retireCompletion;
    MetadataParseCoordinator *_parseCoordinator;
}

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
                         lane:(VibeMetadataLane)lane
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    self = [super init];
    if (self) {
        NSParameterAssert(loadingConfiguration);
        _isCancelled = NO;
        _owner = owner;
        _queuedTracks = [NSMutableSet set];
        _priorityRetryRequestedTracks = [NSMutableSet set];
        _priorityParkedTracks = [NSMutableSet set];
        _materializationLock = OS_UNFAIR_LOCK_INIT;
        _materializationCoordinator = [AudioFileMaterializationCoordinator sharedCoordinator];
        _liveMaterializationTokens = [NSMutableSet set];
        _materializationMaximumAttempts =
                VibeMetadataMaximumAttemptsForRetryCount(
                        loadingConfiguration.metadataRetryCount);
        _parseCoordinator = owner.parseCoordinator;
        _delegate = delegate;
        _queue = [[NSOperationQueue alloc] init];
        if (lane == VibeMetadataLanePriority) {
            // The priority lane, loadPriorityTrack:. Only the newest
            // request is user-visible, so the width exists purely to absorb
            // blocked predecessors. A slow materialized file, on a network
            // mount or a sleeping disk, can block a worker for minutes. The configured
            // width controls how many consecutive wedged opens it takes before
            // the header's load queues behind one, at one stranded thread each.
            // The QoS is user-initiated because the user is looking at a
            // header waiting on this exact load.
            _queue.name = @"AudioTrackMetadataLoader.priority";
            _queue.maxConcurrentOperationCount =
                    (NSInteger)loadingConfiguration.localMetadataParseConcurrency;
            _queue.qualityOfService = NSQualityOfServiceUserInitiated;
            dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
            _materializationCallbackQueue = dispatch_queue_create(
                    "com.vibe.metadata-priority-materialization", attributes);
        }
        else {
            _isScanLane = YES;
            // Configurable concurrency lets a single slow file, on a network
            // mount or a sleeping disk, stall only its own worker rather than
            // the whole playlist. Utility is the right QoS band: the work is
            // user-visible, since it drives the playlist UI, but not
            // user-initiated.
            _queue.name = @"AudioTrackMetadataLoader";
            _queue.maxConcurrentOperationCount =
                    (NSInteger)loadingConfiguration.localMetadataParseConcurrency;
            _queue.qualityOfService = NSQualityOfServiceUtility;
            _pendingMaterializations = [NSMutableArray array];
            _delayedScanRetryEntries = [NSMutableSet set];
            _neighborhood = @[];
            _materializationAttemptsByPath = [NSMutableDictionary dictionary];
            dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
            _materializationCallbackQueue = dispatch_queue_create(
                    "com.vibe.metadata-scan-materialization", attributes);
        }
    }
    return self;
}

- (void)load:(NSArray<AudioTrack*>*)tracks {
    __weak __typeof(self) weakSelf = self;
    // One setup op, rather than a per-track loop on the caller's main thread:
    // the parsedOK and dedupe walk over a large drop must not cost the main
    // thread a burst. It runs at high priority so that the sweep still starts
    // ahead of any queued stage-2 parses.
    NSOperation *setup = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) setupSelf = weakSelf;
        if (!setupSelf) return;
        NSMutableArray<MetadataScanEntry *> *worklist =
                [NSMutableArray arrayWithCapacity:tracks.count];
        for (NSUInteger index = 0; index < tracks.count; index++) {
            if (setupSelf.isCancelled) break;
            AudioTrack *track = tracks[index];
            // Skip only tracks with real metadata. A failed parse, where
            // parsedOK is NO because of a dataless cloud placeholder or a
            // transient I/O error, stays eligible: the file may be readable by
            // the time the playlist is re-queued, and the filename-only
            // fallback would otherwise stick until the app restarts. Messaging
            // nil metadata returns NO, so never-parsed tracks pass through too.
            if (track.metadata.parsedOK) continue;
            // A track appearing twice in the array must not parse twice.
            if ([setupSelf->_queuedTracks containsObject:track]) continue;
            [setupSelf->_queuedTracks addObject:track];
            MetadataScanEntry *entry = [[MetadataScanEntry alloc] init];
            entry.track = track;
            entry.url = track.url;
            // The materialization lane's tie-break is the row order this loop
            // walks in.
            entry.playlistIndex = index;
            [worklist addObject:entry];
        }
        [setupSelf enqueueStageOneWorkersForWorklist:worklist];
        [setupSelf->_queue addBarrierBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            BOOL shouldDispatch = NO;
            os_unfair_lock_lock(&strongSelf->_materializationLock);
            if (!strongSelf.isCancelled) {
                strongSelf->_stageOneFinished = YES;
                shouldDispatch = strongSelf->_pendingMaterializations.count > 0;
            }
            os_unfair_lock_unlock(&strongSelf->_materializationLock);
            if (shouldDispatch) {
                [strongSelf dispatchNextScanMaterialization];
            }
        }];
    }];
    setup.queuePriority = NSOperationQueuePriorityHigh;
    [_queue addOperation:setup];
    LogInfo(@"Metadata sweep: %lu tracks", (unsigned long)tracks.count);
}

// Stage 1 of the two-stage scan: the cache check, a stat and a small disk
// read, never the audio data, so a dataless cloud placeholder cannot block it
// on a download. High priority makes the whole cache sweep drain before any
// parse gets a worker, so every previously seen track's row populates at disk
// speed even when the playlist is mostly slow cloud files.
//
// A bounded worker set drains the records in playlist order — never one
// pre-built operation per row, because a playlist can hold over 100,000 rows
// and each resident operation would retain a track and a block before stage 2
// admits its first miss. Each worker rechecks isCancelled before every
// record, so a cancel stops the sweep at per-track granularity.
- (void)enqueueStageOneWorkersForWorklist:(NSArray<MetadataScanEntry *> *)worklist {
    if (worklist.count == 0) {
        return;
    }
    NSUInteger workerCount = MIN((NSUInteger)_queue.maxConcurrentOperationCount,
                                 worklist.count);
    // Shared by the workers alone; guarded by _materializationLock.
    __block NSUInteger cursor = 0;
    __weak __typeof(self) weakSelf = self;
    for (NSUInteger worker = 0; worker < workerCount; worker++) {
        NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
            for (;;) {
                __typeof(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf.isCancelled) return;
                MetadataScanEntry *entry = nil;
                os_unfair_lock_lock(&strongSelf->_materializationLock);
                if (cursor < worklist.count) {
                    entry = worklist[cursor++];
                }
                os_unfair_lock_unlock(&strongSelf->_materializationLock);
                if (!entry) return;
                [strongSelf cacheCheckEntry:entry];
            }
        }];
        op.queuePriority = NSOperationQueuePriorityHigh;
        [_queue addOperation:op];
    }
}

// The stage-1 worker step: publish from the disk cache, or hand the record to
// stage 2. Every miss first takes the shared materialization path. A local
// file settles immediately; an unflagged provider placeholder cannot bypass
// the foreground hold and wedge one of the wide TagLib workers.
- (void)cacheCheckEntry:(MetadataScanEntry *)entry {
    AudioTrack *track = entry.track;
    // A second drop can re-queue a track before its first check runs, so skip
    // the redundant work if the earlier loader already produced real metadata.
    // Failed metadata, with parsedOK == NO, does not count as done: re-parsing
    // it is the whole point of the re-queue.
    if (track.metadata.parsedOK) {
        return;
    }
    if ([self loadTrackFromDiskCache:track]) {
        return;
    }
    if (self.isCancelled) {
        return;
    }
    if (_isScanLane) {
        [self enqueueScanMaterialization:entry];
        return;
    }
    [self submitPriorityMaterializationForTrack:track];
}

#pragma mark - The scan materialization lane

- (void)enqueueScanMaterialization:(MetadataScanEntry *)entry {
    os_unfair_lock_lock(&_materializationLock);
    if (!self.isCancelled) {
        [_pendingMaterializations addObject:entry];
        _scanOrderGeneration++;
    }
    os_unfair_lock_unlock(&_materializationLock);
}

- (void)dispatchNextScanMaterialization {
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanDispatchKickPending && !self.isCancelled) {
        _scanDispatchKickPending = YES;
        shouldSchedule = YES;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!shouldSchedule) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        strongSelf->_scanDispatchKickPending = NO;
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        [strongSelf dispatchNextScanMaterializationOnCallbackQueue];
    });
}

- (void)dispatchNextScanMaterializationOnCallbackQueue {
    NSArray<MetadataScanEntry *> *pending = nil;
    NSArray<NSURL *> *neighborhood = nil;
    NSUInteger orderGeneration = 0;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanMaterializationInFlight && !_backgroundMaterializationHeld && !self.isCancelled
            && _stageOneFinished && _pendingMaterializations.count > 0) {
        pending = [_pendingMaterializations copy];
        neighborhood = _neighborhood;
        orderGeneration = _scanOrderGeneration;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!pending.count) {
        return;
    }

    MetadataScanEntry *chosen =
            (MetadataScanEntry *)VibeBestMetadataScanCandidate(
            (NSArray<id<MetadataScanOrderCandidate>> *)pending,
            neighborhood);
    BOOL retryPick = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (_scanMaterializationInFlight || _backgroundMaterializationHeld || self.isCancelled) {
        chosen = nil;
    }
    else if (orderGeneration != _scanOrderGeneration) {
        chosen = nil;
        retryPick = YES;
    }
    else if (chosen) {
        if ([_pendingMaterializations containsObject:chosen]) {
            [_pendingMaterializations removeObjectIdenticalTo:chosen];
            _scanOrderGeneration++;
            _scanMaterializationInFlight = YES;
        }
        else {
            chosen = nil;
            retryPick = YES;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (retryPick) {
        [self dispatchNextScanMaterialization];
        return;
    }
    if (!chosen) {
        return;
    }
    [self submitScanMaterializationForEntry:chosen];
}

- (void)submitScanMaterializationForEntry:(MetadataScanEntry *)entry {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        BOOL requeueBehindHold = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled) {
            strongSelf->_scanMaterializationInFlight = NO;
        }
        else if (strongSelf->_backgroundMaterializationHeld) {
            [strongSelf->_pendingMaterializations addObject:entry];
            strongSelf->_scanOrderGeneration++;
            strongSelf->_scanMaterializationInFlight = NO;
            requeueBehindHold = YES;
        }
        BOOL shouldSubmit = !strongSelf.isCancelled && !requeueBehindHold;
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (!shouldSubmit) {
            return;
        }

        __block __weak AudioFileMaterializationRequestToken *weakToken = nil;
        AudioFileMaterializationRequestToken *token =
                [strongSelf->_materializationCoordinator
                        materializeURL:entry.url
                                  role:VibeAudioFileMaterializationRoleMetadataScan
                       completionQueue:strongSelf->_materializationCallbackQueue
                            registered:nil
                            completion:^(VibeAudioFileMaterializationResult result,
                                         NSError *error,
                                         NSTimeInterval elapsed) {
            [weakSelf completeScanMaterializationForEntry:entry
                                                     token:weakToken
                                                    result:result
                                                     error:error
                                                   elapsed:elapsed];
        }];
        weakToken = token;

        BOOL cancelToken = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled || !strongSelf->_scanMaterializationInFlight) {
            cancelToken = YES;
        }
        else {
            strongSelf->_scanMaterializationToken = token;
            [strongSelf->_liveMaterializationTokens addObject:token];
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (cancelToken) {
            [token cancel];
        }
    });
}

- (void)completeScanMaterializationForEntry:(MetadataScanEntry *)entry
                                      token:(AudioFileMaterializationRequestToken *)token
                                     result:(VibeAudioFileMaterializationResult)result
                                      error:(NSError *)error
                                    elapsed:(NSTimeInterval)elapsed {
    BOOL shouldParse = NO;
    BOOL didRequeue = NO;
    BOOL didScheduleDelayedRetry = NO;
    NSTimeInterval retryDelay = 0;
    NSUInteger attempt = 0;
    NSString *attemptKey = entry.url.path ?: entry.url.absoluteString;

    os_unfair_lock_lock(&_materializationLock);
    if (_scanMaterializationToken != token) {
        [_liveMaterializationTokens removeObject:token];
        os_unfair_lock_unlock(&_materializationLock);
        return;
    }
    [_liveMaterializationTokens removeObject:token];
    _scanMaterializationToken = nil;
    _scanMaterializationInFlight = NO;
    if (!self.isCancelled) {
        if (result == VibeAudioFileMaterializationResultReady) {
            shouldParse = YES;
            if (attemptKey) {
                [_materializationAttemptsByPath removeObjectForKey:attemptKey];
            }
        }
        else {
            NSUInteger priorAttempts = attemptKey
                    ? _materializationAttemptsByPath[attemptKey].unsignedIntegerValue : 0;
            VibeMetadataMaterializationRetry retry =
                    VibeMetadataMaterializationRetryForResult(
                            result, priorAttempts,
                            _materializationMaximumAttempts);
            if (retry != VibeMetadataMaterializationRetryNone) {
                if (retry == VibeMetadataMaterializationRetryDeferred
                        || retry == VibeMetadataMaterializationRetryDeferredAfterDelay) {
                    attempt = priorAttempts + 1;
                    entry.deferred = YES;
                    if (attemptKey) {
                        _materializationAttemptsByPath[attemptKey] = @(attempt);
                    }
                }
                if (retry == VibeMetadataMaterializationRetryDeferredAfterDelay) {
                    retryDelay = VibeMetadataAdmissionRetryDelay(priorAttempts);
                    [_delayedScanRetryEntries addObject:entry];
                    didScheduleDelayedRetry = YES;
                }
                else {
                    [_pendingMaterializations addObject:entry];
                    _scanOrderGeneration++;
                }
                didRequeue = YES;
            }
            else if (result == VibeAudioFileMaterializationResultFailed
                    || result == VibeAudioFileMaterializationResultAdmissionExhausted) {
                attempt = priorAttempts + 1;
                if (attemptKey) {
                    _materializationAttemptsByPath[attemptKey] = @(attempt);
                }
            }
        }
    }
    os_unfair_lock_unlock(&_materializationLock);

    if (shouldParse) {
        __weak __typeof(self) weakSelf = self;
        [_queue addOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf && !strongSelf.isCancelled) {
                [strongSelf parseOneTrack:entry.track];
            }
        }];
        LogInfo(@"Metadata scan materialized %@ in %.1fs",
                entry.url.lastPathComponent, elapsed);
    }
    else if (result == VibeAudioFileMaterializationResultYielded) {
        LogInfo(@"Metadata scan yielded %@ after %.1fs",
                entry.url.lastPathComponent, elapsed);
    }
    else if (result == VibeAudioFileMaterializationResultFailed
            || result == VibeAudioFileMaterializationResultAdmissionExhausted) {
        if (didRequeue) {
            LogWarn(@"Metadata scan materialization failed for %@ "
                    @"(attempt %lu of %lu); re-queued last (%@)",
                    entry.url.lastPathComponent, (unsigned long)attempt,
                    (unsigned long)_materializationMaximumAttempts,
                    error.localizedDescription);
        }
        else {
            LogWarn(@"Metadata scan materialization failed for %@ and is out of attempts (%@)",
                    entry.url.lastPathComponent, error.localizedDescription);
        }
    }
    if (didScheduleDelayedRetry) {
        [self scheduleDelayedScanRetryForEntry:entry delay:retryDelay];
    }
    [self dispatchNextScanMaterialization];
}

- (void)scheduleDelayedScanRetryForEntry:(MetadataScanEntry *)entry
                                   delay:(NSTimeInterval)delay {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   _materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL shouldDispatch = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if ([strongSelf->_delayedScanRetryEntries containsObject:entry]) {
            [strongSelf->_delayedScanRetryEntries removeObject:entry];
            if (!strongSelf.isCancelled) {
                [strongSelf->_pendingMaterializations addObject:entry];
                strongSelf->_scanOrderGeneration++;
                shouldDispatch = YES;
            }
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (shouldDispatch) {
            [strongSelf dispatchNextScanMaterialization];
        }
    });
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    if (!_isScanLane) {
        return;
    }
    os_unfair_lock_lock(&_materializationLock);
    _neighborhood = [urls copy] ?: @[];
    _scanOrderGeneration++;
    os_unfair_lock_unlock(&_materializationLock);
    [self dispatchNextScanMaterialization];
}

#if DEBUG
// Used by AudioTrackMetadataCache's debug surface; the list lives here.
- (NSUInteger)debugPendingBackgroundMaterializationCount {
    if (!_isScanLane) {
        return 0;
    }
    os_unfair_lock_lock(&_materializationLock);
    NSUInteger count = _pendingMaterializations.count + _delayedScanRetryEntries.count
            + (_scanMaterializationInFlight ? 1 : 0);
    os_unfair_lock_unlock(&_materializationLock);
    return count;
}
#endif

// The priority lane asks the same central coordinator with the priority
// role. A same-path playback request is joined atomically; a didStart edge
// racing a Yielded callback either retries after release or parks until it.
- (void)loadPriorityTrack:(AudioTrack *)track {
    if (track.metadata.parsedOK) {
        return;
    }
    if ([_queuedTracks containsObject:track]) {
        [_priorityRetryRequestedTracks addObject:track];
        return;
    }
    [_queuedTracks addObject:track];
    __weak __typeof(self) weakSelf = self;
    [_queue addOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            run_on_main_thread({
                [weakSelf clearInFlightTrack:track];
            });
            return;
        }
        if ([strongSelf loadTrackFromDiskCache:track]) {
            run_on_main_thread({
                [weakSelf clearInFlightTrack:track];
            });
            return;
        }
        [strongSelf submitPriorityMaterializationForTrack:track];
    }];
}

- (void)submitPriorityMaterializationForTrack:(AudioTrack *)track {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            run_on_main_thread({
                [weakSelf clearInFlightTrack:track];
            });
            return;
        }

        __block __weak AudioFileMaterializationRequestToken *weakToken = nil;
        AudioFileMaterializationRequestToken *token =
                [strongSelf->_materializationCoordinator
                        materializeURL:track.url
                                  role:VibeAudioFileMaterializationRoleMetadataPriority
                       completionQueue:strongSelf->_materializationCallbackQueue
                            registered:nil
                            completion:^(VibeAudioFileMaterializationResult result,
                                         NSError *error,
                                         NSTimeInterval elapsed) {
            [weakSelf completePriorityMaterializationForTrack:track
                                                        token:weakToken
                                                       result:result
                                                        error:error
                                                      elapsed:elapsed];
        }];
        weakToken = token;

        BOOL cancelToken = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled) {
            cancelToken = YES;
        }
        else {
            [strongSelf->_liveMaterializationTokens addObject:token];
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (cancelToken) {
            [token cancel];
        }
    });
}

- (void)completePriorityMaterializationForTrack:(AudioTrack *)track
                                           token:(AudioFileMaterializationRequestToken *)token
                                          result:(VibeAudioFileMaterializationResult)result
                                           error:(NSError *)error
                                         elapsed:(NSTimeInterval)elapsed {
    __weak __typeof(self) weakSelf = self;
    os_unfair_lock_lock(&_materializationLock);
    [_liveMaterializationTokens removeObject:token];
    BOOL cancelled = self.isCancelled;
    os_unfair_lock_unlock(&_materializationLock);

    if (result == VibeAudioFileMaterializationResultReady && !cancelled) {
        [_queue addOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf && !strongSelf.isCancelled) {
                [strongSelf parseOneTrack:track];
            }
            run_on_main_thread({
                [weakSelf clearInFlightTrack:track];
            });
        }];
        LogInfo(@"Priority metadata materialized %@ in %.1fs",
                track.url.lastPathComponent, elapsed);
        return;
    }
    if (result == VibeAudioFileMaterializationResultYielded && !cancelled) {
        run_on_main_thread({
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            VibeMetadataPriorityYieldAction action =
                    VibeMetadataPriorityActionForYield(
                            [strongSelf->_priorityRetryRequestedTracks containsObject:track],
                            strongSelf->_backgroundMaterializationHeld,
                            strongSelf.isCancelled);
            [strongSelf->_priorityRetryRequestedTracks removeObject:track];
            switch (action) {
                case VibeMetadataPriorityYieldActionRetry:
                    [strongSelf submitPriorityMaterializationForTrack:track];
                    break;
                case VibeMetadataPriorityYieldActionPark:
                    [strongSelf->_priorityParkedTracks addObject:track];
                    break;
                case VibeMetadataPriorityYieldActionClear:
                    [strongSelf clearInFlightTrack:track];
                    break;
            }
        });
        return;
    }
    if (!cancelled && result != VibeAudioFileMaterializationResultYielded) {
        LogWarn(@"Priority metadata materialization failed for %@ (%@)",
                track.url.lastPathComponent, error.localizedDescription);
    }
    run_on_main_thread({
        [weakSelf clearInFlightTrack:track];
    });
}

- (void)clearInFlightTrack:(AudioTrack *)track {
    [_queuedTracks removeObject:track];
    [_priorityRetryRequestedTracks removeObject:track];
    [_priorityParkedTracks removeObject:track];
    [self finishRetirementIfPossible];
}

- (void)retireWithCompletion:(dispatch_block_t)completion {
    _retiring = YES;
    _retireCompletion = [completion copy];
    [self finishRetirementIfPossible];
}

- (void)finishRetirementIfPossible {
    if (!_retiring || _queuedTracks.count) {
        return;
    }
    dispatch_block_t completion = _retireCompletion;
    _retireCompletion = nil;
    _retiring = NO;
    [_queue addBarrierBlock:^{
        run_on_main_thread({
            completion();
        });
    }];
}

// A disk-cache attempt. It returns YES on a hit, with the metadata set on the
// track and published. It deliberately touches only file attributes and the
// cache store, never the audio data, because both lanes rely on it staying
// fast for dataless cloud files.
- (BOOL)loadTrackFromDiskCache:(AudioTrack *)track {
    // nil when the file cannot be statted; see NSURL+Hash. Without a stable
    // identity there is no cache read. The stage-2 parse still runs, and an
    // unreadable file degrades to the filename-only fallback, parsedOK == NO.
    NSString *cacheKey = track.cacheKey;
    if (!cacheKey) {
        LogWarn(@"No cache key for %@ — loading metadata uncached", track.url.path);
        return NO;
    }
    // Re-read at use time; see _owner. nil merely means not yet constructed,
    // so the earliest tracks parse uncached rather than the whole playlist.
    PINCache *metadataCache = _owner.metadataCache;
    if (!metadataCache) {
        LogWarn(@"Metadata cache not yet available — loading %@ uncached", track.url.path);
        return NO;
    }
    // Read the disk cache directly, bypassing PINMemoryCache. On macOS the
    // memory cache never evicts, since its pressure hooks are iOS-only and
    // disk hits repopulate it at cost 0, so every track ever loaded — decoded
    // thumbnail included — would stay pinned for the age limit even after its
    // playlist was gone. The playlist's AudioTrack objects retain the live
    // metadata, and a re-drop pays about a 10KB unarchive per track.
    AudioTrackMetadata *cachedMetaData = (AudioTrackMetadata *)[metadataCache.diskCache objectForKey:cacheKey];
    // PINCache unarchives without secure coding, so a tampered entry with a
    // different root class decodes cleanly and bypasses initWithCoder:'s field
    // validation entirely. A wrong-class object would crash on first use, with
    // an unrecognized selector, on every launch. Evict it instead.
    if (cachedMetaData && ![cachedMetaData isKindOfClass:[AudioTrackMetadata class]]) {
        [metadataCache.diskCache removeObjectForKey:cacheKey];
        cachedMetaData = nil;
    }
    if (!cachedMetaData) {
        return NO;
    }
    // Unarchive keeps compact thumbnail bytes. The first visible row requests
    // their bounded off-main decode; offscreen rows cost no decoded pixels.
    //
    // Another lane may have installed a successful parse result while this
    // disk read was in flight. Only the winner publishes: otherwise the cache
    // hit overwrites independently adopted artwork state and the row receives
    // the same logical metadata completion twice.
    if ([track installMetadataIfUnresolved:cachedMetaData]) {
        [self publishTrack:track];
    }
    return YES;
}

// The stage-2 worker: the TagLib parse. The central materialization result has
// already made provider-backed content ready before this opens the audio file.
- (void)parseOneTrack:(AudioTrack *)track {
    if (self.isCancelled || track.metadata.parsedOK) {
        return;
    }
    MetadataParseClaim *claim = [_parseCoordinator claimParseForKey:track.url
                                                         participant:track];
    if (!claim.isOwner) {
        return;
    }
    // Another lane can resolve this row, or a prior holder can populate the
    // disk entry, between the entry check and claim acquisition.
    if (track.metadata.parsedOK || [self loadTrackFromDiskCache:track]) {
        [self serveWaitersFromCache:[_parseCoordinator completeClaim:claim] owner:track];
        return;
    }

    AudioTrackMetadata *result = [self parseAndCacheMetadataForTrack:track];
    if (result.parsedOK) {
        BOOL publishHolder = [track installMetadataIfUnresolved:result];
        NSMutableArray<AudioTrack *> *adopted = [NSMutableArray array];
        BOOL completed = NO;
        do {
            NSArray<AudioTrack *> *waiters =
                    [_parseCoordinator drainWaitersForSuccessfulClaim:claim
                                                              completed:&completed];
            [adopted addObjectsFromArray:
                    [self installCopiesOfMetadata:result onTracks:waiters]];
        } while (!completed);
        if (publishHolder) {
            [self publishTrack:track];
        }
        for (AudioTrack *waiter in adopted) {
            [self publishTrack:waiter];
        }
        return;
    }

    BOOL publishFallback = [track installMetadataIfUnresolved:result];
    NSArray<AudioTrack *> *waiters = [_parseCoordinator completeClaim:claim];
    if (publishFallback) {
        [self publishTrack:track expectedMetadata:result];
    }
    for (AudioTrack *waiter in waiters) {
        AudioTrackMetadata *copy = [result copy];
        if ([waiter installMetadataIfUnresolved:copy]) {
            [self publishTrack:waiter expectedMetadata:copy];
        }
    }
}

- (void)serveWaitersFromCache:(NSArray<AudioTrack *> *)waiters owner:(AudioTrack *)owner {
    NSMutableArray<AudioTrack *> *unserved = [NSMutableArray array];
    for (AudioTrack *waiter in waiters) {
        if (!waiter.metadata.parsedOK && ![self loadTrackFromDiskCache:waiter]) {
            [unserved addObject:waiter];
        }
    }
    if (unserved.count == 0) {
        return;
    }
    // The disk entry can vanish between the owner's hit and a waiter's read —
    // Clear Cache racing the drain, or eviction. The owner's installed result
    // is the same metadata, so copy it rather than stranding the row on
    // filename-only display with nothing left to re-parse it.
    AudioTrackMetadata *ownerMetadata = owner.metadata;
    if (!ownerMetadata.parsedOK) {
        return;
    }
    for (AudioTrack *waiter in [self installCopiesOfMetadata:ownerMetadata
                                                    onTracks:unserved]) {
        [self publishTrack:waiter];
    }
}

- (NSArray<AudioTrack *> *)installCopiesOfMetadata:(AudioTrackMetadata *)metadata
                                           onTracks:(NSArray<AudioTrack *> *)tracks {
    NSMutableArray<AudioTrack *> *installed = [NSMutableArray array];
    for (AudioTrack *track in tracks) {
        if (track.metadata.parsedOK) {
            continue;
        }
        AudioTrackMetadata *copy = [metadata copy];
        if ([track installMetadataIfUnresolved:copy]) {
            [installed addObject:track];
        }
    }
    return installed;
}

- (AudioTrackMetadata *)parseAndCacheMetadataForTrack:(AudioTrack *)track {
    AudioTrackMetadataCache *owner = _owner;
    // Captured before the parse, which can block for minutes on a cloud file:
    // an invalidate arriving mid-parse makes this result stale for the cache.
    uint64_t generation = owner.cacheGeneration;
    AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:track.url];
    // cacheKey is re-read here, memoized on the track, because a transient
    // stat failure at cache-check time may have healed by the end of the parse.
    NSString *cacheKey = track.cacheKey;
    if (metadata.parsedOK && cacheKey) {
        // Skip failed parses, whether from a dataless cloud file or a
        // transient I/O error: caching the filename-only fallback would shadow
        // the real tags until the size-and-mtime cache key changed, which can
        // take up to the six-month limit. The write is synchronous on purpose,
        // because it is small, about 10KB, and the back-pressure paces the
        // workers; async writes pile up on PINDiskCache's serial queue and
        // stall the workers' next objectForKey: behind the backlog. The cache
        // is re-read fresh here, since it may have finished constructing
        // during the parse above, and nil no-ops harmlessly if it has not.
        // The generation guard mirrors the waveform cache's: skip the write
        // after an invalidate, and re-check after it lands, because
        // removeAllObjects takes PINDiskCache's lock directly and can slip
        // between the check and the write. The compensating remove is what
        // keeps Settings > Clear Cache genuinely empty.
        // The strong local throughout, never the weak _owner: it is pinned at
        // the top precisely so the cache cannot deallocate across the parse
        // above, and reaching back through the ivar here would put a nil hole
        // in the middle of the write-then-recheck pair.
        if (generation == owner.cacheGeneration) {
            [owner.metadataCache.diskCache setObject:metadata forKey:cacheKey];
            if (generation != owner.cacheGeneration) {
                [owner.metadataCache.diskCache removeObjectForKey:cacheKey];
            }
        }
    }
    return metadata;
}

// Deliberately not gated on isCancelled: every caller reaching this method has
// a candidate publication edge — a successful install winner, a cache winner,
// or an installed failed fallback. The identity guard below decides whether it
// still owns delivery, and a departed track is dropped by the delegate's own
// checks.
- (void)publishTrack:(AudioTrack *)track {
    [self publishTrack:track expectedMetadata:track.metadata];
}

- (void)publishTrack:(AudioTrack *)track
    expectedMetadata:(AudioTrackMetadata *)expectedMetadata {
    if (!expectedMetadata) {
        return;
    }
    // Folder art stays off the scan path; its accessors resolve it lazily for
    // tracks actually on screen.
    run_on_main_thread({
        // Keep the installed object stable through the observer call. Both
        // delegates read track.metadata synchronously; neither waits for a
        // metadata worker, and the recursive monitor permits ordinary reads.
        [track deliverIfMetadataStillInstalled:expectedMetadata usingBlock:^{
            [self.delegate didLoadMetadata:track];
        }];
    });
}

- (void)setBackgroundMaterializationHeld:(BOOL)held {
    os_unfair_lock_lock(&_materializationLock);
    _backgroundMaterializationHeld = held;
    os_unfair_lock_unlock(&_materializationLock);
    if (!held) {
        if (_isScanLane) {
            [self dispatchNextScanMaterialization];
        }
        else {
            NSArray<AudioTrack *> *parkedTracks = _priorityParkedTracks.allObjects;
            [_priorityParkedTracks removeAllObjects];
            for (AudioTrack *track in parkedTracks) {
                VibeMetadataPriorityYieldAction action =
                        VibeMetadataPriorityActionForHoldRelease(
                                [_priorityRetryRequestedTracks containsObject:track],
                                self.isCancelled);
                [_priorityRetryRequestedTracks removeObject:track];
                if (action == VibeMetadataPriorityYieldActionRetry) {
                    [self submitPriorityMaterializationForTrack:track];
                }
                else {
                    [self clearInFlightTrack:track];
                }
            }
        }
    }
}

- (void)cancel {
    // Scan lane only: the cache cancels _currentLoader and nothing else — the
    // priority lane always retires through retireWithCompletion:.
    NSAssert(_isScanLane, @"Only the scan lane is ever cancelled");
    self.isCancelled = YES;
    [_queue cancelAllOperations];
    NSArray<AudioFileMaterializationRequestToken *> *tokens = nil;
    os_unfair_lock_lock(&_materializationLock);
    tokens = _liveMaterializationTokens.allObjects;
    [_liveMaterializationTokens removeAllObjects];
    _scanMaterializationToken = nil;
    _scanMaterializationInFlight = NO;
    _scanDispatchKickPending = NO;
    if (_isScanLane) {
        _backgroundMaterializationHeld = YES;
        _stageOneFinished = NO;
        [_pendingMaterializations removeAllObjects];
        [_delayedScanRetryEntries removeAllObjects];
        _scanOrderGeneration++;
        [_materializationAttemptsByPath removeAllObjects];
    }
    os_unfair_lock_unlock(&_materializationLock);
    for (AudioFileMaterializationRequestToken *token in tokens) {
        [token cancel];
    }
}

@end
