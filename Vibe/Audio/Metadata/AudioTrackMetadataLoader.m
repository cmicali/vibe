//
//  AudioTrackMetadataLoader.m
//  Vibe
//

#import "AudioTrackMetadataLoader.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioLoadingConfiguration.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "CloudParseOrderRules.h"
#import "MetadataMaterializationRetryRules.h"
#import "MetadataRetryMath.h"
#import "MetadataStageOneRules.h"
#import "MetadataParseCoordinator.h"

#include <os/lock.h>

// One pending scan parse: a plain record, never a pre-built operation. The
// lane submits at most one materialization request at a time, so everything
// still pending remains re-rankable.
@interface VibeMetadataParseEntry : NSObject <VibeCloudParseOrderCandidate>
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

@implementation VibeMetadataParseEntry
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
    // lane touches it only on main, since loadSingleTrack: runs on the caller's
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
    NSMutableArray<VibeMetadataParseEntry *>* _pendingParses;
    // Admission-exhausted entries waiting for their bounded eligibility edge.
    // A set makes cancellation observable to the delayed block and keeps the
    // debug pending count honest while no coordinator request exists.
    NSMutableSet<VibeMetadataParseEntry *>* _delayedScanRetryEntries;
    BOOL _scanMaterializationInFlight;
    BOOL _scanDispatchKickPending;
    // Bumped by every pending-list or neighborhood mutation. The picker works
    // outside the lock, then verifies this snapshot before removing its choice.
    NSUInteger _parseOrderGeneration;
    // The setup operation discovers checks while earlier checks can already be
    // finishing. Stage 2 therefore waits for both facts — enumeration finished
    // and every discovered check settled — never a bare count reaching zero in
    // the middle of enumeration.
    VibeMetadataStageOneState _stageOneState;
    NSArray<NSURL *>* _neighborhood;   // rank order; empty until a screen names one
    // This local gate prevents a yielded scan request from resubmitting until
    // the shell's matching foreground-open settlement. The central hold owns
    // the provider-independent admission and cancellation edge.
    BOOL _cloudParsesHeld;
    // Materialization failures per file path, hold cancellations excluded. The
    // budget is what keeps a transient provider error from costing the row its
    // tags for the rest of the sweep without letting a dead file retry forever.
    // Guarded by _materializationLock; bounded by the playlist's failing tracks.
    NSMutableDictionary<NSString *, NSNumber *> *_cloudAttemptsByPath;
    NSUInteger _cloudMaterializationMaximumAttempts;
    os_unfair_lock _materializationLock;
    AudioFileMaterializationCoordinator *_materializationCoordinator;
    dispatch_queue_t _materializationCallbackQueue;
    NSMutableSet<AudioFileMaterializationRequestToken *> *_liveMaterializationTokens;
    AudioFileMaterializationRequestToken *_scanMaterializationToken;
    BOOL _retiring;
    dispatch_block_t _retireCompletion;
    // The parse ordering, over the owner's shared coordinator. Held strongly,
    // and it holds this loader weakly back.
    MetadataParseRunner* _parseRunner;
}

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
                         lane:(VibeMetadataLane)lane {
    return [self initWithOwner:owner delegate:delegate lane:lane
          loadingConfiguration:[AudioLoadingConfiguration productionConfiguration]];
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
        _cloudMaterializationMaximumAttempts =
                VibeMetadataMaximumAttemptsForRetryCount(
                        loadingConfiguration.metadataRetryCount);
        _parseRunner = [[MetadataParseRunner alloc] initWithCoordinator:owner.parseCoordinator
                                                           delegate:self];
        _delegate = delegate;
        _queue = [[NSOperationQueue alloc] init];
        if (lane == VibeMetadataLaneCurrentTrack) {
            // The current-track lane, loadSingleTrack:. Only the newest
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
            _pendingParses = [NSMutableArray array];
            _delayedScanRetryEntries = [NSMutableSet set];
            _neighborhood = @[];
            _stageOneState = VibeMetadataStageOneStateMake();
            _cloudAttemptsByPath = [NSMutableDictionary dictionary];
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
    // One setup op, rather than a per-track loop on the caller's main thread.
    // A drop of several thousand tracks would otherwise pay for thousands of
    // NSBlockOperation allocations and addOperation: locks in one main-thread
    // burst. It runs at high priority so that the sweep still starts ahead of
    // any queued stage-2 parses.
    NSOperation *setup = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) setupSelf = weakSelf;
        if (!setupSelf) return;
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
            // Stage 1 of the two-stage scan: the cache check, a stat and a
            // small disk read, never the audio data, so a dataless cloud
            // placeholder cannot block it on a download. High priority makes
            // the whole cache sweep drain before any parse gets a worker, so
            // every previously seen track's row populates at disk speed even
            // when the playlist is mostly slow cloud files. Misses re-enqueue
            // as stage-2 work; the playlist index rides along because the
            // materialization lane's tie-break is the row order this loop walks in. See
            // cacheCheckOneTrack:index:deferred:.
            if (setupSelf->_isScanLane) {
                os_unfair_lock_lock(&setupSelf->_materializationLock);
                VibeMetadataStageOneBeginCheck(&setupSelf->_stageOneState);
                os_unfair_lock_unlock(&setupSelf->_materializationLock);
            }
            NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
                __typeof(self) strongSelf = weakSelf;
                if (strongSelf && !strongSelf.isCancelled) {
                    [strongSelf cacheCheckOneTrack:track index:index deferred:NO];
                }
                [strongSelf noteStageOneCheckFinished];
            }];
            op.queuePriority = NSOperationQueuePriorityHigh;
            [setupSelf->_queue addOperation:op];
        }
        [setupSelf noteStageOneEnumerationFinished];
    }];
    setup.queuePriority = NSOperationQueuePriorityHigh;
    [_queue addOperation:setup];
    LogInfo(@"Metadata sweep: %lu tracks", (unsigned long)tracks.count);
}

