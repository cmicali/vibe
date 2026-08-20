//
//  AudioTrackMetadataLoaderInternal.h
//  Vibe
//
//  The worker behind AudioTrackMetadataCache: one sweep over one playlist,
//  with the current track carried as a priority-flagged record in the same
//  pending list rather than a second lane. A loader lives until the next
//  loadMetadata: replaces it, and everything it holds — records, tracks,
//  in-flight priority work — dies with it, which is what makes playlist
//  replacement drop the old playlist's downloads by construction.
//

#import <Foundation/Foundation.h>
#import "AudioTrackMetadataCache.h"

@class AudioTrack;
@class AudioLoadingConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataLoader : NSObject

@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration
        NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Stage 1 of the playlist sweep; see the directory's CLAUDE.md for the map.
- (void)load:(NSArray<AudioTrack *> *)tracks;
// Marks (or creates) the track's record as priority: materialized through its
// own slot ahead of the sweep's, exempt from the stage-1 barrier, submitted
// even while the foreground rule is in force (a same-path playback claim
// serves it for free), and parsed at user-initiated QoS. Main thread.
// Idempotent — the record owns its retries, so a repeat edge has nothing to
// add. The foreground/background rule itself is the materialization
// coordinator's: the sweep asks isForegroundTransferActive before submitting
// dataless records and re-asks on a bounded 1s clock while gated.
- (void)prioritizeTrack:(AudioTrack *)track;

// Re-ranks pending scan materializations so these URLs go first, in the order
// given; everything else falls to the back of the sweep.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
