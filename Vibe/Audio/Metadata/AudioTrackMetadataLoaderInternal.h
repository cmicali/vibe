//
//  AudioTrackMetadataLoaderInternal.h
//  Vibe
//
//  One sweep over one playlist; the current track is a priority record in
//  the same pending list. Everything a loader holds dies with it when the
//  cache replaces or cancels it, which is what drops the old playlist's
//  downloads.
//

#import <Foundation/Foundation.h>
#import "AudioTrackMetadataCache.h"

#include <os/lock.h>

@class AudioTrack;
@class AudioTrackMetadata;
@class AudioLoadingConfiguration;
@class AudioFileMaterializationCoordinator;
@class AudioFileMaterializationRequestToken;
@class MetadataParseCoordinator;
@class MetadataScanEntry;
@class MetadataPriorityMark;

typedef AudioTrackMetadata * _Nullable (^VibeAudioTrackMetadataCacheReader)(
        AudioTrack * _Nonnull track);
typedef AudioTrackMetadata * _Nonnull (^VibeAudioTrackMetadataFileParser)(
        NSURL * _Nonnull url);

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataLoader : NSObject

@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

// Host-less seam: a coordinator faked at its provider-operation boundary, and
// replaceable cache reads and parsing.
- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(nullable id <AudioTrackMetadataCacheDelegate>)delegate
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration
    materializationCoordinator:(AudioFileMaterializationCoordinator *)materializationCoordinator
                   cacheReader:(nullable VibeAudioTrackMetadataCacheReader)cacheReader
                    fileParser:(nullable VibeAudioTrackMetadataFileParser)fileParser
        NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (void)load:(NSArray<AudioTrack *> *)tracks;
- (void)cancel;

@end

// AudioTrackMetadataLoader.m is the loader's life and the sweep's stage 1.
// Each category below is one more file of the same object.
@interface AudioTrackMetadataLoader () {
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
}
@end

// The materialization lane: priority marks, the two slots, the foreground
// gate and each completion's settlement
// (AudioTrackMetadataLoader+Materialization.m).
@interface AudioTrackMetadataLoader (Materialization)

// Marks the record holding the track (or its file's pending record, or a new
// one) as priority: its own slot, exempt from the stage-1 barrier, submitted
// even under the foreground rule, parsed user-initiated. A repeat edge
// reactivates one submission, so it can join a new same-path foreground claim
// without waiting for the gate clock. Main thread.
- (void)prioritizeTrack:(AudioTrack *)track;

// Takes one departed row out of its not-yet-picked record, dropping the record
// once empty, and forgets the row, so a later prioritizeTrack: rebuilds it.
// Picked work settles normally. Main thread.
- (void)abandonQueuedTrack:(AudioTrack *)track;

// These URLs go first, in order.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
// The gate clock's tick, exposed so tests need not sleep.
- (void)recheckForegroundGate;

// For the loader's other files.
- (void)enqueueScanMaterialization:(MetadataScanEntry *)entry;
- (void)dispatchNextScanMaterialization;
- (nullable MetadataPriorityMark *)priorityMarkForEntryLocked:(MetadataScanEntry *)entry;
- (nullable MetadataPriorityMark *)leadEntryWithItsMarkedRowLocked:(MetadataScanEntry *)entry;
- (BOOL)retirePriorityMarksTargetingTracksLocked:(NSArray<AudioTrack *> *)tracks;
- (void)retirePriorityMarksSatisfiedByTracks:(NSArray<AudioTrack *> *)tracks;

@end

// The cache read, the parse, installation, settlement and publication
// (AudioTrackMetadataLoader+Parse.m).
@interface AudioTrackMetadataLoader (Parse)

// The disk cache alone, for rows whose audio is not on the device: a hit
// installs and publishes as the sweep's does, and a miss ends there. No
// record, no materialization and no parse, so the file is never read. Any
// thread.
- (void)loadFromCacheOnly:(NSArray<AudioTrack *> *)tracks;

// For the loader's other files.
- (BOOL)loadTrackFromDiskCache:(AudioTrack *)track;
- (BOOL)scheduleParseForEntry:(MetadataScanEntry *)entry
                userInitiated:(BOOL)userInitiatedParse;
- (void)finishTracks:(NSArray<AudioTrack *> *)tracks;
- (void)settleTracks:(NSArray<AudioTrack *> *)tracks withMetadata:(AudioTrackMetadata *)metadata;

@end

NS_ASSUME_NONNULL_END