// The stage-1 worker: publish from the disk cache, or hand off to stage 2.
// Every miss first takes the shared materialization path. A local file settles
// immediately; an unflagged provider placeholder cannot bypass the foreground
// hold and wedge one of the wide TagLib workers.
//
// deferred marks a re-queue after a failed materialization. It only affects
// the scan lane's ordering.
- (void)cacheCheckOneTrack:(AudioTrack *)track index:(NSUInteger)playlistIndex deferred:(BOOL)deferred {
    // A second drop can re-queue a track before its first op runs, so skip the
    // redundant work if the earlier loader already produced real metadata.
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
        VibeMetadataParseEntry *entry = [[VibeMetadataParseEntry alloc] init];
        entry.track = track;
        entry.url = track.url;
        entry.playlistIndex = playlistIndex;
        entry.deferred = deferred;
        [self enqueueScanParseEntry:entry];
        return;
    }
    [self submitPriorityMaterializationForTrack:track];
}

#pragma mark - The scan materialization lane

- (void)enqueueScanParseEntry:(VibeMetadataParseEntry *)entry {
    os_unfair_lock_lock(&_materializationLock);
    if (!self.isCancelled) {
        [_pendingParses addObject:entry];
        _parseOrderGeneration++;
    }
    os_unfair_lock_unlock(&_materializationLock);
    [self dispatchStageTwoIfReady];
}

// A check can finish while the setup operation is still discovering later
// checks, so neither edge is sufficient alone. Whichever edge completes the
// pair kicks stage 2.
- (void)noteStageOneCheckFinished {
    if (!_isScanLane) {
        return;
    }
    BOOL canDispatch = NO;
    os_unfair_lock_lock(&_materializationLock);
    VibeMetadataStageOneFinishCheck(&_stageOneState);
    canDispatch = VibeMetadataStageTwoCanDispatch(
            _stageOneState, _pendingParses.count);
    os_unfair_lock_unlock(&_materializationLock);
    if (canDispatch) {
        [self dispatchStageTwoIfReady];
    }
}

- (void)noteStageOneEnumerationFinished {
    if (!_isScanLane) {
        return;
    }
    BOOL canDispatch = NO;
    os_unfair_lock_lock(&_materializationLock);
    VibeMetadataStageOneFinishEnumeration(&_stageOneState);
    canDispatch = VibeMetadataStageTwoCanDispatch(
            _stageOneState, _pendingParses.count);
    os_unfair_lock_unlock(&_materializationLock);
    if (canDispatch) {
        [self dispatchStageTwoIfReady];
    }
}

