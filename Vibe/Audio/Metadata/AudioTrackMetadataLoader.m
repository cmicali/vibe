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

// One row from cache check to materialization: a plain record, never a
// pre-built operation, so everything pending stays re-rankable. The current
// track is the same record with its URL in the priority set, a second slot
// rather than a second lane, so playlist replacement drops it like any row.
@interface MetadataScanEntry : NSObject <MetadataScanOrderCandidate>
@property (nonatomic, strong, readonly, nonnull) AudioTrack *track;
@property (nonatomic, copy, readonly, nonnull) NSURL *url;
@property (nonatomic, copy, readonly, nonnull) NSString *standardizedPath;
// The equal-rank tie-break; without it the tail downloads in stage-1
// completion order. NSNotFound, sorting last, for a record prioritizeTrack:
// made outside the sweep.
@property (nonatomic) NSUInteger playlistIndex;
// A retry after a failure: below every untried record, however the
// neighborhood moves.
@property (nonatomic) BOOL deferred;
// On disk at the last probe: leads the order and is exempt from the hold.
// Re-probed at every enqueue, submit and requeue, since the playback open
// downloading this very file is how it usually flips.
@property (nonatomic) BOOL local;
// A priority submission yielded under the hold; the record waits for a
// gated tick to re-judge it (MetadataRetryRules.h).
@property (nonatomic) BOOL yieldedUnderHold;
// Other records of its file may be pending: its parse holds them back from
// the scan, and its resolution settles them. Set for a file of several rows in
// the sweep, and for a priority record, whose file's rows the sweep holds
// apart; every other record skips both.
@property (nonatomic) BOOL sharesFile;
// The prioritizeTrack: edge this record carried when its slot was claimed. An
// off-lock probe's result acts only while this still matches the URL's mark.
@property (nonatomic) NSUInteger priorityMarkGeneration;
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
@property(nonatomic) NSUInteger markGeneration;
@property(nonatomic, strong) AudioTrack *track;
@end

@implementation MetadataPriorityMark
@end

// NSURL+Hash cache keys never contain '#'.
static NSString *VibeArchivedDisplayArtKey(NSString *cacheKey) {
    return [cacheKey stringByAppendingString:@"#displayArt"];
}

// Stamped on every art-bearing row, thumbnail bytes or not: an entry whose
// 128px re-encode failed has only the rendition to rebuild its thumbnail
// from, and a row without one pays a single empty read.
static void VibeInstallArchivedDisplayArtProvider(AudioTrackMetadata *metadata,
                                                  PINCache *metadataCache,
                                                  NSString *cacheKey) {
    if (!metadata.artwork.hasEmbeddedArt) {
        return;
    }
    NSString *sidecarKey = VibeArchivedDisplayArtKey(cacheKey);
    __weak PINCache *weakCache = metadataCache;
    metadata.artwork.archivedDisplayArtProvider = ^NSData *{
        // Blocking read on a registry worker; a departed cache reads as absent.
        PINCache *cache = weakCache;
        NSData *data = (NSData *)[cache.diskCache objectForKey:sidecarKey];
        // PINCache unarchives without secure coding: a wrong class is absent.
        return [data isKindOfClass:[NSData class]] ? data : nil;
    };
}

@interface AudioTrackMetadataLoader ()
- (nullable AudioTrackMetadata *)readCachedMetadataForTrack:(AudioTrack *)track;
- (void)retirePriorityMarkSatisfiedByTrack:(AudioTrack *)track;
- (void)finishScanInFlightForTrack:(AudioTrack *)track;
- (void)finishParseOperation:(NSOperation *)operation forEntry:(MetadataScanEntry *)entry;
- (void)dropRecordsForExhaustedPathLocked:(NSString * _Nonnull)path
                             currentTrack:(AudioTrack * _Nonnull)track;
- (NSArray<AudioTrack *> *)removeUnpickedRecordsPassingTestLocked:
        (NS_NOESCAPE BOOL (^)(MetadataScanEntry *record))test;
- (AudioTrackMetadata *)parseAndCacheMetadataForTrack:(AudioTrack *)track;
- (NSArray<AudioTrack *> *)installCopiesOfMetadata:(AudioTrackMetadata *)metadata
                                           onTracks:(NSArray<AudioTrack *> *)tracks;
