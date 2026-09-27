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
// Marks (or creates) the track's record as priority: its own slot, exempt from
// the stage-1 barrier, submitted even under the foreground rule, parsed
// user-initiated. A repeat edge reactivates one submission, so it can join a
// new same-path foreground claim without waiting for the gate clock. Main
// thread.
- (void)prioritizeTrack:(AudioTrack *)track;

// Drops one departed row's not-yet-picked records and, when nothing is in
// flight for it, its identity marks, so a later prioritizeTrack: rebuilds it.
// Picked work settles normally. Main thread.
- (void)abandonQueuedTrack:(AudioTrack *)track;

// These URLs go first, in order.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
// The gate clock's tick, exposed so tests need not sleep.
- (void)recheckForegroundGate;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
