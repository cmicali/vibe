//
//  AudioTrackMetadataLoaderInternal.h
//  Vibe
//
//  The private header the loader's three files share: every ivar, and the
//  methods one file implements for the others. AudioTrackMetadataLoader.m is
//  the loader's life and the sweep's stage 1. Each category below is one more
//  file of the same object. The debug seam and the scan benchmark import it
//  too, for the ivars.
//

#import "AudioTrackMetadataLoader.h"
#import "HelperMacros.h"

#include <os/lock.h>

@class AudioFileMaterializationRequestToken;
@class MetadataParseCoordinator;
@class MetadataScanEntry;
@class MetadataPriorityMark;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataLoader () {
    // Re-read at use: the owner builds its PINCache asynchronously, and an
    // early snapshot would freeze nil for the loader's life.
    __weak AudioTrackMetadataCache* _owner;
    NSOperationQueue* _queue;
    // By identity, not inferred from track.metadata: a failed parse must stay
    // eligible for a later loader. Guarded by _materializationLock.
    NSMutableSet<id<AudioTrackMetadataHolder>>* _queuedTracks;
    // Tracks whose record, materialization or parse can still settle a
    // priority mark; a priority edge for any other track mints a fresh
    // cache-check record. Guarded by _materializationLock.
    NSMutableSet<id<AudioTrackMetadataHolder>>* _tracksWithScanInFlight;
    // Every row of a parse's record, so a priority edge after Ready can
    // promote a queued utility parse. Guarded by _materializationLock.
    NSMapTable<id<AudioTrackMetadataHolder>, NSOperation *> *_parseOperationsByTrack;
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
    // Debug builds only (AudioTrackMetadataLoader+Debug.m). Guarded by
    // _materializationLock.
    dispatch_block_t _debugBeforeScanPickValidation;
    NSQualityOfService _debugLastScheduledParseQualityOfService;
    // The retry scheduler's storage, declared so the categories see it.
    VibeScheduler _retryScheduler;
}

// Test seam for the admission retry's delay; the default schedules on the
// materialization callback queue.
@property (nonatomic, copy) VibeScheduler retryScheduler;
@end

// AudioTrackMetadataLoader+Materialization.m, for the loader's other files.
@interface AudioTrackMetadataLoader (MaterializationInternal)

- (void)enqueueScanMaterialization:(MetadataScanEntry *)entry;
- (void)dispatchNextScanMaterialization;
- (nullable MetadataPriorityMark *)priorityMarkForEntryLocked:(MetadataScanEntry *)entry;
- (nullable MetadataPriorityMark *)leadEntryWithItsMarkedRowLocked:(MetadataScanEntry *)entry;
- (BOOL)retirePriorityMarksTargetingTracksLocked:(NSArray<id<AudioTrackMetadataHolder>> *)tracks;
- (void)retirePriorityMarksSatisfiedByTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks;

@end

// AudioTrackMetadataLoader+Parse.m, for the loader's other files.
@interface AudioTrackMetadataLoader (ParseInternal)

- (BOOL)holdsCurrentMetadata:(id<AudioTrackMetadataHolder>)track;
- (BOOL)loadTrackFromDiskCache:(id<AudioTrackMetadataHolder>)track;
- (BOOL)scheduleParseForEntry:(MetadataScanEntry *)entry
                userInitiated:(BOOL)userInitiatedParse;
- (void)finishTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks;
- (void)settleTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks withMetadata:(AudioTrackMetadata *)metadata;

@end

NS_ASSUME_NONNULL_END
