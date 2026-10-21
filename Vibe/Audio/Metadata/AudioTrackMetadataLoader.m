//
//  AudioTrackMetadataLoader.m
//  Vibe
//
//  The loader's life and the sweep's stage 1. The lane is
//  AudioTrackMetadataLoader+Materialization.m, and the parse is
//  AudioTrackMetadataLoader+Parse.m.
//

#import "AudioTrackMetadataLoaderInternal.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioLoadingConfiguration.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "FilePaths.h"
#import "MetadataScanEntry.h"
#import "MetadataRetryRules.h"

#import "AudioTrackMetadataLoader+Debug.h"

@implementation AudioTrackMetadataLoader

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
        dispatch_queue_t callbackQueue = _materializationCallbackQueue;
        _retryScheduler = ^(NSTimeInterval delay, dispatch_block_t block) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), callbackQueue, block);
        };
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
        // One record per file, its rows in playlist order.
        NSMutableArray<MetadataScanEntry *> *worklist = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableArray<AudioTrack *> *> *rowsByPath =
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
            NSString *path = VibeStandardizedAudioOpenPath(track.url);
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

// Stage 1 reads attributes and cache entries without downloading audio.
// Scan parses wait for its barrier; priority parses are exempt. A bounded
// worker set walks the records instead of allocating one operation per row.
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

// Every miss takes the materialization path, including local files. The
// first row reads for the file; a cache hit serves every row of a cue sheet.
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
