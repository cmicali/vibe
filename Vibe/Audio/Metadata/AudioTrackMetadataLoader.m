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
#import "AudioTrackArtworkInternal.h"
#import "AudioFileOpenRules.h"
#import "MetadataScanOrderRules.h"
#import "MetadataRetryRules.h"
#import "MetadataParseCoordinator.h"
#import "NSURLUtil.h"

#include <os/lock.h>

// One row's record, from its stage-1 cache check through stage-2
// materialization: a plain record, never a pre-built operation. The lane
// submits at most one scan materialization at a time, so everything still
// pending remains re-rankable. The current track is the same record with its
// URL in the loader's priority set — a second in-flight slot, not a second
// lane — so playlist replacement drops it exactly as it drops every other row.
@interface MetadataScanEntry : NSObject <MetadataScanOrderCandidate>
@property (nonatomic, strong, readonly, nonnull) AudioTrack *track;
@property (nonatomic, copy, readonly, nonnull) NSURL *url;
@property (nonatomic, copy, readonly, nonnull) NSString *standardizedPath;
// The playlist row this sweep queued the track from, the comparator's
// equal-rank tie-break: without it the tail of the lane downloads in
// stage-1 completion order, which reads as random. NSNotFound for a record
// created by prioritizeTrack: outside the sweep — if it ever demotes, an
// unknown row sorting last is right.
@property (nonatomic) NSUInteger playlistIndex;
// A retry after a failed materialization. It stays at the bottom of the lane
// however the neighborhood moves, so re-ranking cannot promote a known-bad
// file back in front of tracks that have not been tried at all.
@property (nonatomic) BOOL deferred;
// The file's contents were on disk at the last probe, so its materialization
// is a no-op: it leads the ordering and is exempt from the background hold.
// Stamped at enqueue and refreshed at every submit and requeue — the playback
// open downloading this very file is the common way it flips to YES.
@property (nonatomic) BOOL local;
// A priority submission came back Yielded while the hold was up. The record
// waits — re-picking it would spin against the coordinator's synchronous
// yield — until the release edge re-judges it (MetadataRetryRules.h).
@property (nonatomic) BOOL yieldedUnderHold;
// The exact prioritizeTrack: edge this record carried when its priority slot
// was claimed. A locality probe runs without the bookkeeping lock, so its
// result may act only while this still matches the URL's current mark.
@property (nonatomic) NSUInteger priorityMarkRevision;
- (instancetype)initWithTrack:(AudioTrack *)track
                 playlistIndex:(NSUInteger)playlistIndex;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation MetadataScanEntry

- (instancetype)initWithTrack:(AudioTrack *)track
                 playlistIndex:(NSUInteger)playlistIndex {
    self = [super init];
    if (self) {
        _track = track;
        _url = [track.url copy];
        _standardizedPath = [VibeStandardizedAudioOpenPath(_url) copy];
        _playlistIndex = playlistIndex;
    }
    return self;
}

@end

@interface MetadataPriorityMark : NSObject
@property(nonatomic) NSUInteger revision;
@property(nonatomic, strong) AudioTrack *track;
@end

@implementation MetadataPriorityMark
@end

// The display-art rendition's entry beside its metadata entry, same store,
// same LRU and age terms. NSURL+Hash cache keys never contain '#'.
static NSString *VibeArchivedDisplayArtKey(NSString *cacheKey) {
    return [cacheKey stringByAppendingString:@"#displayArt"];
}

// Both platforms: the rendition is sized per platform to be quality-equivalent
// to the display decode it stands in for (PlatformImage.m), so the mac header
// and the iOS now-playing page both re-show art without re-reading — or, on a
// dataless cloud file, re-downloading — the song. Stamped on every art-bearing
// row, thumbnail bytes or not: an entry whose 128px re-encode failed at parse
// has ONLY the rendition to recover its row thumbnail from, and a row with no
// sidecar either merely pays one empty read before extraction.
static void VibeInstallArchivedDisplayArtProvider(AudioTrackMetadata *metadata,
                                                  PINCache *metadataCache,
                                                  NSString *cacheKey) {
    if (!metadata.artwork.hasEmbeddedArt) {
        return;
    }
    NSString *sidecarKey = VibeArchivedDisplayArtKey(cacheKey);
    __weak PINCache *weakCache = metadataCache;
    metadata.artwork.archivedDisplayArtProvider = ^NSData *{
        // Blocking disk read on a registry worker; a departed cache reads as
        // a missing sidecar and the load falls back to extraction.
        PINCache *cache = weakCache;
        NSData *data = (NSData *)[cache.diskCache objectForKey:sidecarKey];
        // PINCache unarchives without secure coding; treat a wrong class as
        // absent rather than handing it to ImageIO.
        return [data isKindOfClass:[NSData class]] ? data : nil;
    };
}

