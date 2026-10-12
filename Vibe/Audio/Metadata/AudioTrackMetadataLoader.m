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

// One file from cache check to materialization, with every row sharing its
// standardized path, so the file materializes and parses once by construction
// and its answer settles them all. A plain record, never a pre-built
// operation, so everything pending stays re-rankable. The current track's file
// is the same record holding a marked row, a second slot rather than a second
// lane, so playlist replacement drops it like any row.
@interface MetadataScanEntry : NSObject <MetadataScanOrderCandidate>
// Never empty. Replaced whole under _materializationLock, and read off it only
// while no other thread can replace it: before the record is published, or
// once picked.
@property (nonatomic, copy, nonnull) NSArray<AudioTrack *> *tracks;
// The first row's: any spelling reaches the file.
@property (nonatomic, copy, readonly, nonnull) NSURL *url;
@property (nonatomic, copy, readonly, nonnull) NSString *standardizedPath;
// The first row's, the equal-rank tie-break; without it the tail downloads in
// stage-1 completion order. NSNotFound, sorting last, for a record
// prioritizeTrack: made outside the sweep.
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
// The rank under the neighborhood neighborhoodRankGeneration names, kept
// across picks: the neighborhood moves per track, the sweep picks per file,
// and ranking compares URLs. Under _materializationLock.
@property (nonatomic) NSUInteger neighborhoodRank;
@property (nonatomic) NSUInteger neighborhoodRankGeneration;
// The prioritizeTrack: edge this record carried when its slot was claimed. An
// off-lock probe's result acts only while this still matches the row's mark.
@property (nonatomic) NSUInteger priorityMarkGeneration;
- (instancetype)initWithTracks:(NSArray<AudioTrack *> *)tracks
              standardizedPath:(NSString *)standardizedPath
                 playlistIndex:(NSUInteger)playlistIndex;
- (BOOL)holdsTrack:(AudioTrack *)track;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation MetadataScanEntry

- (instancetype)initWithTracks:(NSArray<AudioTrack *> *)tracks
              standardizedPath:(NSString *)standardizedPath
                 playlistIndex:(NSUInteger)playlistIndex {
    self = [super init];
    if (self) {
        _tracks = [tracks copy];
        _url = [tracks.firstObject.url copy];
        _standardizedPath = [standardizedPath copy];
        _playlistIndex = playlistIndex;
    }
    return self;
}

