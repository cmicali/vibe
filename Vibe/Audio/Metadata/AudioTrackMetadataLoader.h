//
//  AudioTrackMetadataLoader.h
//  Vibe
//
//  One sweep over one playlist; the current track is a priority record in
//  the same pending list. Cancellation drops pending work and detaches its
//  materialization tokens. Entered parses may still finish. The ivars and
//  shared methods live in AudioTrackMetadataLoaderInternal.h.
//

#import <Foundation/Foundation.h>
#import "AudioTrackMetadataCache.h"

@class AudioTrack;
@class AudioTrackMetadata;
@class AudioLoadingConfiguration;
@class AudioFileMaterializationCoordinator;

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

// Ranks these URLs within the same locality and retry class, in order.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
// The gate clock's tick, exposed so tests need not sleep.
- (void)recheckForegroundGate;

@end

// The cache read, the parse, installation, settlement and publication
// (AudioTrackMetadataLoader+Parse.m).
@interface AudioTrackMetadataLoader (Parse)

// The disk cache alone, for rows whose audio is not on the device: a hit
// installs and publishes as the sweep's does, and a miss ends there. No
// record, no materialization and no parse, so the file is never read. Any
// thread.
- (void)loadFromCacheOnly:(NSArray<AudioTrack *> *)tracks;

@end

NS_ASSUME_NONNULL_END