- (void)settleTracks:(NSArray<AudioTrack *> *)tracks withMetadata:(AudioTrackMetadata *)metadata;
- (void)publishTrack:(AudioTrack *)track
    expectedMetadata:(AudioTrackMetadata *)expectedMetadata;
@end

@implementation AudioTrackMetadataLoader {
    // Re-read at use: the owner builds its PINCache asynchronously, and an
    // early snapshot would freeze nil for the loader's life.
    __weak AudioTrackMetadataCache* _owner;
    NSOperationQueue* _queue;
    // By identity, not inferred from track.metadata: a failed parse must stay
    // eligible for a later loader. Guarded by _materializationLock.
    NSMutableSet<AudioTrack *>* _queuedTracks;
    // Tracks whose record, materialization or parse can still settle a
    // priority mark; a priority edge for any other track mints a fresh
    // cache-check record. Guarded by _materializationLock.
    NSMutableSet<AudioTrack *>* _tracksWithScanInFlight;
    // So a priority edge after Ready can promote a queued utility parse.
    // Guarded by _materializationLock.
    NSMapTable<AudioTrack *, NSOperation *> *_parseOperationsByTrack;
    // The paths of sharesFile records with a parse queued or running: the scan
    // holds their file's other records back for it to settle. Counted, since
    // the priority slot can add a second. Added on the callback queue, where
    // the picker runs, so a pick's snapshot cannot miss one. Guarded by
    // _materializationLock.
    NSCountedSet<NSString *> *_parsingSharedPaths;
    // Every cache miss, app-owned until one pick is registered with the
    // coordinator.
    NSMutableArray<MetadataScanEntry *>* _pendingMaterializations;
    // Admission-exhausted entries waiting out their delay. A set, so the
    // delayed block can see a cancellation.
    NSMutableSet<MetadataScanEntry *>* _delayedScanRetryEntries;
    // The single source of which records are priority; demotion is removal,
    // so no stale mark survives. Guarded by _materializationLock.
    NSMutableSet<NSURL *>* _priorityURLs;
    NSMutableDictionary<NSURL *, MetadataPriorityMark *> *_priorityMarks;
    NSUInteger _nextPriorityMarkGeneration;
    BOOL _scanMaterializationInFlight;
    BOOL _priorityMaterializationInFlight;
    // The two slots must never join one claim, or its failure is charged to
    // the path twice.
    NSString *_scanMaterializationPath;
    NSString *_priorityMaterializationPath;
    BOOL _scanDispatchKickPending;
    // Bumped by every pending-list or neighborhood mutation; the picker
    // chooses off the lock and verifies it before taking its choice.
    NSUInteger _scanOrderGeneration;
    // Set by the barrier once every cache check settled, so no parse steals a
    // stage-1 worker. Priority picks are exempt: a pre-sweep loader never
    // runs load:.
    BOOL _stageOneFinished;
    NSArray<NSURL *>* _neighborhood;   // rank order; empty until a screen names one
    // One coalesced 1s re-pick while the rule gates work; the coordinator has
    // no release edge to deliver. Guarded by _materializationLock.
    BOOL _gatedRepickPending;
    // Failures per path, yields excluded (spec D7). Guarded by
    // _materializationLock.
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
        _tracksWithScanInFlight = [NSMutableSet set];
        _parseOperationsByTrack = [NSMapTable strongToStrongObjectsMapTable];
        _parsingSharedPaths = [NSCountedSet set];
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
        // Several workers, so one slow file stalls only its own. The current
        // track's parse raises its own operation to user-initiated.
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
    // Off main: the walk over a large drop. High priority, so the sweep starts
    // ahead of queued parses.
    NSOperation *setup = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) setupSelf = weakSelf;
        if (!setupSelf) return;
        // One item per file, its rows in playlist order.
        NSMutableArray<NSMutableArray<MetadataScanEntry *> *> *worklist =
                [NSMutableArray arrayWithCapacity:tracks.count];
        NSMutableDictionary<NSString *, NSMutableArray<MetadataScanEntry *> *> *rowsByPath =
                [NSMutableDictionary dictionaryWithCapacity:tracks.count];
        for (NSUInteger index = 0; index < tracks.count; index++) {
            if (setupSelf.isCancelled) break;
            AudioTrack *track = tracks[index];
            // A failed parse stays eligible: the file may be readable now.
            if (track.metadata.parsedOK) continue;
            BOOL alreadyQueued;
            os_unfair_lock_lock(&setupSelf->_materializationLock);
            alreadyQueued = [setupSelf->_queuedTracks containsObject:track];
            if (!alreadyQueued) {
                [setupSelf->_queuedTracks addObject:track];
                [setupSelf->_tracksWithScanInFlight addObject:track];
            }
            os_unfair_lock_unlock(&setupSelf->_materializationLock);
            if (alreadyQueued) continue;
            MetadataScanEntry *entry = [[MetadataScanEntry alloc]
                    initWithTrack:track playlistIndex:index];
            // Keyed like the parse claim, so two spellings share one read.
            NSMutableArray<MetadataScanEntry *> *rows = rowsByPath[entry.standardizedPath];
            if (!rows) {
                rows = [NSMutableArray array];
                rowsByPath[entry.standardizedPath] = rows;
                [worklist addObject:rows];
            }
            [rows addObject:entry];
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

// Stage 1: the cache check never reads audio, so a dataless file cannot block
// it, and high priority drains it before any parse gets a worker. A bounded
// worker set walks the records in order, never one operation per row: a
// playlist can hold over 100,000 rows.
- (void)enqueueStageOneWorkersForWorklist:(NSArray<NSArray<MetadataScanEntry *> *> *)worklist {
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
                NSArray<MetadataScanEntry *> *rows = nil;
                os_unfair_lock_lock(&strongSelf->_materializationLock);
                if (cursor < worklist.count) {
                    rows = worklist[cursor++];
                }
                os_unfair_lock_unlock(&strongSelf->_materializationLock);
                if (!rows) return;
                [strongSelf cacheCheckRows:rows];
            }
        }];
        op.queuePriority = NSOperationQueuePriorityHigh;
        [_queue addOperation:op];
    }
}