@interface AudioTrackMetadataLoader ()
- (nullable AudioTrackMetadata *)readCachedMetadataForTrack:(AudioTrack *)track;
- (void)retirePriorityMarkSatisfiedByTrack:(AudioTrack *)track;
- (void)finishCarrierForTrack:(AudioTrack *)track;
- (void)finishParseOperation:(NSOperation *)operation forTrack:(AudioTrack *)track;
- (void)dropRecordsForExhaustedPathLocked:(NSString * _Nonnull)path
                             currentTrack:(AudioTrack * _Nonnull)track;
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
    // since. Guarded by _materializationLock: load:'s setup op and
    // prioritizeTrack: (main) both touch it.
    NSMutableSet<AudioTrack *>* _queuedTracks;
    // Tracks whose stage-1 record, materialization, or parse attempt can still
    // settle a priority mark. Once its carrier finishes, a fresh priority edge
    // mints a new cache-check record; the central coordinators absorb any
    // same-path materialization or parse already owned by another loader.
    // Guarded by _materializationLock.
    NSMutableSet<AudioTrack *>* _tracksWithCarrier;
    // Queued and running parses by exact track identity. Priority can arrive
    // after Ready enqueues a utility operation, so that operation must remain
    // reachable for promotion. Guarded by _materializationLock.
    NSMapTable<AudioTrack *, NSOperation *> *_parseOperationsByTrack;
    // Every scan cache miss takes this provider-independent path. Entries stay
    // app-owned until one exact pick is atomically registered with the shared
    // materialization coordinator.
    NSMutableArray<MetadataScanEntry *>* _pendingMaterializations;
    // Admission-exhausted entries waiting for their bounded eligibility edge.
    // A set makes cancellation observable to the delayed block and keeps the
    // debug pending count honest while no coordinator request exists.
    NSMutableSet<MetadataScanEntry *>* _delayedScanRetryEntries;
    // The URLs whose records are priority: picked through their own slot,
    // exempt from the stage-1 barrier, submitted while the hold is up, parsed
    // user-initiated. The single source of that fact — demotion is removal —
    // so the picker reads it live and a stale mark cannot survive. Guarded by
    // _materializationLock; bounded by the tracks a shell prioritizes (~1-2).
    NSMutableSet<NSURL *>* _priorityURLs;
    NSMutableDictionary<NSURL *, MetadataPriorityMark *> *_priorityMarks;
    NSUInteger _nextPriorityMarkRevision;
    BOOL _scanMaterializationInFlight;
    BOOL _priorityMaterializationInFlight;
    // The two loader-owned slots must never join the same coordinator claim.
    // A provider failure is one path attempt even when a claim has waiters;
    // two callbacks from this loader would otherwise charge it twice.
    NSString *_scanMaterializationPath;
    NSString *_priorityMaterializationPath;
    BOOL _scanDispatchKickPending;
    // Bumped by every pending-list or neighborhood mutation. The picker works
    // outside the lock, then verifies this snapshot before removing its choice.
    NSUInteger _scanOrderGeneration;
    // The setup barrier flips this only after every cache check ahead of it
    // has settled, so no audio-file work can steal a worker from stage 1.
    // Priority picks are deliberately exempt: a loader created by a pre-sweep
    // prioritizeTrack: never runs load: at all.
    BOOL _stageOneFinished;
    NSArray<NSURL *>* _neighborhood;   // rank order; empty until a screen names one
    // One coalesced 1s re-pick while the foreground rule gates work: the
    // coordinator has no release edge to deliver (suspension derives from its
    // claim table), so a picker that found only gated candidates re-asks on a
    // bounded clock. The same tick re-judges priority records a yield made
    // wait. Guarded by _materializationLock.
    BOOL _gatedRepickPending;
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
    AudioFileMaterializationRequestToken *_priorityMaterializationToken;
    MetadataParseCoordinator *_parseCoordinator;
    VibeAudioTrackMetadataCacheReader _cacheReader;
    VibeAudioTrackMetadataFileParser _fileParser;
#if DEBUG
    dispatch_block_t _debugBeforeScanPickValidation;
    NSQualityOfService _debugLastScheduledParseQualityOfService;
