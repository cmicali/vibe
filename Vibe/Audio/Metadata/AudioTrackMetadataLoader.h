//
//  AudioTrackMetadataLoader.h
//  Vibe
//
//  The worker behind AudioTrackMetadataCache. Which lane it is decides four
//  coupled things at once — queue width, QoS, whether work is cancellable, and
//  how long a queued track is remembered — so the lane is an enum rather than a
//  BOOL nobody can read at the call site.
//

#import <Foundation/Foundation.h>
#import "AudioTrackMetadataCache.h"
#import "MetadataParseRunner.h"

@class AudioTrack;
@class AudioLoadingConfiguration;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VibeMetadataLane) {
    // The playlist-wide sweep. Utility QoS, cancelled and released wholesale on
    // File > Close, and it remembers every track it queued so a re-drop does
    // not re-scan the same rows.
    VibeMetadataLaneScan,
    // The jump-the-queue lane for the track the user just started. Lives for
    // the cache's lifetime, never cancelled, user-initiated QoS, and remembers
    // only in-flight tracks so a later re-click can retry a failed parse.
    VibeMetadataLaneCurrentTrack,
};

@interface AudioTrackMetadataLoader : NSObject <MetadataParseRunnerDelegate>

@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
                         lane:(VibeMetadataLane)lane;

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
                         lane:(VibeMetadataLane)lane
         loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration
        NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Stage 1 of the playlist sweep; see the directory's CLAUDE.md for the map.
- (void)load:(NSArray<AudioTrack *> *)tracks;
// The current-track lane's single-track entry point.
- (void)loadSingleTrack:(AudioTrack *)track;
// Locally gates new scan materialization requests. The cache also owns the
// central coordinator hold that yields an already-registered request. The
// current-track lane uses the same edge to park a delayed yielded retry until
// the foreground hold releases.
- (void)setCloudParsesHeld:(BOOL)held;

// Re-ranks the pending cloud parses so these URLs go first, in the order
// given; everything else falls to the back of the sweep. See
// AudioTrackMetadataCache.setNeighborhoodURLs:.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