// Every miss takes the materialization path, even a local one, which settles
// at once: one route to TagLib whatever the probe answered. The file's first
// row reads for all of them, so on a hit a cue sheet's forty rows cost one stat
// and one unarchive.
- (void)cacheCheckRows:(NSArray<MetadataScanEntry *> *)rows {
    AudioTrack *track = rows.firstObject.track;
    // An earlier loader may have resolved it since it was queued.
    if (track.metadata.parsedOK || [self loadTrackFromDiskCache:track]) {
        [self settleTracks:[rows valueForKey:@"track"] withMetadata:track.metadata];
        return;
    }
    for (MetadataScanEntry *row in rows) {
        if (row.track.metadata.parsedOK) {
            [self finishScanInFlightForTrack:row.track];
            [self retirePriorityMarkSatisfiedByTrack:row.track];
        }
        else if (!self.isCancelled) {
            row.sharesFile = rows.count > 1;
            [self enqueueScanMaterialization:row];
        }
    }
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
            // A priority record does not wait for the stage-1 barrier.
            kick = _priorityMarks[entry.url].track == entry.track;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (kick || dropped) {
        [self dispatchNextScanMaterialization];
    }
}

// A pending or delayed record is reactivated for one submission; an in-flight
// or mid-stage-1 one adopts the mark at completion or enqueue; any other track
// gets its own high-priority cache check, then a record.
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
    BOOL needsScan;
    NSOperation *parseOperation;
    os_unfair_lock_lock(&_materializationLock);
    MetadataPriorityMark *mark = [[MetadataPriorityMark alloc] init];
    mark.markGeneration = ++_nextPriorityMarkGeneration;
    mark.track = track;
    [_priorityURLs addObject:url];
    _priorityMarks[url] = mark;
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (entry.track == track) {
            entry.priorityMarkGeneration = mark.markGeneration;
            entry.yieldedUnderHold = NO;
        }
    }
    for (MetadataScanEntry *entry in [_delayedScanRetryEntries copy]) {
        if (entry.track == track) {
            [_delayedScanRetryEntries removeObject:entry];
            entry.priorityMarkGeneration = mark.markGeneration;
            entry.yieldedUnderHold = NO;
            [_pendingMaterializations addObject:entry];
        }
    }
    _scanOrderGeneration++;
    alreadyQueued = [_queuedTracks containsObject:track];
    if (!alreadyQueued) {
        [_queuedTracks addObject:track];
    }
    needsScan = ![_tracksWithScanInFlight containsObject:track];
    if (needsScan) {
        [_tracksWithScanInFlight addObject:track];
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
    // A winner that installed before the mark existed retired nothing.
    if (track.metadata.parsedOK) {
        [self finishScanInFlightForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    LogDebug(@"Priority load %@%@", url.lastPathComponent,
             alreadyQueued ? @": already queued" : @"");
    if (!needsScan) {
        [self dispatchNextScanMaterialization];
        return;
    }
    __weak __typeof(self) weakSelf = self;
    NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }
        if (track.metadata.parsedOK || [strongSelf loadTrackFromDiskCache:track]) {
            [strongSelf finishScanInFlightForTrack:track];
            [strongSelf retirePriorityMarkSatisfiedByTrack:track];
            return;
        }
        MetadataScanEntry *entry = [[MetadataScanEntry alloc]
                initWithTrack:track playlistIndex:NSNotFound];
        entry.sharesFile = YES;
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
    // A snapshot: a submission racing a rising edge is yielded unspent.
    BOOL suspended = [_materializationCoordinator isForegroundTransferActive];
    // Before any idle pick, or a kick in the release gap could resubmit a
    // still-dataless yielded record instead of demoting it.
    if (!suspended) {
        [self judgeWaitingPriorityRecordsWhileHeld:NO];
    }
    // The priority slot runs beside the scan's, so the current track never
    // waits for the sweep's transfer (D3).
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
            priorityPick.priorityMarkGeneration =
                    _priorityMarks[priorityPick.url].markGeneration;
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
    NSSet<NSString *> *parsingSharedPaths = nil;
    NSUInteger orderGeneration = 0;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanMaterializationInFlight && !self.isCancelled
            && _stageOneFinished && _pendingMaterializations.count > 0) {
        pending = [_pendingMaterializations copy];
        neighborhood = _neighborhood;
        priorityURLs = [_priorityURLs copy];
        priorityMaterializationPath = [_priorityMaterializationPath copy];
        parsingSharedPaths = [_parsingSharedPaths copy];
        orderGeneration = _scanOrderGeneration;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (priorityURLs.count) {
        // Priority records belong to the priority slot alone.
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
    if (parsingSharedPaths.count) {
        // A row of their file is parsing, and its success settles them.
        pending = [pending filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(MetadataScanEntry *entry,
                                                      NSDictionary *bindings) {
            return !entry.sharesFile
                    || ![parsingSharedPaths containsObject:entry.standardizedPath];
        }]];
    }
    if (suspended) {
        // Local entries start no transfer, so they keep parsing. No dataless
        // record is submitted while suspended, even one C3 would join (J4).
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

// Stands in for the hold's release edge: one coalesced re-pick per second
// while the rule gates work. A gap between rapid nexts cannot flap the sweep;
// the tick just finds the foreground active again.
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

// Every gated tick (MetadataRetryRules.h). The probe is I/O, so it runs off
// the lock, and the mark generation is revalidated after it so an old mark's
// judgement cannot remove a new prioritizeTrack: edge.
- (void)judgeWaitingPriorityRecordsWhileHeld:(BOOL)held {
    NSMutableArray<MetadataScanEntry *> *waiting = [NSMutableArray array];
    NSMutableArray<NSNumber *> *markGenerations = [NSMutableArray array];
    os_unfair_lock_lock(&_materializationLock);
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (entry.yieldedUnderHold
                && _priorityMarks[entry.url].track == entry.track) {
            [waiting addObject:entry];
            [markGenerations addObject:@(entry.priorityMarkGeneration)];
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    for (NSUInteger index = 0; index < waiting.count; index++) {
        MetadataScanEntry *entry = waiting[index];
        NSUInteger markGeneration = markGenerations[index].unsignedIntegerValue;
        BOOL local = ![NSURLUtil isDatalessFile:entry.url];
        BOOL demoted = NO;
        os_unfair_lock_lock(&_materializationLock);
        BOOL stillPending = [_pendingMaterializations containsObject:entry];
        BOOL sameEntryMark = entry.priorityMarkGeneration == markGeneration;
        MetadataPriorityMark *currentMark = _priorityMarks[entry.url];
        BOOL sameCurrentMark = currentMark.track == entry.track
                && currentMark.markGeneration == markGeneration;
        if (!stillPending || !entry.yieldedUnderHold || !sameEntryMark) {
            os_unfair_lock_unlock(&_materializationLock);
            continue;
        }
        entry.local = local;
        VibeMetadataPriorityYieldOutcome outcome =
                VibeMetadataPriorityAfterYield(held, local);
        if (!sameCurrentMark) {
            // A newer mark, already reactivated; this probe cannot touch it.
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

        // Re-probed: a rule that rose since the pick must not requeue a file
        // the playback open has since downloaded.
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
            // Scan picks only: a priority submission goes through, served by
            // a same-path foreground claim or yielded by the coordinator (J4).
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

    // Off the lock (I/O): a requeued entry re-ranks on fresh locality, and the
    // yield triage below judges against this rule sample.
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
            // Yield triage (MetadataRetryRules.h); spends no budget.
            VibeMetadataPriorityYieldOutcome outcome =
                    VibeMetadataPriorityAfterYield(suspended, entry.local);
            MetadataPriorityMark *currentMark = _priorityMarks[entry.url];
            BOOL sameCurrentMark = currentMark.track == entry.track
                    && currentMark.markGeneration == entry.priorityMarkGeneration;
            if (!sameCurrentMark) {
                // Carried an older mark: reactivate the newer edge once.
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
                // Exhausted (D7): the path and its priority mark are dropped
                // until a fresh loader.
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
                    [strongSelf parseOneEntry:entry];
                }
                [strongSelf finishParseOperation:weakParse forEntry:entry];
            }
        }];
        weakParse = parse;
        BOOL userInitiatedParse = priority || satisfiesCurrentPriority;
        parse.qualityOfService = userInitiatedParse
                ? NSQualityOfServiceUserInitiated : NSQualityOfServiceUtility;
        if (userInitiatedParse) {
            parse.queuePriority = NSOperationQueuePriorityHigh;
        }
        os_unfair_lock_lock(&_materializationLock);
        // prioritizeTrack: may have marked it after the decision above but
        // before this operation existed.
        if (_priorityMarks[entry.url].track == entry.track) {
            userInitiatedParse = YES;
            parse.qualityOfService = NSQualityOfServiceUserInitiated;
            parse.queuePriority = NSOperationQueuePriorityHigh;
        }
        [_parseOperationsByTrack setObject:parse forKey:entry.track];
        if (entry.sharesFile) {
            [_parsingSharedPaths addObject:entry.standardizedPath];
        }
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

// Touches only file attributes and the store, never audio data, so it stays
// fast over dataless files.
- (AudioTrackMetadata *)readCachedMetadataForTrack:(AudioTrack *)track {
    if (_cacheReader) {
        return _cacheReader(track);
    }
    // nil when the stat fails (NSURL+Hash); the parse still runs.
    NSString *cacheKey = track.cacheKey;
    if (!cacheKey) {
        LogWarn(@"No cache key for %@ — loading metadata uncached", track.url.path);
        return nil;
    }
    // nil until constructed; only the earliest tracks parse uncached.
    PINCache *metadataCache = _owner.metadataCache;
    if (!metadataCache) {
        LogWarn(@"Metadata cache not yet available — loading %@ uncached", track.url.path);
        return nil;
    }
    // Bypasses PINMemoryCache: on macOS it never evicts (its pressure hooks
    // are iOS-only), so every track ever loaded would stay pinned.
    AudioTrackMetadata *cachedMetaData = (AudioTrackMetadata *)[metadataCache.diskCache objectForKey:cacheKey];
    // PINCache unarchives without secure coding: a wrong root class skips
    // initWithCoder:'s validation and would crash on first use every launch.
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

- (void)finishScanInFlightForTrack:(AudioTrack *)track {
    os_unfair_lock_lock(&_materializationLock);
    [_tracksWithScanInFlight removeObject:track];
    os_unfair_lock_unlock(&_materializationLock);
}

- (void)finishParseOperation:(NSOperation *)operation forEntry:(MetadataScanEntry *)entry {
    BOOL released = NO;
    os_unfair_lock_lock(&_materializationLock);
    if ([_parseOperationsByTrack objectForKey:entry.track] == operation) {
        [_parseOperationsByTrack removeObjectForKey:entry.track];
    }
    if (entry.sharesFile) {
        [_parsingSharedPaths removeObject:entry.standardizedPath];
        released = [_parsingSharedPaths countForObject:entry.standardizedPath] == 0;
    }
    os_unfair_lock_unlock(&_materializationLock);
    // A failed parse settled nothing: the rows it held back are pickable now.
    if (released) {
        [self dispatchNextScanMaterialization];
    }
}

// _materializationLock held. D7 is per path: duplicate rows must not each buy
// another run from an exhausted ledger.
- (void)dropRecordsForExhaustedPathLocked:(NSString * _Nonnull)path
                             currentTrack:(AudioTrack * _Nonnull)track {
    NSArray<AudioTrack *> *dropped = [self removeUnpickedRecordsPassingTestLocked:
            ^BOOL(MetadataScanEntry *record) {
        return [record.standardizedPath isEqualToString:path];
    }];
    [_tracksWithScanInFlight minusSet:[NSSet setWithArray:dropped]];
    for (NSURL *priorityURL in [_priorityMarks.allKeys copy]) {
        if ([VibeStandardizedAudioOpenPath(priorityURL) isEqualToString:path]) {
            [_priorityURLs removeObject:priorityURL];
            [_priorityMarks removeObjectForKey:priorityURL];
        }
    }
    [_tracksWithScanInFlight removeObject:track];
    _scanOrderGeneration++;
}

// _materializationLock held. Takes out the records not yet picked, pending or
// delayed, that pass the test, and answers their tracks; a picked record
// settles on its own.
- (NSArray<AudioTrack *> *)removeUnpickedRecordsPassingTestLocked:
        (NS_NOESCAPE BOOL (^)(MetadataScanEntry *record))test {
    NSIndexSet *pending = [_pendingMaterializations indexesOfObjectsPassingTest:
            ^BOOL(MetadataScanEntry *record, NSUInteger index, BOOL *stop) {
        return test(record);
    }];
    NSSet<MetadataScanEntry *> *delayed = [_delayedScanRetryEntries objectsPassingTest:
            ^BOOL(MetadataScanEntry *record, BOOL *stop) {
        return test(record);
    }];
    NSArray<MetadataScanEntry *> *removed = [[_pendingMaterializations objectsAtIndexes:pending]
            arrayByAddingObjectsFromArray:delayed.allObjects];
    [_pendingMaterializations removeObjectsAtIndexes:pending];
    [_delayedScanRetryEntries minusSet:delayed];
    if (removed.count > 0) {
        _scanOrderGeneration++;
    }
    return [removed valueForKey:@"track"];
}

- (BOOL)loadTrackFromDiskCache:(AudioTrack *)track {
    AudioTrackMetadata *cachedMetaData = [self readCachedMetadataForTrack:track];
    if (!cachedMetaData) {
        return NO;
    }
    // Only the winner publishes: another lane may have installed a parse
    // during the read.
    if ([track installMetadataIfUnresolved:cachedMetaData]) {
        [self publishTrack:track];
    }
    return YES;
}

// Stage 2: the TagLib parse, entered only after materialization was Ready.
- (void)parseOneEntry:(MetadataScanEntry *)entry {
    if (self.isCancelled) {
        return;
    }
    AudioTrack *track = entry.track;
    if (track.metadata.parsedOK) {
        [self finishScanInFlightForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    // A priority edge landing while the parse is queued has no record to
    // carry it, so entry and settlement both retire it.
    [self retirePriorityMarkSatisfiedByTrack:track];
    MetadataParseClaim *claim = [_parseCoordinator claimParseForKey:entry.standardizedPath
                                                         participant:track];
    if (!claim.isOwner) {
        [self finishScanInFlightForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
        return;
    }
    // Another lane or a prior holder may have resolved it before the claim.
    AudioTrackMetadata *result = (track.metadata.parsedOK || [self loadTrackFromDiskCache:track])
            ? track.metadata : [self parseAndCacheMetadataForTrack:track];
    if (result.parsedOK) {
        // NO for a resolved holder, already published.
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
        // The file's rows still waiting to be picked take it too, rather than
        // each materialize and read the cache again.
        NSArray<AudioTrack *> *settled = @[];
        if (entry.sharesFile) {
            NSString *path = entry.standardizedPath;
            os_unfair_lock_lock(&_materializationLock);
            settled = [self removeUnpickedRecordsPassingTestLocked:^BOOL(MetadataScanEntry *record) {
                return [record.standardizedPath isEqualToString:path];
            }];
            os_unfair_lock_unlock(&_materializationLock);
        }
        [self settleTracks:[settled arrayByAddingObject:track] withMetadata:result];
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
    [self finishScanInFlightForTrack:track];
    [self retirePriorityMarkSatisfiedByTrack:track];
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

// Copies into every track still unresolved and publishes it, then ends each
// track's scan and retires the mark it satisfies.
- (void)settleTracks:(NSArray<AudioTrack *> *)tracks withMetadata:(AudioTrackMetadata *)metadata {
    for (AudioTrack *adopted in [self installCopiesOfMetadata:metadata onTracks:tracks]) {
        [self publishTrack:adopted];
    }
    for (AudioTrack *track in tracks) {
        [self finishScanInFlightForTrack:track];
        [self retirePriorityMarkSatisfiedByTrack:track];
    }
}

- (AudioTrackMetadata *)parseAndCacheMetadataForTrack:(AudioTrack *)track {
    AudioTrackMetadataCache *owner = _owner;
    // Before the parse, which can block for minutes: an invalidate during it
    // makes the result stale for the cache.
    uint64_t generation = owner.cacheGeneration;
    // A local, so every skipped write below releases it with the frame.
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = _fileParser
            ? _fileParser(track.url)
            : [AudioTrackMetadata metadataWithURL:track.url displayArtData:&displayArt];
    // Re-read: a stat failure at cache-check time may have healed.
    NSString *cacheKey = track.cacheKey;
    if (metadata.parsedOK && cacheKey) {
        // A failed parse is never cached: its fallback would shadow the real
        // tags until the cache key changed. The write is synchronous so its
        // back-pressure paces the workers; async writes back up PINDiskCache's
        // queue. The generation is rechecked after the write because
        // removeAllObjects can slip between check and write, and the remove
        // keeps Clear Cache empty. Use the strong `owner`, never _owner, so
        // the pair cannot see the cache vanish midway.
        if (generation == owner.cacheGeneration) {
            [owner.metadataCache.diskCache setObject:metadata forKey:cacheKey];
            // Same write-then-recheck pair for the rendition.
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

// Not gated on isCancelled: every caller won an install. The identity guard
// decides delivery, and the delegate drops a departed track.
- (void)publishTrack:(AudioTrack *)track {
    [self publishTrack:track expectedMetadata:track.metadata];
}

- (void)publishTrack:(AudioTrack *)track
    expectedMetadata:(AudioTrackMetadata *)expectedMetadata {
    if (!expectedMetadata) {
        return;
    }
    run_on_main_thread({
        // Holds the track monitor through the delegate, which may read
        // track.metadata but must never wait on a metadata worker.
        [track deliverIfMetadataStillInstalled:expectedMetadata usingBlock:^{
            [self.delegate didLoadMetadata:track];
        }];
    });
}

- (void)abandonQueuedTrack:(AudioTrack *)track {
    if (!track) {
        return;
    }
    NSString *path = VibeStandardizedAudioOpenPath(track.url);
    os_unfair_lock_lock(&_materializationLock);
    // Not-yet-picked records of this exact row; a duplicate row is another
    // AudioTrack and keeps its own.
    BOOL removed = [self removeUnpickedRecordsPassingTestLocked:^BOOL(MetadataScanEntry *record) {
        return record.track == track;
    }].count > 0;
    if (removed) {
        // With nothing in flight, drop the identity marks too, so an undo's
        // prioritizeTrack: builds a fresh record. In-flight work keeps them
        // for its settlement. A record still in stage 1 is missed and costs at
        // most one transfer; its delivery no-ops.
        BOOL inFlight = [_parseOperationsByTrack objectForKey:track] != nil
                || (path != nil
                    && ([path isEqualToString:_scanMaterializationPath]
                        || [path isEqualToString:_priorityMaterializationPath]));
        if (!inFlight) {
            [_queuedTracks removeObject:track];
            [_tracksWithScanInFlight removeObject:track];
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
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
    [_tracksWithScanInFlight removeAllObjects];
    [_parseOperationsByTrack removeAllObjects];
    [_parsingSharedPaths removeAllObjects];
    _scanOrderGeneration++;
    [_materializationAttemptsByPath removeAllObjects];
    os_unfair_lock_unlock(&_materializationLock);
    for (AudioFileMaterializationRequestToken *token in tokens) {
        [token cancel];
    }
}

@end