#endif
}

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    return [self initWithOwner:owner
                      delegate:delegate
          loadingConfiguration:loadingConfiguration
     materializationCoordinator:[AudioFileMaterializationCoordinator sharedCoordinator]
                    cacheReader:nil
                     fileParser:nil];
}

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration
    materializationCoordinator:(AudioFileMaterializationCoordinator *)materializationCoordinator
                   cacheReader:(VibeAudioTrackMetadataCacheReader)cacheReader
                    fileParser:(VibeAudioTrackMetadataFileParser)fileParser {
    self = [super init];
    if (self) {
        NSParameterAssert(loadingConfiguration);
        NSParameterAssert(materializationCoordinator);
        _isCancelled = NO;
        _owner = owner;
        _queuedTracks = [NSMutableSet set];
        _tracksWithCarrier = [NSMutableSet set];
        _parseOperationsByTrack = [NSMapTable strongToStrongObjectsMapTable];
        _priorityURLs = [NSMutableSet set];
        _priorityMarks = [NSMutableDictionary dictionary];
        _materializationLock = OS_UNFAIR_LOCK_INIT;
        _materializationCoordinator = materializationCoordinator;
        _liveMaterializationTokens = [NSMutableSet set];
        _materializationMaximumAttempts =
                VibeMetadataMaximumAttemptsForRetryCount(
                        loadingConfiguration.metadataRetryCount);
        _parseCoordinator = owner.parseCoordinator;
        _cacheReader = [cacheReader copy];
        _fileParser = [fileParser copy];
        _delegate = delegate;
        _materializationAttemptsByPath = [NSMutableDictionary dictionary];
        // Configurable concurrency lets a single slow file, on a network
        // mount or a sleeping disk, stall only its own worker rather than
        // the whole playlist. Utility is the queue's band — the work drives
        // the playlist UI but is not user-initiated; the current track's
        // parse rides the same queue at user-initiated per-operation QoS.
        _queue = [[NSOperationQueue alloc] init];
        _queue.name = @"AudioTrackMetadataLoader";
        _queue.maxConcurrentOperationCount =
                (NSInteger)loadingConfiguration.localMetadataParseConcurrency;
        _queue.qualityOfService = NSQualityOfServiceUtility;
        _pendingMaterializations = [NSMutableArray array];
        _delayedScanRetryEntries = [NSMutableSet set];
        _neighborhood = @[];
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _materializationCallbackQueue = dispatch_queue_create(
                "com.vibe.metadata-scan-materialization", attributes);
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
            // A track appearing twice in the array must not parse twice, and a
            // track prioritizeTrack: already queued must not requeue.
            BOOL alreadyQueued;
            os_unfair_lock_lock(&setupSelf->_materializationLock);
            alreadyQueued = [setupSelf->_queuedTracks containsObject:track];
            if (!alreadyQueued) {
                [setupSelf->_queuedTracks addObject:track];
                [setupSelf->_tracksWithCarrier addObject:track];
            }
            os_unfair_lock_unlock(&setupSelf->_materializationLock);
            if (alreadyQueued) continue;
            MetadataScanEntry *entry = [[MetadataScanEntry alloc]
                    initWithTrack:track playlistIndex:index];
            [worklist addObject:entry];
        }
        [setupSelf enqueueStageOneWorkersForWorklist:worklist];
        [setupSelf->_queue addBarrierBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            BOOL shouldDispatch = NO;
            NSUInteger missCount = 0;
            os_unfair_lock_lock(&strongSelf->_materializationLock);
            if (!strongSelf.isCancelled) {
                strongSelf->_stageOneFinished = YES;
                missCount = strongSelf->_pendingMaterializations.count;
                shouldDispatch = missCount > 0;
            }
            os_unfair_lock_unlock(&strongSelf->_materializationLock);
            LogInfo(@"Metadata sweep stage 1 done: %lu cache misses pending",
                    (unsigned long)missCount);
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
        [self finishCarrierForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    if ([self loadTrackFromDiskCache:track]) {
        [self finishCarrierForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    if (self.isCancelled) {
        return;
    }
    [self enqueueScanMaterialization:entry];
}

#pragma mark - The materialization lane

- (void)enqueueScanMaterialization:(MetadataScanEntry *)entry {
    entry.local = ![NSURLUtil isDatalessFile:entry.url];
    BOOL kick = NO;
    BOOL dropped = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (!self.isCancelled) {
        NSString *path = entry.standardizedPath;
        if (_materializationAttemptsByPath[path].unsignedIntegerValue
                >= _materializationMaximumAttempts) {
            [self dropRecordsForExhaustedPathLocked:path
                                      currentTrack:entry.track];
            dropped = YES;
        }
        else {
            [_pendingMaterializations addObject:entry];
            _scanOrderGeneration++;
            // A priority record must not wait for the stage-1 barrier the way
            // the sweep's picks do.
            kick = _priorityMarks[entry.url].track == entry.track;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (kick || dropped) {
        [self dispatchNextScanMaterialization];
    }
}

// Marks the track's URL priority and makes sure a record exists to carry it.
// The set is the live decision; each mark's revision and target identity let a
// record prove which edge it carried across an off-lock probe or completion.
// Three cases: a pending/delayed record is reactivated for one submission; a
// mid-flight or mid-stage-1 record adopts the mark at completion/enqueue; an
// unknown track gets its own high-priority cache check, then a record.
- (void)prioritizeTrack:(AudioTrack *)track {
    if (track.metadata.parsedOK) {
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    NSURL *url = track.url;
    if (!url) {
        return;
    }
    BOOL alreadyQueued;
    BOOL needsCarrier;
    NSOperation *parseOperation;
    os_unfair_lock_lock(&_materializationLock);
    MetadataPriorityMark *mark = [[MetadataPriorityMark alloc] init];
    mark.revision = ++_nextPriorityMarkRevision;
    mark.track = track;
    [_priorityURLs addObject:url];
    _priorityMarks[url] = mark;
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (entry.track == track) {
            entry.priorityMarkRevision = mark.revision;
            entry.yieldedUnderHold = NO;
        }
    }
    for (MetadataScanEntry *entry in [_delayedScanRetryEntries copy]) {
        if (entry.track == track) {
            [_delayedScanRetryEntries removeObject:entry];
            entry.priorityMarkRevision = mark.revision;
            entry.yieldedUnderHold = NO;
            [_pendingMaterializations addObject:entry];
        }
    }
    _scanOrderGeneration++;
    alreadyQueued = [_queuedTracks containsObject:track];
    if (!alreadyQueued) {
        [_queuedTracks addObject:track];
    }
    needsCarrier = ![_tracksWithCarrier containsObject:track];
    if (needsCarrier) {
        [_tracksWithCarrier addObject:track];
    }
    parseOperation = [_parseOperationsByTrack objectForKey:track];
    if (parseOperation) {
        parseOperation.qualityOfService = NSQualityOfServiceUserInitiated;
        parseOperation.queuePriority = NSOperationQueuePriorityHigh;
#if DEBUG
        _debugLastScheduledParseQualityOfService =
                NSQualityOfServiceUserInitiated;
#endif
    }
    os_unfair_lock_unlock(&_materializationLock);
    // Closes install-before-mark: a cache/parse winner that retired just
    // before registration made the first parsedOK sample stale.
    if (track.metadata.parsedOK) {
        [self finishCarrierForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    LogDebug(@"Priority load %@%@", url.lastPathComponent,
             alreadyQueued ? @": already queued" : @"");
    if (!needsCarrier) {
        // A pending/delayed record was reactivated above. An in-flight or
        // mid-stage-1 record adopts the mark at completion or enqueue.
        [self dispatchNextScanMaterialization];
        return;
    }
    __weak __typeof(self) weakSelf = self;
    NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }
        if (track.metadata.parsedOK) {
            [strongSelf finishCarrierForTrack:track];
            [strongSelf retirePriorityMarkSatisfiedByTrack:track];
            return;
        }
        if ([strongSelf loadTrackFromDiskCache:track]) {
            [strongSelf finishCarrierForTrack:track];
            [strongSelf retirePriorityMarkSatisfiedByTrack:track];
            return;
        }
        MetadataScanEntry *entry = [[MetadataScanEntry alloc]
                initWithTrack:track playlistIndex:NSNotFound];
        [strongSelf enqueueScanMaterialization:entry];
        [strongSelf dispatchNextScanMaterialization];
    }];
    op.queuePriority = NSOperationQueuePriorityHigh;
    op.qualityOfService = NSQualityOfServiceUserInitiated;
    [_queue addOperation:op];
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
    // Sampled once per pass, off the lock: the coordinator's answer is a
    // snapshot either way, and a submission that races a rising edge is
    // yielded at admission, spending nothing.
    BOOL suspended = [_materializationCoordinator isForegroundTransferActive];
    // A yielded record must be judged before any idle pick, not only by the
    // one-second clock. Otherwise an unrelated kick in the release gap can
    // resubmit a still-dataless old priority instead of demoting it.
    if (!suspended) {
        [self judgeWaitingPriorityRecordsWhileHeld:NO];
    }
    // The priority slot first: at most one priority materialization runs
    // beside the scan's one, so the current track never waits for the sweep's
    // transfer — D3's "ahead of the sweep" is a second slot, not a queue jump.
    MetadataScanEntry *priorityPick = nil;
    os_unfair_lock_lock(&_materializationLock);
    if (!_priorityMaterializationInFlight && !self.isCancelled) {
        NSMutableArray<MetadataScanEntry *> *targeted = [NSMutableArray array];
        for (MetadataScanEntry *entry in _pendingMaterializations) {
            if (_priorityMarks[entry.url].track == entry.track
                    && ![entry.standardizedPath
                            isEqualToString:_scanMaterializationPath]) {
                [targeted addObject:entry];
            }
        }
        priorityPick = (MetadataScanEntry *)VibeBestPriorityScanCandidate(
                (NSArray<id<MetadataScanOrderCandidate>> *)targeted,
                _priorityURLs, suspended);
        if (priorityPick) {
            [_pendingMaterializations removeObjectIdenticalTo:priorityPick];
            _scanOrderGeneration++;
            _priorityMaterializationInFlight = YES;
            _priorityMaterializationPath = priorityPick.standardizedPath;
            priorityPick.priorityMarkRevision =
                    _priorityMarks[priorityPick.url].revision;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (priorityPick) {
        [self submitMaterializationForEntry:priorityPick priority:YES];
    }

    NSArray<MetadataScanEntry *> *pending = nil;
    NSArray<NSURL *> *neighborhood = nil;
    NSSet<NSURL *> *priorityURLs = nil;
    NSString *priorityMaterializationPath = nil;
    NSUInteger orderGeneration = 0;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanMaterializationInFlight && !self.isCancelled
            && _stageOneFinished && _pendingMaterializations.count > 0) {
        pending = [_pendingMaterializations copy];
        neighborhood = _neighborhood;
        priorityURLs = [_priorityURLs copy];
        priorityMaterializationPath = [_priorityMaterializationPath copy];
        orderGeneration = _scanOrderGeneration;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (priorityURLs.count) {
        // Priority records belong to the priority slot alone; the sweep's
        // pick must not consume one and bill its transfer to the scan slot.
        pending = [pending filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(MetadataScanEntry *entry,
                                                      NSDictionary *bindings) {
            return ![priorityURLs containsObject:entry.url];
        }]];
    }
    if (priorityMaterializationPath) {
        pending = [pending filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(MetadataScanEntry *entry,
                                                      NSDictionary *bindings) {
            return ![entry.standardizedPath
                    isEqualToString:priorityMaterializationPath];
        }]];
    }
    if (suspended) {
        // The rule suspends provider transfers, which a local entry never
        // starts — so already-downloaded rows keep parsing while the open the
        // user is waiting on has the wire to itself (D6/J4: the sweep submits
        // no dataless record at all while suspended, even one C3 would join).
        pending = [pending filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(MetadataScanEntry *entry,
                                                      NSDictionary *bindings) {
            return entry.local;
        }]];
    }
    if (!pending.count) {
        [self scheduleGatedRepickIfNeededWhileSuspended:suspended];
        return;
    }

    MetadataScanEntry *chosen =
            (MetadataScanEntry *)VibeBestMetadataScanCandidate(
            (NSArray<id<MetadataScanOrderCandidate>> *)pending,
            neighborhood);
#if DEBUG
    dispatch_block_t beforeValidation = nil;
    os_unfair_lock_lock(&_materializationLock);
    beforeValidation = [_debugBeforeScanPickValidation copy];
    os_unfair_lock_unlock(&_materializationLock);
    if (beforeValidation) {
        beforeValidation();
    }
#endif
    BOOL retryPick = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (_scanMaterializationInFlight || self.isCancelled
            || (suspended && !chosen.local)) {
        chosen = nil;
    }
    else if (orderGeneration != _scanOrderGeneration
            || (chosen && [_priorityURLs containsObject:chosen.url])
            || (chosen && [chosen.standardizedPath
                    isEqualToString:_priorityMaterializationPath])) {
        chosen = nil;
        retryPick = YES;
    }
    else if (chosen) {
        if ([_pendingMaterializations containsObject:chosen]) {
            [_pendingMaterializations removeObjectIdenticalTo:chosen];
            _scanOrderGeneration++;
            _scanMaterializationInFlight = YES;
            _scanMaterializationPath = chosen.standardizedPath;
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
        [self scheduleGatedRepickIfNeededWhileSuspended:suspended];
        return;
    }
    [self submitMaterializationForEntry:chosen priority:NO];
}

// The bounded clock that replaces the hold's release edge. While the rule
// gates work — dataless scan records suspended, or a priority record a yield
// made wait — one coalesced re-pick per second re-asks the coordinator.
// Every tick re-judges the waiting priority records: one the open made local
// retries at once, gated or not (its parse starts no transfer), while a
// still-dataless one waits and demotes to the sweep only at the first idle
// tick. A millisecond gap between rapid nexts cannot flap the sweep: the
// tick simply finds the foreground active again.
- (void)scheduleGatedRepickIfNeededWhileSuspended:(BOOL)suspended {
    if (!suspended) {
        return;
    }
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (!_gatedRepickPending && !self.isCancelled
            && (_pendingMaterializations.count > 0
                    || _delayedScanRetryEntries.count > 0)) {
        _gatedRepickPending = YES;
        shouldSchedule = YES;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!shouldSchedule) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   _materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        strongSelf->_gatedRepickPending = NO;
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled) {
            return;
        }
        [strongSelf recheckForegroundGate];
    });
}

- (void)recheckForegroundGate {
    if (self.isCancelled) {
        return;
    }
    [self judgeWaitingPriorityRecordsWhileHeld:
            [_materializationCoordinator isForegroundTransferActive]];
    [self dispatchNextScanMaterialization];
}

// The waiting records' re-judgement, run every gated tick: a record whose
// file the open made local retries at once — its parse starts no transfer,
// so it must not wait out an unrelated foreground download (the successor's
// prefetch, measured holding the current track's art for its whole
// transfer). A still-dataless record waits while the rule holds and demotes
// at the first idle tick — re-downloading a dead pick behind its error UI is
// the sweep's call to make, at its rank. Probing is I/O, so it happens off
// the lock. The mark revision is revalidated after the probe so a new
// prioritizeTrack: edge cannot be removed by the old mark's judgement.
- (void)judgeWaitingPriorityRecordsWhileHeld:(BOOL)held {
    NSMutableArray<MetadataScanEntry *> *waiting = [NSMutableArray array];
    NSMutableArray<NSNumber *> *markRevisions = [NSMutableArray array];
    os_unfair_lock_lock(&_materializationLock);
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (entry.yieldedUnderHold
                && _priorityMarks[entry.url].track == entry.track) {
            [waiting addObject:entry];
            [markRevisions addObject:@(entry.priorityMarkRevision)];
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    for (NSUInteger index = 0; index < waiting.count; index++) {
        MetadataScanEntry *entry = waiting[index];
        NSUInteger markRevision = markRevisions[index].unsignedIntegerValue;
        BOOL local = ![NSURLUtil isDatalessFile:entry.url];
        BOOL demoted = NO;
        os_unfair_lock_lock(&_materializationLock);
        BOOL stillPending = [_pendingMaterializations containsObject:entry];
        BOOL sameEntryMark = entry.priorityMarkRevision == markRevision;
        MetadataPriorityMark *currentMark = _priorityMarks[entry.url];
        BOOL sameCurrentMark = currentMark.track == entry.track
                && currentMark.revision == markRevision;
        if (!stillPending || !entry.yieldedUnderHold || !sameEntryMark) {
            os_unfair_lock_unlock(&_materializationLock);
            continue;
        }
        entry.local = local;
        VibeMetadataPriorityYieldOutcome outcome =
                VibeMetadataPriorityAfterYield(held, local);
        if (!sameCurrentMark) {
            // A fresh mark supersedes this probe. prioritizeTrack: already
            // reactivated its target; the old probe cannot park or demote it.
            os_unfair_lock_unlock(&_materializationLock);
            continue;
        }
        switch (outcome) {
            case VibeMetadataPriorityYieldWait:
                break;
            case VibeMetadataPriorityYieldRetry:
                entry.yieldedUnderHold = NO;
                break;
            case VibeMetadataPriorityYieldDemote:
                entry.yieldedUnderHold = NO;
                [_priorityURLs removeObject:entry.url];
                [_priorityMarks removeObjectForKey:entry.url];
                _scanOrderGeneration++;
                demoted = YES;
                break;
        }
        os_unfair_lock_unlock(&_materializationLock);
        if (demoted) {
            LogInfo(@"Priority record %@ still dataless once the foreground settled — left to the sweep",
                    entry.url.lastPathComponent);
        }
    }
}

- (void)submitMaterializationForEntry:(MetadataScanEntry *)entry
                             priority:(BOOL)priority {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_materializationCallbackQueue, ^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Re-probed at every submit: a rule that rose since the pick must not
        // requeue an entry whose file is on disk, and the playback open
        // downloading this very file is the common way local flips to YES.
        entry.local = ![NSURLUtil isDatalessFile:entry.url];
        BOOL suspended = !priority && !entry.local
                && [strongSelf->_materializationCoordinator isForegroundTransferActive];
        BOOL requeueBehindRule = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        if (strongSelf.isCancelled) {
            if (priority) {
                strongSelf->_priorityMaterializationInFlight = NO;
                strongSelf->_priorityMaterializationPath = nil;
            }
            else {
                strongSelf->_scanMaterializationInFlight = NO;
                strongSelf->_scanMaterializationPath = nil;
            }
        }
        else if (suspended) {
            // Scan picks only: a priority submission goes through even while
            // the rule is in force — a same-path playback claim serves it
            // with no second transfer, and the coordinator yields it
            // otherwise (D6/J4).
            [strongSelf->_pendingMaterializations addObject:entry];
            strongSelf->_scanOrderGeneration++;
            strongSelf->_scanMaterializationInFlight = NO;
            strongSelf->_scanMaterializationPath = nil;
            requeueBehindRule = YES;
        }
        BOOL shouldSubmit = !strongSelf.isCancelled && !requeueBehindRule;
        NSUInteger stillPending = strongSelf->_pendingMaterializations.count;
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (requeueBehindRule) {
            [strongSelf scheduleGatedRepickIfNeededWhileSuspended:YES];
        }
        if (!shouldSubmit) {
            return;
        }
        LogInfo(@"Metadata %@ materializing %@ (%lu pending behind it)",
                priority ? @"priority" : @"scan",
                entry.url.lastPathComponent, (unsigned long)stillPending);

        __block __weak AudioFileMaterializationRequestToken *weakToken = nil;
        AudioFileMaterializationRequestToken *token =
                [strongSelf->_materializationCoordinator
                        materializeURL:entry.url
                                  role:priority
                                          ? VibeAudioFileMaterializationRoleMetadataPriority
                                          : VibeAudioFileMaterializationRoleMetadataScan
                       completionQueue:strongSelf->_materializationCallbackQueue
                            completion:^(VibeAudioFileMaterializationResult result,
                                         NSError *error,
                                         NSTimeInterval elapsed) {
            [weakSelf completeMaterializationForEntry:entry
                                             priority:priority
                                                token:weakToken
                                               result:result
                                                error:error
                                              elapsed:elapsed];
        }];
        weakToken = token;

        BOOL cancelToken = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        BOOL slotStillOurs = priority ? strongSelf->_priorityMaterializationInFlight
                                      : strongSelf->_scanMaterializationInFlight;
        if (strongSelf.isCancelled || !slotStillOurs) {
            cancelToken = YES;
        }
        else {
            if (priority) {
                strongSelf->_priorityMaterializationToken = token;
            }
            else {
                strongSelf->_scanMaterializationToken = token;
            }
            [strongSelf->_liveMaterializationTokens addObject:token];
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (cancelToken) {
            [token cancel];
        }
    });
}

- (void)completeMaterializationForEntry:(MetadataScanEntry *)entry
                               priority:(BOOL)priority
                                  token:(AudioFileMaterializationRequestToken *)token
                                 result:(VibeAudioFileMaterializationResult)result
                                  error:(NSError *)error
                                elapsed:(NSTimeInterval)elapsed {
    BOOL shouldParse = NO;
    BOOL didRequeue = NO;
    BOOL didScheduleDelayedRetry = NO;
    BOOL demoted = NO;
    BOOL satisfiesCurrentPriority = NO;
    NSTimeInterval retryDelay = 0;
    NSUInteger attempt = 0;
    NSString *attemptKey = entry.standardizedPath;

    // A requeued entry re-ranks on fresh locality: the yield that parked it is
    // often the playback open downloading this same file. Probed before the
    // lock — the stat is cheap but is still I/O — as is the rule sample the
    // priority triage below judges against.
    entry.local = ![NSURLUtil isDatalessFile:entry.url];
    BOOL suspended = priority && result == VibeAudioFileMaterializationResultYielded
            && [_materializationCoordinator isForegroundTransferActive];
    os_unfair_lock_lock(&_materializationLock);
    AudioFileMaterializationRequestToken *slotToken =
            priority ? _priorityMaterializationToken : _scanMaterializationToken;
    if (slotToken != token) {
        [_liveMaterializationTokens removeObject:token];
        os_unfair_lock_unlock(&_materializationLock);
        return;
    }
    [_liveMaterializationTokens removeObject:token];
    if (priority) {
        _priorityMaterializationToken = nil;
        _priorityMaterializationInFlight = NO;
        _priorityMaterializationPath = nil;
    }
    else {
        _scanMaterializationToken = nil;
        _scanMaterializationInFlight = NO;
        _scanMaterializationPath = nil;
    }
    if (!self.isCancelled) {
        if (result == VibeAudioFileMaterializationResultReady) {
            shouldParse = YES;
            entry.yieldedUnderHold = NO;
            if (_priorityMarks[entry.url].track == entry.track) {
                satisfiesCurrentPriority = YES;
                [_priorityURLs removeObject:entry.url];
                [_priorityMarks removeObjectForKey:entry.url];
                _scanOrderGeneration++;
            }
            if (attemptKey) {
                [_materializationAttemptsByPath removeObjectForKey:attemptKey];
            }
        }
        else if (priority && result == VibeAudioFileMaterializationResultYielded) {
            // The priority record's own yield triage (MetadataRetryRules.h):
            // wait out the hold, retry a file the open made local, or demote
            // a still-dataless one to an ordinary sweep candidate. Yields
            // spend no budget either way.
            VibeMetadataPriorityYieldOutcome outcome =
                    VibeMetadataPriorityAfterYield(suspended, entry.local);
            MetadataPriorityMark *currentMark = _priorityMarks[entry.url];
            BOOL sameCurrentMark = currentMark.track == entry.track
                    && currentMark.revision == entry.priorityMarkRevision;
            if (!sameCurrentMark) {
                // The completed request carried an older mark. Preserve and
                // reactivate the newer edge for exactly one submission.
                entry.yieldedUnderHold = NO;
            }
            else {
                switch (outcome) {
                    case VibeMetadataPriorityYieldWait:
                        entry.yieldedUnderHold = YES;
                        break;
                    case VibeMetadataPriorityYieldRetry:
                        entry.yieldedUnderHold = NO;
                        break;
                    case VibeMetadataPriorityYieldDemote:
                        entry.yieldedUnderHold = NO;
                        [_priorityURLs removeObject:entry.url];
                        [_priorityMarks removeObjectForKey:entry.url];
                        _scanOrderGeneration++;
                        demoted = YES;
                        break;
                }
            }
            [_pendingMaterializations addObject:entry];
            _scanOrderGeneration++;
            didRequeue = YES;
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
                // D7 is per path, across both slots and duplicate rows. Once
                // exhausted, the path and any priority mark for it are dropped
                // until a fresh playlist loader supplies a fresh ledger.
                [self dropRecordsForExhaustedPathLocked:attemptKey
                                          currentTrack:entry.track];
            }
        }
    }
    os_unfair_lock_unlock(&_materializationLock);

    if (shouldParse) {
        __weak __typeof(self) weakSelf = self;
        __block __weak NSOperation *weakParse = nil;
        NSOperation *parse = [NSBlockOperation blockOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf) {
                if (!strongSelf.isCancelled) {
                    [strongSelf parseOneTrack:entry.track];
                }
                [strongSelf finishParseOperation:weakParse forTrack:entry.track];
            }
        }];
        weakParse = parse;
        BOOL userInitiatedParse = priority || satisfiesCurrentPriority;
        parse.qualityOfService = userInitiatedParse
                ? NSQualityOfServiceUserInitiated : NSQualityOfServiceUtility;
        if (userInitiatedParse) {
            // The user is looking at a header waiting on this exact parse.
            parse.queuePriority = NSOperationQueuePriorityHigh;
        }
        os_unfair_lock_lock(&_materializationLock);
        // Closes Ready-to-enqueue: prioritizeTrack: may install a mark after
        // the completion decision above but before this operation exists.
        if (_priorityMarks[entry.url].track == entry.track) {
            userInitiatedParse = YES;
            parse.qualityOfService = NSQualityOfServiceUserInitiated;
            parse.queuePriority = NSOperationQueuePriorityHigh;
        }
        [_parseOperationsByTrack setObject:parse forKey:entry.track];
#if DEBUG
        _debugLastScheduledParseQualityOfService = parse.qualityOfService;
#endif
        os_unfair_lock_unlock(&_materializationLock);
        [_queue addOperation:parse];
        LogInfo(@"Metadata %@ materialized %@ in %.1fs",
                userInitiatedParse ? @"priority" : @"scan",
                entry.url.lastPathComponent, elapsed);
    }
    else if (result == VibeAudioFileMaterializationResultYielded) {
        LogInfo(@"Metadata %@ yielded %@ after %.1fs%@",
                priority ? @"priority" : @"scan",
                entry.url.lastPathComponent, elapsed,
                demoted ? @" — still dataless, left to the sweep" : @"");
    }
    else if (result == VibeAudioFileMaterializationResultFailed
            || result == VibeAudioFileMaterializationResultAdmissionExhausted) {
        if (didRequeue) {
            LogWarn(@"Metadata materialization failed for %@ "
                    @"(attempt %lu of %lu); re-queued last (%@)",
                    entry.url.lastPathComponent, (unsigned long)attempt,
                    (unsigned long)_materializationMaximumAttempts,
                    error.localizedDescription);
        }
        else {
            LogWarn(@"Metadata materialization failed for %@ and is out of attempts (%@)",
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
    os_unfair_lock_lock(&_materializationLock);
    _neighborhood = [urls copy] ?: @[];
    _scanOrderGeneration++;
    os_unfair_lock_unlock(&_materializationLock);
    [self dispatchNextScanMaterialization];
}

#if DEBUG
// Used by AudioTrackMetadataCache's debug surface; the list lives here.
- (NSUInteger)debugPendingBackgroundMaterializationCount {
    os_unfair_lock_lock(&_materializationLock);
    NSUInteger count = _pendingMaterializations.count + _delayedScanRetryEntries.count
            + (_scanMaterializationInFlight ? 1 : 0)
            + (_priorityMaterializationInFlight ? 1 : 0);
    os_unfair_lock_unlock(&_materializationLock);
    return count;
}

- (NSDictionary *)debugPriorityLaneState {
    BOOL held = [_materializationCoordinator isForegroundTransferActive];
    NSMutableArray *pendingNames = [NSMutableArray array];
    NSUInteger yielded = 0;
    NSUInteger tokens;
    BOOL inFlight;
    os_unfair_lock_lock(&_materializationLock);
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (_priorityMarks[entry.url].track == entry.track) {
            [pendingNames addObject:entry.url.lastPathComponent ?: @"?"];
            if (entry.yieldedUnderHold) {
                yielded++;
            }
        }
    }
    tokens = _priorityMaterializationToken != nil ? 1 : 0;
    inFlight = _priorityMaterializationInFlight;
    os_unfair_lock_unlock(&_materializationLock);
    return @{@"pending": pendingNames,
             @"yieldedUnderHold": @(yielded),
             @"inFlight": @(inFlight),
             @"liveTokens": @(tokens),
             @"held": @(held)};
}

- (NSDictionary *)debugScanLaneState {
    NSMutableArray<NSString *> *pendingNames = [NSMutableArray array];
    NSMutableArray<NSString *> *delayedNames = [NSMutableArray array];
    BOOL inFlight;
    NSUInteger tokens;
    BOOL stageOneFinished;
    os_unfair_lock_lock(&_materializationLock);
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (_priorityMarks[entry.url].track != entry.track) {
            [pendingNames addObject:entry.url.lastPathComponent ?: @"?"];
        }
    }
    for (MetadataScanEntry *entry in _delayedScanRetryEntries) {
        if (_priorityMarks[entry.url].track != entry.track) {
            [delayedNames addObject:entry.url.lastPathComponent ?: @"?"];
        }
    }
    inFlight = _scanMaterializationInFlight;
    tokens = _scanMaterializationToken != nil ? 1 : 0;
    stageOneFinished = _stageOneFinished;
    os_unfair_lock_unlock(&_materializationLock);
    return @{@"pending": pendingNames,
             @"delayed": delayedNames,
             @"inFlight": @(inFlight),
             @"liveTokens": @(tokens),
             @"stageOneFinished": @(stageOneFinished)};
}