- (void)dispatchStageTwoIfReady {
    [self dispatchNextScanMaterialization];
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
    NSArray<VibeMetadataParseEntry *> *pending = nil;
    NSArray<NSURL *> *neighborhood = nil;
    NSUInteger orderGeneration = 0;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanMaterializationInFlight && !_cloudParsesHeld && !self.isCancelled
            && VibeMetadataStageTwoCanDispatch(_stageOneState,
                                                _pendingParses.count)) {
        pending = [_pendingParses copy];
        neighborhood = _neighborhood;
        orderGeneration = _parseOrderGeneration;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!pending.count) {
        return;
    }

    VibeMetadataParseEntry *chosen =
            (VibeMetadataParseEntry *)VibeBestCloudParseCandidate(
            (NSArray<id<VibeCloudParseOrderCandidate>> *)pending,
            neighborhood, [NSSet set]);
    BOOL retryPick = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (_scanMaterializationInFlight || _cloudParsesHeld || self.isCancelled) {
        chosen = nil;
    }
    else if (orderGeneration != _parseOrderGeneration) {
        chosen = nil;
        retryPick = YES;
    }
    else if (chosen) {
        if ([_pendingParses containsObject:chosen]) {
            [_pendingParses removeObjectIdenticalTo:chosen];
            _parseOrderGeneration++;
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

- (void)submitScanMaterializationForEntry:(VibeMetadataParseEntry *)entry {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        BOOL requeueBehindHold = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled) {
            strongSelf->_scanMaterializationInFlight = NO;
        }
        else if (strongSelf->_cloudParsesHeld) {
            [strongSelf->_pendingParses addObject:entry];
            strongSelf->_parseOrderGeneration++;
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

- (void)completeScanMaterializationForEntry:(VibeMetadataParseEntry *)entry
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
                [_cloudAttemptsByPath removeObjectForKey:attemptKey];
            }
        }
        else {
            NSUInteger priorAttempts = attemptKey
                    ? _cloudAttemptsByPath[attemptKey].unsignedIntegerValue : 0;
            VibeMetadataMaterializationRetry retry =
                    VibeMetadataMaterializationRetryForResult(
                            result, priorAttempts,
                            _cloudMaterializationMaximumAttempts);
            if (retry != VibeMetadataMaterializationRetryNone) {
                if (retry == VibeMetadataMaterializationRetryDeferred
                        || retry == VibeMetadataMaterializationRetryDeferredAfterDelay) {
                    attempt = priorAttempts + 1;
                    entry.deferred = YES;
                    if (attemptKey) {
                        _cloudAttemptsByPath[attemptKey] = @(attempt);
                    }
                }
                if (retry == VibeMetadataMaterializationRetryDeferredAfterDelay) {
                    retryDelay = VibeMetadataAdmissionRetryDelay(priorAttempts);
                    [_delayedScanRetryEntries addObject:entry];
                    didScheduleDelayedRetry = YES;
                }
                else {
                    [_pendingParses addObject:entry];
                    _parseOrderGeneration++;
                }
                didRequeue = YES;
            }
            else if (result == VibeAudioFileMaterializationResultFailed
                    || result == VibeAudioFileMaterializationResultAdmissionExhausted) {
                attempt = priorAttempts + 1;
                if (attemptKey) {
                    _cloudAttemptsByPath[attemptKey] = @(attempt);
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
                    (unsigned long)_cloudMaterializationMaximumAttempts,
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

- (void)scheduleDelayedScanRetryForEntry:(VibeMetadataParseEntry *)entry
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
                [strongSelf->_pendingParses addObject:entry];
                strongSelf->_parseOrderGeneration++;
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
    _parseOrderGeneration++;
    os_unfair_lock_unlock(&_materializationLock);
    [self dispatchNextScanMaterialization];
}

#if DEBUG
// Declared in Debug/AudioTrackMetadataCache+Debug.h; implemented here because
// the list it counts is this file's.
- (NSUInteger)debugPendingCloudParseCount {
    if (!_isScanLane) {
        return 0;
    }
    os_unfair_lock_lock(&_materializationLock);
    NSUInteger count = _pendingParses.count + _delayedScanRetryEntries.count
            + (_scanMaterializationInFlight ? 1 : 0);
    os_unfair_lock_unlock(&_materializationLock);
    return count;
}
#endif

// The current-track lane asks the same central coordinator with the priority
// role. A same-path playback request is joined atomically; a didStart edge
// racing a Yielded callback either retries after release or parks until it.
- (void)loadSingleTrack:(AudioTrack *)track {
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
        __weak __typeof(self) weakSelf = self;
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
                            strongSelf->_cloudParsesHeld,
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
    // No thumbnail warm-up is needed before publishing, unlike in
    // parseOneTrack:. On macOS the unarchive above already decoded it, because
    // initWithCoder: hands the archived JPEG straight to the artwork, so the
    // main thread's first cachedThumbnail read after publish is a plain ivar
    // hit; on iOS there is no thumbnail to warm at all.
    //
    // This pairs with parseOneTrack's guarded store. The unconditional store
    // here is safe because cached entries are always parsedOK, but it must not
    // interleave inside that check-then-act.
    @synchronized (track) {
        track.metadata = cachedMetaData;
    }
    [self publishTrack:track];
    return YES;
}

// The stage-2 worker: the TagLib parse. The central materialization result has
// already made provider-backed content ready before this opens the audio file.
// The claim, the recheck under it and the duplicate-row fan-out are
// MetadataParseRunner's; the four steps below are what it calls back into.
- (void)parseOneTrack:(AudioTrack *)track {
    // A stale loader, cancelled when a new playlist replaced this one, must
    // not keep parsing discarded tracks and issuing synchronous cache writes
    // that the live loader's objectForKey: reads then queue behind. The runner's
    // own entry check covers a track an earlier loader or the priority lane
    // resolved while this op sat queued.
    if (self.isCancelled) {
        return;
    }
    // Keyed on the file URL, not the track: the same file can occupy several
    // playlist rows as distinct AudioTracks, and one parse must answer them
    // all. When the holder is a DIFFERENT track for the same file, skipping
    // outright would leave this row bare, since the winner's result lands on
    // its own track — so the runner registers it as a waiter and the winner fans
    // its result out once, avoiding one redundant file read per duplicate row.
    [_parseRunner runForParticipant:track key:track.url];
}

#pragma mark - MetadataParseRunnerDelegate

- (BOOL)parseRunnerIsResolved:(AudioTrack *)track {
    return track.metadata.parsedOK;
}

// Also how a duplicate row is served once the holder's parse lands: from the
// disk entry it just wrote, NOT by handing over the holder's own object. Two
// rows for the same file must own SEPARATE AudioTrackMetadata, because the art
// state on it is mutable and per-row — the current row decodes
// full-resolution art into it, and a track change discards that art again.
- (BOOL)parseRunnerServeFromCache:(AudioTrack *)track {
    return [self loadTrackFromDiskCache:track];
}

- (void)parseRunnerPublish:(AudioTrack *)track {
    [self publishTrack:track];
}

- (void)parseRunnerReadAndCache:(AudioTrack *)track {
    AudioTrackMetadataCache *owner = _owner;
    // Captured before the parse, which can block for minutes on a cloud file:
    // an invalidate arriving mid-parse makes this result stale for the cache.
    uint64_t generation = owner.cacheGeneration;
    AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:track.url];
    // Decode the row thumbnail before publication so the main thread never
    // pays ImageIO work. Folder fallback remains lazy and visibility-driven.
    // Both platforms want it — the mac playlist's art cells, the iOS library
    // rows and mini strip — while the iOS pager deliberately draws none of it
    // and decodes full size for the few pages in its window.
    [metadata prewarmEmbeddedThumbnail];
    // Never clobber real metadata with a failed parse. A cancelled loader's op
    // can still be mid-parse when this loader re-parses successfully, and
    // last-writer-wins would reinstate the filename-only fallback. The monitor
    // spans both the check and the store: unguarded, it is the same race one
    // interleave later.
    @synchronized (track) {
        if (metadata.parsedOK || !track.metadata.parsedOK) {
            track.metadata = metadata;
        }
    }
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
}

// Deliberately not gated on isCancelled: once a parse has landed on the track,
// every later loader's parsedOK checks skip it, so this publish is the only one
// the delegate will ever get — the cross-lane claim's "the winner's publish
// reaches the delegate either way". The art-byte discard must run for the same
// reason, and a departed track is dropped by the delegate's own checks.
- (void)publishTrack:(AudioTrack *)track {
    if (track.metadata) {
        // Drop the full-size art bytes, or a large first import pins hundreds
        // of MB. Cache-hit instances never carried them, and freshly parsed
        // ones now match: whatever each platform wanted decoding — the mac's
        // thumbnail, above — is decoded by now, and the full-resolution image
        // is re-read on demand for the few tracks actually shown at that size.
        [track.metadata discardArtData];
        // The folder-artwork fallback is deliberately NOT resolved here: this
        // is the scan's path, including the cache-check lane whose whole point
        // is that it blocks on nothing but a stat and a small read, and a cover
        // on a network folder would. The accessors resolve it lazily instead,
        // for the tracks actually on screen.
        run_on_main_thread({
            [self.delegate didLoadMetadata:track];
        });
    }
}

- (void)setCloudParsesHeld:(BOOL)held {
    os_unfair_lock_lock(&_materializationLock);
    _cloudParsesHeld = held;
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
        _cloudParsesHeld = YES;
        VibeMetadataStageOneCancel(&_stageOneState);
        [_pendingParses removeAllObjects];
        [_delayedScanRetryEntries removeAllObjects];
        _parseOrderGeneration++;
        [_cloudAttemptsByPath removeAllObjects];
    }
    os_unfair_lock_unlock(&_materializationLock);
    for (AudioFileMaterializationRequestToken *token in tokens) {
        [token cancel];
    }
    if (!_isScanLane) {
        run_on_main_thread({
            [self->_queuedTracks removeAllObjects];
            [self->_priorityRetryRequestedTracks removeAllObjects];
            [self->_priorityParkedTracks removeAllObjects];
            [self finishRetirementIfPossible];
        });
    }
}

@end
