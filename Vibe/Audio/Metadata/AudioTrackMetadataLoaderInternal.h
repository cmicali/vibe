//
//  AudioTrackMetadataLoaderInternal.h
//  Vibe
//
//  The worker behind AudioTrackMetadataCache: one sweep over one playlist,
//  with the current track carried as a priority-flagged record in the same
//  pending list and dispatched through its priority slot. A loader lives until the next
//  loadMetadata: replaces it, and everything it holds — records, tracks,
//  in-flight priority work — dies with it, which is what makes playlist
//  replacement drop the old playlist's downloads by construction.
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

// Host-less orchestration seam. The real queue, stage-1 barrier, scan records,
// materialization slots, parse claims, installation, publication and
// cancellation path stay in play. Tests inject a real coordinator configured
// at its provider-operation boundary; cache reads and file parsing are the
// other replaceable boundaries.
- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(nullable id <AudioTrackMetadataCacheDelegate>)delegate
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration
    materializationCoordinator:(AudioFileMaterializationCoordinator *)materializationCoordinator
                   cacheReader:(nullable VibeAudioTrackMetadataCacheReader)cacheReader
                    fileParser:(nullable VibeAudioTrackMetadataFileParser)fileParser
        NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Stage 1 of the playlist sweep; see the directory's CLAUDE.md for the map.
- (void)load:(NSArray<AudioTrack *> *)tracks;
// Marks (or creates) the track's record as priority: materialized through its
// own slot ahead of the sweep's, exempt from the stage-1 barrier, submitted
// even while the foreground rule is in force (a same-path playback claim
// serves it for free), and parsed at user-initiated QoS. Main thread.
// A repeat edge reactivates one priority submission. That lets metadata join a
// newly active same-path playback/prefetch claim instead of waiting for the
// bounded gate clock. The record still owns its retry budget. The foreground/
// background rule itself is the materialization coordinator's: the sweep asks
// isForegroundTransferActive before submitting dataless records and re-asks on
// a bounded 1s clock while gated.
- (void)prioritizeTrack:(AudioTrack *)track;

// Re-ranks pending scan materializations so these URLs go first, in the order
// given; everything else falls to the back of the sweep.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
// The gated clock's action, shared with host-less tests so the release edge
// can be judged without sleeping for the production one-second cadence.
- (void)recheckForegroundGate;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