- (void)debugSetBeforeScanPickValidation:(dispatch_block_t)block {
    os_unfair_lock_lock(&_materializationLock);
    _debugBeforeScanPickValidation = [block copy];
    os_unfair_lock_unlock(&_materializationLock);
}

- (NSQualityOfService)debugLastScheduledParseQualityOfService {
    os_unfair_lock_lock(&_materializationLock);
    NSQualityOfService qualityOfService = _debugLastScheduledParseQualityOfService;
    os_unfair_lock_unlock(&_materializationLock);
    return qualityOfService;
}

- (NSQualityOfService)debugParseQualityOfServiceForTrack:(AudioTrack *)track {
    os_unfair_lock_lock(&_materializationLock);
    NSOperation *operation = [_parseOperationsByTrack objectForKey:track];
    NSQualityOfService qualityOfService = operation
            ? operation.qualityOfService : NSQualityOfServiceDefault;
    os_unfair_lock_unlock(&_materializationLock);
    return qualityOfService;
}
#endif

// The one disk-cache I/O boundary. It deliberately touches only file
// attributes and the cache store, never the audio data, because the sweep
// relies on it staying fast for dataless cloud files.
- (AudioTrackMetadata *)readCachedMetadataForTrack:(AudioTrack *)track {
    if (_cacheReader) {
        return _cacheReader(track);
    }
    // nil when the file cannot be statted; see NSURL+Hash. Without a stable
    // identity there is no cache read. The stage-2 parse still runs, and an
    // unreadable file degrades to the filename-only fallback, parsedOK == NO.
    NSString *cacheKey = track.cacheKey;
    if (!cacheKey) {
        LogWarn(@"No cache key for %@ — loading metadata uncached", track.url.path);
        return nil;
    }
    // Re-read at use time; see _owner. nil merely means not yet constructed,
    // so the earliest tracks parse uncached rather than the whole playlist.
    PINCache *metadataCache = _owner.metadataCache;
    if (!metadataCache) {
        LogWarn(@"Metadata cache not yet available — loading %@ uncached", track.url.path);
        return nil;
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
        [metadataCache.diskCache removeObjectForKey:VibeArchivedDisplayArtKey(cacheKey)];
        cachedMetaData = nil;
    }
    if (!cachedMetaData) {
        return nil;
    }
    VibeInstallArchivedDisplayArtProvider(cachedMetaData, metadataCache, cacheKey);
    return cachedMetaData;
}