- (BOOL)holdsTrack:(AudioTrack *)track {
    return [_tracks indexOfObjectIdenticalTo:track] != NSNotFound;
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
- (nullable MetadataPriorityMark *)priorityMarkForEntryLocked:(MetadataScanEntry *)entry;
- (nullable MetadataPriorityMark *)leadEntryWithItsMarkedRowLocked:(MetadataScanEntry *)entry;
- (BOOL)retirePriorityMarksTargetingTracksLocked:(NSArray<AudioTrack *> *)tracks;
- (void)retirePriorityMarksSatisfiedByTracks:(NSArray<AudioTrack *> *)tracks;
- (void)finishTracks:(NSArray<AudioTrack *> *)tracks;
- (void)finishParseOperation:(NSOperation *)operation forEntry:(MetadataScanEntry *)entry;
- (void)dropRecordsForExhaustedPathOfEntryLocked:(MetadataScanEntry * _Nonnull)entry;
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
    // Every row of a parse's record, so a priority edge after Ready can
    // promote a queued utility parse. Guarded by _materializationLock.
    NSMapTable<AudioTrack *, NSOperation *> *_parseOperationsByTrack;
    // Every cache miss, app-owned until one pick is registered with the
    // coordinator.
    NSMutableArray<MetadataScanEntry *>* _pendingMaterializations;
    // Admission-exhausted entries waiting out their delay. A set, so the
    // delayed block can see a cancellation.
    NSMutableSet<MetadataScanEntry *>* _delayedScanRetryEntries;
    // The single source of which records are priority, keyed by the target's
    // URL, which the scan holds back; demotion is removal, so no stale mark
    // survives. Guarded by _materializationLock.
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
    // releases the lock between choosing and taking, and takes only a choice
    // this still vouches for.
    NSUInteger _scanOrderGeneration;
    // Set by the barrier once every cache check settled, so no parse steals a
    // stage-1 worker. Priority picks are exempt: a pre-sweep loader never
    // runs load:.
    BOOL _stageOneFinished;
    NSArray<NSURL *>* _neighborhood;   // rank order; empty until a screen names one
    // From 1, so a fresh record's 0 is stale.
    NSUInteger _neighborhoodGeneration;
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
        _neighborhoodGeneration = 1;
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
        // One record per file, its rows in playlist order. The path is
        // memoized per URL: standardizing stats, and a sheet's rows share one.
        NSMutableArray<MetadataScanEntry *> *worklist = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableArray<AudioTrack *> *> *rowsByPath =
                [NSMutableDictionary dictionaryWithCapacity:tracks.count];
        NSMutableDictionary<NSURL *, NSString *> *pathsByURL =
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
            // Keyed like the parse claim, so two spellings share one record.
            NSString *path = track.url ? pathsByURL[track.url] : nil;
            if (!path) {
                path = VibeStandardizedAudioOpenPath(track.url);
                if (track.url) {
                    pathsByURL[track.url] = path;
                }
            }
            NSMutableArray<AudioTrack *> *rows = rowsByPath[path];
            if (!rows) {
                rows = [NSMutableArray array];
                rowsByPath[path] = rows;
                [worklist addObject:[[MetadataScanEntry alloc]
                        initWithTracks:@[track] standardizedPath:path playlistIndex:index]];
            }
            [rows addObject:track];
        }
        for (MetadataScanEntry *entry in worklist) {
            entry.tracks = rowsByPath[entry.standardizedPath];
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

// Every miss takes the materialization path, even a local one, which settles
// at once: one route to TagLib whatever the probe answered. The first row
// reads for the file, so on a hit a cue sheet's forty rows cost one stat and
// one unarchive.
- (void)cacheCheckEntry:(MetadataScanEntry *)entry {
    AudioTrack *track = entry.tracks.firstObject;
    // An earlier loader may have resolved it since it was queued.
    if (track.metadata.parsedOK || [self loadTrackFromDiskCache:track]) {
        [self settleTracks:entry.tracks withMetadata:track.metadata];
        return;
    }
    if (!self.isCancelled) {
        [self enqueueScanMaterialization:entry];
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
            [self dropRecordsForExhaustedPathOfEntryLocked:entry];
            dropped = YES;
        }
        else {
            [_pendingMaterializations addObject:entry];
            _scanOrderGeneration++;
            // A priority record does not wait for the stage-1 barrier.
            kick = [self priorityMarkForEntryLocked:entry] != nil;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (kick || dropped) {
        [self dispatchNextScanMaterialization];
    }
}

// A pending or delayed record holding the track is reactivated for one
// submission; an in-flight or mid-stage-1 one adopts the mark at completion or
// enqueue; any other track gets its own high-priority cache check, then joins
// its file's pending record or mints one.
- (void)prioritizeTrack:(AudioTrack *)track {
    if (track.metadata.parsedOK) {
        [self retirePriorityMarksSatisfiedByTracks:@[track]];
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
    _priorityMarks[url] = mark;
    MetadataScanEntry *held = [self unpickedRecordHoldingTrackLocked:track];
    if (held) {
        held.priorityMarkGeneration = mark.markGeneration;
        held.yieldedUnderHold = NO;
        if ([_delayedScanRetryEntries containsObject:held]) {
            [_delayedScanRetryEntries removeObject:held];
            [_pendingMaterializations addObject:held];
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
        [self finishTracks:@[track]];
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
            [strongSelf finishTracks:@[track]];
            return;
        }
        // The file's pending record takes the row, so the file still reads
        // once and its answer settles the rows beside it.
        NSString *path = VibeStandardizedAudioOpenPath(track.url);
        BOOL joined = NO;
        os_unfair_lock_lock(&strongSelf->_materializationLock);
        for (MetadataScanEntry *record in strongSelf->_pendingMaterializations) {
            if ([record.standardizedPath isEqualToString:path]) {
                record.tracks = [record.tracks arrayByAddingObject:track];
                record.yieldedUnderHold = NO;
                strongSelf->_scanOrderGeneration++;
                joined = YES;
                break;
            }
        }
        os_unfair_lock_unlock(&strongSelf->_materializationLock);
        if (!joined) {
            [strongSelf enqueueScanMaterialization:[[MetadataScanEntry alloc]
                    initWithTracks:@[track] standardizedPath:path playlistIndex:NSNotFound]];
        }
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
    if (!_priorityMaterializationInFlight && !self.isCancelled
            && _priorityMarks.count > 0) {
        NSMutableArray<MetadataScanEntry *> *targeted = [NSMutableArray array];
        for (MetadataScanEntry *entry in _pendingMaterializations) {
            if ([self priorityMarkForEntryLocked:entry]
                    && ![entry.standardizedPath
                            isEqualToString:_scanMaterializationPath]) {
                [targeted addObject:entry];
            }
        }
        priorityPick = (MetadataScanEntry *)VibeBestPriorityScanCandidate(
                (NSArray<id<MetadataScanOrderCandidate>> *)targeted, suspended);
        if (priorityPick) {
            [_pendingMaterializations removeObjectIdenticalTo:priorityPick];
            _scanOrderGeneration++;
            _priorityMaterializationInFlight = YES;
            _priorityMaterializationPath = priorityPick.standardizedPath;
            priorityPick.priorityMarkGeneration =
                    [self priorityMarkForEntryLocked:priorityPick].markGeneration;
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (priorityPick) {
        [self submitMaterializationForEntry:priorityPick priority:YES];
    }

    // One pass in place under the lock, no copy: a real playlist holds over
    // 100,000 misses, and the sweep picks once per file.
    MetadataScanEntry *chosen = nil;
    NSUInteger chosenIndex = NSNotFound;
    NSUInteger orderGeneration = 0;
    os_unfair_lock_lock(&_materializationLock);
    if (!_scanMaterializationInFlight && !self.isCancelled
            && _stageOneFinished && _pendingMaterializations.count > 0) {
        NSDictionary<NSURL *, MetadataPriorityMark *> *marks =
                _priorityMarks.count > 0 ? _priorityMarks : nil;
        NSString *priorityMaterializationPath = _priorityMaterializationPath;
        NSArray<NSURL *> *neighborhood = _neighborhood;
        NSUInteger neighborhoodGeneration = _neighborhoodGeneration;
        chosenIndex = VibeBestMetadataScanCandidateIndex(
                (NSArray<id<MetadataScanOrderCandidate>> *)_pendingMaterializations,
                ^NSUInteger(id<MetadataScanOrderCandidate> candidate) {
            MetadataScanEntry *entry = (MetadataScanEntry *)candidate;
            if (entry.neighborhoodRankGeneration != neighborhoodGeneration) {
                entry.neighborhoodRank = VibeMetadataScanNeighborhoodRank(entry.url, neighborhood);
                entry.neighborhoodRankGeneration = neighborhoodGeneration;
            }
            return entry.neighborhoodRank;
        }, ^BOOL(id<MetadataScanOrderCandidate> candidate) {
            MetadataScanEntry *entry = (MetadataScanEntry *)candidate;
            // Priority records belong to the priority slot alone, and a marked
            // URL holds its other records back until the mark settles. Local
            // entries start no transfer, so they keep parsing; no dataless
            // record is submitted while suspended, even one C3 would join (J4).
            return (marks && marks[entry.url] != nil)
                    || (priorityMaterializationPath
                            && [entry.standardizedPath isEqualToString:priorityMaterializationPath])
                    || (suspended && !entry.local);
        });
        if (chosenIndex != NSNotFound) {
            chosen = _pendingMaterializations[chosenIndex];
        }
        orderGeneration = _scanOrderGeneration;
    }
    os_unfair_lock_unlock(&_materializationLock);
    if (!chosen) {
        [self scheduleGatedRepickIfNeededWhileSuspended:suspended];
        return;
    }

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
    // Every pending-list, priority-mark and priority-path change moves the
    // generation, so an unchanged one still has the pick, at its index.
    else if (orderGeneration != _scanOrderGeneration) {
        chosen = nil;
        retryPick = YES;
    }
    else {
        [_pendingMaterializations removeObjectAtIndex:chosenIndex];
        _scanOrderGeneration++;
        _scanMaterializationInFlight = YES;
        _scanMaterializationPath = chosen.standardizedPath;
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
    // A waiting record is a marked one: with no mark, no pass over the misses.
    if (_priorityMarks.count > 0) {
        for (MetadataScanEntry *entry in _pendingMaterializations) {
            if (entry.yieldedUnderHold && [self priorityMarkForEntryLocked:entry]) {
                [waiting addObject:entry];
                [markGenerations addObject:@(entry.priorityMarkGeneration)];
            }
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
        MetadataPriorityMark *currentMark = [self priorityMarkForEntryLocked:entry];
        BOOL sameCurrentMark = currentMark != nil
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
                [_priorityMarks removeObjectForKey:currentMark.track.url];
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
        // A remote placeholder's tags are read by range (AudioTrackMetadata's
        // VibeRangedStream), so it takes no claim: one would download the
        // whole file for a few hundred KB of tags. Ready at once, with no
        // token — the slot holds none yet, so the completion's match passes.
        // The foreground hold above covers the scan's picks only: a priority
        // read — the tags of the track being downloaded and its neighbors' —
        // goes out beside the foreground download, a few hundred KB each, so
        // the header is not blank until the whole file lands. A format TagLib
        // cannot parse is materialized as any cloud file is: CoreAudio's
        // facts need the whole file.
        if ([NSURLUtil readsRemotePlaceholderByRange:entry.url]) {
            [strongSelf completeMaterializationForEntry:entry
                                               priority:priority
                                                  token:nil
                                                 result:VibeAudioFileMaterializationResultReady
                                                  error:nil
                                                elapsed:0];
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
        if (token) {
            [_liveMaterializationTokens removeObject:token];
        }
        os_unfair_lock_unlock(&_materializationLock);
        return;
    }
    if (token) {
        [_liveMaterializationTokens removeObject:token];
    }
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
            MetadataPriorityMark *mark = [self leadEntryWithItsMarkedRowLocked:entry];
            if (mark) {
                satisfiesCurrentPriority = YES;
                [_priorityMarks removeObjectForKey:mark.track.url];
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
            MetadataPriorityMark *currentMark = [self priorityMarkForEntryLocked:entry];
            BOOL sameCurrentMark = currentMark != nil
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
                        [_priorityMarks removeObjectForKey:currentMark.track.url];
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
                [self dropRecordsForExhaustedPathOfEntryLocked:entry];
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
        if ([self priorityMarkForEntryLocked:entry]) {
            userInitiatedParse = YES;
            parse.qualityOfService = NSQualityOfServiceUserInitiated;
            parse.queuePriority = NSOperationQueuePriorityHigh;
        }
        for (AudioTrack *track in entry.tracks) {
            [_parseOperationsByTrack setObject:parse forKey:track];
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
    _neighborhoodGeneration++;
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
        if ([self priorityMarkForEntryLocked:entry]) {
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
    BOOL gatedRepickPending;
    os_unfair_lock_lock(&_materializationLock);
    for (MetadataScanEntry *entry in _pendingMaterializations) {
        if (![self priorityMarkForEntryLocked:entry]) {
            [pendingNames addObject:entry.url.lastPathComponent ?: @"?"];
        }
    }
    for (MetadataScanEntry *entry in _delayedScanRetryEntries) {
        if (![self priorityMarkForEntryLocked:entry]) {
            [delayedNames addObject:entry.url.lastPathComponent ?: @"?"];
        }
    }
    inFlight = _scanMaterializationInFlight;
    tokens = _scanMaterializationToken != nil ? 1 : 0;
    stageOneFinished = _stageOneFinished;
    gatedRepickPending = _gatedRepickPending;
    os_unfair_lock_unlock(&_materializationLock);
    return @{@"pending": pendingNames,
             @"delayed": delayedNames,
             @"inFlight": @(inFlight),
             @"liveTokens": @(tokens),
             @"stageOneFinished": @(stageOneFinished),
             @"gatedRepickPending": @(gatedRepickPending)};
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

// _materializationLock held. The record not yet picked, pending or delayed,
// that holds the row; a row is in at most one.
- (MetadataScanEntry *)unpickedRecordHoldingTrackLocked:(AudioTrack *)track {
    for (MetadataScanEntry *record in _pendingMaterializations) {
        if ([record holdsTrack:track]) {
            return record;
        }
    }
    for (MetadataScanEntry *record in _delayedScanRetryEntries) {
        if ([record holdsTrack:track]) {
            return record;
        }
    }
    return nil;
}

// _materializationLock held. A record is priority while one of its rows is a
// mark's exact target. The marks are few, the rows can be many.
- (MetadataPriorityMark *)priorityMarkForEntryLocked:(MetadataScanEntry *)entry {
    for (MetadataPriorityMark *mark in _priorityMarks.objectEnumerator) {
        if ([entry holdsTrack:mark.track]) {
            return mark;
        }
    }
    return nil;
}

// _materializationLock held, on a picked record. The parse reads for the first
// row, so a failure hands its fallback to the row the user waits on rather
// than requeue it behind the file's other rows.
- (MetadataPriorityMark *)leadEntryWithItsMarkedRowLocked:(MetadataScanEntry *)entry {
    MetadataPriorityMark *mark = [self priorityMarkForEntryLocked:entry];
    if (mark && entry.tracks.firstObject != mark.track) {
        NSMutableArray<AudioTrack *> *tracks = [entry.tracks mutableCopy];
        [tracks removeObjectIdenticalTo:mark.track];
        [tracks insertObject:mark.track atIndex:0];
        entry.tracks = tracks;
    }
    return mark;
}

// _materializationLock held. Answers whether any mark was retired.
- (BOOL)retirePriorityMarksTargetingTracksLocked:(NSArray<AudioTrack *> *)tracks {
    if (_priorityMarks.count == 0) {
        return NO;
    }
    NSSet<NSURL *> *retired = [_priorityMarks keysOfEntriesPassingTest:
            ^BOOL(NSURL *url, MetadataPriorityMark *mark, BOOL *stop) {
        return [tracks indexOfObjectIdenticalTo:mark.track] != NSNotFound;
    }];
    if (retired.count == 0) {
        return NO;
    }
    [_priorityMarks removeObjectsForKeys:retired.allObjects];
    _scanOrderGeneration++;
    return YES;
}

- (void)retirePriorityMarksSatisfiedByTracks:(NSArray<AudioTrack *> *)tracks {
    os_unfair_lock_lock(&_materializationLock);
    BOOL retired = [self retirePriorityMarksTargetingTracksLocked:tracks];
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
    }
}

// Ends each track's scan and retires the marks they satisfy.
- (void)finishTracks:(NSArray<AudioTrack *> *)tracks {
    os_unfair_lock_lock(&_materializationLock);
    for (AudioTrack *track in tracks) {
        [_tracksWithScanInFlight removeObject:track];
    }
    BOOL retired = [self retirePriorityMarksTargetingTracksLocked:tracks];
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
    }
}

- (void)finishParseOperation:(NSOperation *)operation forEntry:(MetadataScanEntry *)entry {
    os_unfair_lock_lock(&_materializationLock);
    for (AudioTrack *track in entry.tracks) {
        if ([_parseOperationsByTrack objectForKey:track] == operation) {
            [_parseOperationsByTrack removeObjectForKey:track];
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
}

// _materializationLock held. D7 is per path: a record minted beside the file's
// own must not buy another run from an exhausted ledger. A picked record
// settles on its own.
- (void)dropRecordsForExhaustedPathOfEntryLocked:(MetadataScanEntry * _Nonnull)entry {
    NSString *path = entry.standardizedPath;
    NSPredicate *samePath = [NSPredicate predicateWithBlock:
            ^BOOL(MetadataScanEntry *record, NSDictionary *bindings) {
        return [record.standardizedPath isEqualToString:path];
    }];
    NSArray<MetadataScanEntry *> *removed = [[_pendingMaterializations filteredArrayUsingPredicate:samePath]
            arrayByAddingObjectsFromArray:[_delayedScanRetryEntries filteredSetUsingPredicate:samePath].allObjects];
    NSMutableArray<AudioTrack *> *dropped = [entry.tracks mutableCopy];
    for (MetadataScanEntry *record in removed) {
        [dropped addObjectsFromArray:record.tracks];
        [_pendingMaterializations removeObjectIdenticalTo:record];
        [_delayedScanRetryEntries removeObject:record];
    }
    [_tracksWithScanInFlight minusSet:[NSSet setWithArray:dropped]];
    [self retirePriorityMarksTargetingTracksLocked:dropped];
    _scanOrderGeneration++;
}

- (void)loadFromCacheOnly:(NSArray<AudioTrack *> *)tracks {
    __weak __typeof(self) weakSelf = self;
    for (AudioTrack *track in tracks) {
        NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf && !track.metadata) {
                [strongSelf loadTrackFromDiskCache:track];
            }
        }];
        // Rows on screen.
        op.qualityOfService = NSQualityOfServiceUserInitiated;
        op.queuePriority = NSOperationQueuePriorityHigh;
        [_queue addOperation:op];
    }
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
    // A mark adopted since Ready leads too.
    os_unfair_lock_lock(&_materializationLock);
    [self leadEntryWithItsMarkedRowLocked:entry];
    os_unfair_lock_unlock(&_materializationLock);
    NSArray<AudioTrack *> *tracks = entry.tracks;
    if (tracks.firstObject.metadata.parsedOK) {
        [self settleTracks:tracks withMetadata:tracks.firstObject.metadata];
        return;
    }
    // A priority edge landing while the parse is queued has no record to
    // carry it, so entry and settlement both retire it.
    [self retirePriorityMarksSatisfiedByTracks:tracks];
    // Rows ahead of the owner joined another lane's holder, which serves them.
    MetadataParseClaim *claim = nil;
    NSUInteger ownerIndex = 0;
    for (; ownerIndex < tracks.count; ownerIndex++) {
        claim = [_parseCoordinator claimParseForKey:entry.standardizedPath
                                        participant:tracks[ownerIndex]];
        if (claim.isOwner) {
            break;
        }
    }
    if (!claim.isOwner) {
        [self finishTracks:tracks];
        return;
    }
    AudioTrack *track = tracks[ownerIndex];
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
        [self settleTracks:tracks withMetadata:result];
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
    [self finishTracks:[tracks subarrayWithRange:NSMakeRange(0, ownerIndex + 1)]];
    // Only the row it read for takes a failure: the rows past it try the file
    // for themselves, as a record of their own.
    NSRange rest = NSMakeRange(ownerIndex + 1, tracks.count - ownerIndex - 1);
    if (rest.length > 0 && !self.isCancelled) {
        [self enqueueScanMaterialization:[[MetadataScanEntry alloc]
                initWithTracks:[tracks subarrayWithRange:rest]
              standardizedPath:entry.standardizedPath
                 playlistIndex:entry.playlistIndex]];
        [self dispatchNextScanMaterialization];
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

// Copies into every track still unresolved and publishes it, then finishes
// them all.
- (void)settleTracks:(NSArray<AudioTrack *> *)tracks withMetadata:(AudioTrackMetadata *)metadata {
    for (AudioTrack *adopted in [self installCopiesOfMetadata:metadata onTracks:tracks]) {
        [self publishTrack:adopted];
    }
    [self finishTracks:tracks];
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
    os_unfair_lock_lock(&_materializationLock);
    // Only a record not yet picked gives the row up; picked work settles it
    // normally. A record still in stage 1 is missed and costs at most one
    // transfer; its delivery no-ops.
    MetadataScanEntry *record = [self unpickedRecordHoldingTrackLocked:track];
    if (record) {
        NSMutableArray<AudioTrack *> *remaining = [record.tracks mutableCopy];
        [remaining removeObjectIdenticalTo:track];
        if (remaining.count > 0) {
            record.tracks = remaining;
        }
        else {
            [_pendingMaterializations removeObjectIdenticalTo:record];
            [_delayedScanRetryEntries removeObject:record];
        }
        _scanOrderGeneration++;
        // So an undo's prioritizeTrack: builds a fresh record.
        [_queuedTracks removeObject:track];
        [_tracksWithScanInFlight removeObject:track];
    }
    // A mark left on a removed row would hold its file's other records out of
    // the scan for good, since no record holds the row for the priority slot.
    BOOL retired = [self retirePriorityMarksTargetingTracksLocked:@[track]];
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
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
    [_priorityMarks removeAllObjects];
    [_tracksWithScanInFlight removeAllObjects];
    [_parseOperationsByTrack removeAllObjects];
    _scanOrderGeneration++;
    [_materializationAttemptsByPath removeAllObjects];
    os_unfair_lock_unlock(&_materializationLock);
    for (AudioFileMaterializationRequestToken *token in tokens) {
        [token cancel];
    }
}

@end