- (void)retirePriorityMarkSatisfiedByTrack:(AudioTrack *)track {
    NSURL *url = track.url;
    BOOL retired = NO;
    os_unfair_lock_lock(&_materializationLock);
    if (_priorityMarks[url].track == track) {
        [_priorityURLs removeObject:url];
        [_priorityMarks removeObjectForKey:url];
        _scanOrderGeneration++;
        retired = YES;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
    }
}

- (void)finishCarrierForTrack:(AudioTrack *)track {
    os_unfair_lock_lock(&_materializationLock);
    [_tracksWithCarrier removeObject:track];
    os_unfair_lock_unlock(&_materializationLock);
}

- (void)finishParseOperation:(NSOperation *)operation forTrack:(AudioTrack *)track {
    os_unfair_lock_lock(&_materializationLock);
    if ([_parseOperationsByTrack objectForKey:track] == operation) {
        [_parseOperationsByTrack removeObjectForKey:track];
    }
    os_unfair_lock_unlock(&_materializationLock);
}

// _materializationLock held. D7 is a path budget, not a row budget: once one
// carrier spends the final attempt, duplicate pending/delayed rows must not
// each buy another provider run from the same exhausted ledger.
- (void)dropRecordsForExhaustedPathLocked:(NSString * _Nonnull)path
                             currentTrack:(AudioTrack * _Nonnull)track {
    for (MetadataScanEntry *candidate in [_pendingMaterializations copy]) {
        if ([candidate.standardizedPath isEqualToString:path]) {
            [_pendingMaterializations removeObjectIdenticalTo:candidate];
            [_tracksWithCarrier removeObject:candidate.track];
        }
    }
    for (MetadataScanEntry *candidate in [_delayedScanRetryEntries copy]) {
        if ([candidate.standardizedPath isEqualToString:path]) {
            [_delayedScanRetryEntries removeObject:candidate];
            [_tracksWithCarrier removeObject:candidate.track];
        }
    }
    for (NSURL *priorityURL in [_priorityMarks.allKeys copy]) {
        if ([VibeStandardizedAudioOpenPath(priorityURL) isEqualToString:path]) {
            [_priorityURLs removeObject:priorityURL];
            [_priorityMarks removeObjectForKey:priorityURL];
        }
    }
    [_tracksWithCarrier removeObject:track];
    _scanOrderGeneration++;
}

- (BOOL)loadTrackFromDiskCache:(AudioTrack *)track {
    AudioTrackMetadata *cachedMetaData = [self readCachedMetadataForTrack:track];
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
    if (self.isCancelled) {
        return;
    }
    if (track.metadata.parsedOK) {
        [self finishCarrierForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    // Materialization for this exact row is already Ready. A priority edge
    // arriving while the parse is queued/running no longer has a record to
    // carry it, so both entry and terminal settlement retire that edge.
    [self retirePriorityMarkSatisfiedByTrack:track];
    MetadataParseClaim *claim = [_parseCoordinator claimParseForKey:track.url
                                                         participant:track];
    if (!claim.isOwner) {
        [self finishCarrierForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    // Another lane can resolve this row, or a prior holder can populate the
    // disk entry, between the entry check and claim acquisition.
    if (track.metadata.parsedOK || [self loadTrackFromDiskCache:track]) {
        [self serveWaitersFromCache:[_parseCoordinator completeClaim:claim] owner:track];
        [self finishCarrierForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
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
        [self finishCarrierForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
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
    [self finishCarrierForTrack:track];
    [self retirePriorityMarkSatisfiedByTrack:track];
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
    AudioTrackMetadata *metadata = _fileParser
            ? _fileParser(track.url)
            : [AudioTrackMetadata metadataWithURL:track.url];
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
            // The display-art rendition rides beside the entry, under the same
            // write-then-recheck pair. The stash is consumed either way, so a
            // skipped write costs the header one extraction, never a leak.
            NSData *displayArt = [metadata.artwork takeArchivedDisplayArtDataForStorage];
            if (displayArt) {
                [owner.metadataCache.diskCache setObject:displayArt
                                                  forKey:VibeArchivedDisplayArtKey(cacheKey)];
            }
            if (generation != owner.cacheGeneration) {
                [owner.metadataCache.diskCache removeObjectForKey:cacheKey];
                [owner.metadataCache.diskCache
                        removeObjectForKey:VibeArchivedDisplayArtKey(cacheKey)];
            }
            VibeInstallArchivedDisplayArtProvider(metadata, owner.metadataCache, cacheKey);
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

- (void)cancel {
    self.isCancelled = YES;
    [_queue cancelAllOperations];
    NSArray<AudioFileMaterializationRequestToken *> *tokens = nil;
    os_unfair_lock_lock(&_materializationLock);
    tokens = _liveMaterializationTokens.allObjects;
    [_liveMaterializationTokens removeAllObjects];
    _scanMaterializationToken = nil;
    _priorityMaterializationToken = nil;
    _scanMaterializationInFlight = NO;
    _priorityMaterializationInFlight = NO;
    _scanMaterializationPath = nil;
    _priorityMaterializationPath = nil;
    _scanDispatchKickPending = NO;
    _gatedRepickPending = NO;
#if DEBUG
    _debugBeforeScanPickValidation = nil;
#endif
    _stageOneFinished = NO;
    [_pendingMaterializations removeAllObjects];
    [_delayedScanRetryEntries removeAllObjects];
    [_priorityURLs removeAllObjects];
    [_priorityMarks removeAllObjects];
    [_tracksWithCarrier removeAllObjects];
    [_parseOperationsByTrack removeAllObjects];
    _scanOrderGeneration++;
    [_materializationAttemptsByPath removeAllObjects];
    os_unfair_lock_unlock(&_materializationLock);
    for (AudioFileMaterializationRequestToken *token in tokens) {
        [token cancel];
    }
}

@end
