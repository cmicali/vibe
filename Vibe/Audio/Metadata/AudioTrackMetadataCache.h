//
//  AudioTrackMetadataCache.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioTrackMetadataCacheDelegate;
@protocol AudioTrackIndexedSource;   // AudioTrack.h
@class AudioTrack;

@interface AudioTrackMetadataCache : NSObject

@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

- (void)loadMetadata:(NSArray<AudioTrack *> *)tracks;

// Cancels the scan and releases its loader, which holds every queued track.
// File > Close. Main thread only.
- (void)cancelScan;

// The track the user just started, ahead of the scan: a cache hit publishes
// at user-initiated QoS; a miss takes a MetadataPriority claim, joining a
// same-path foreground open. A no-op once parsed, so cheap on every start.
// Main thread only.
- (void)loadMetadataNow:(AudioTrack *)track;

// A removed row's queued scan work, so it spends no transfer; an undo
// re-requests through loadMetadataNow:. In-flight work settles and the
// receivers drop its delivery. Main thread only.
- (void)abandonQueuedTrack:(AudioTrack *)track;

// Ranks the pending scan around the track at index (next, second-next,
// previous). Both shells call it from their current-index funnel. Takes the
// playlist, not an array: it reads three rows, and the mac `tracks` getter
// copies the whole list. Main thread only.
- (void)setNeighborhoodAroundIndex:(NSUInteger)index
                          inTracks:(id<AudioTrackIndexedSource>)tracks;

// The completion fires on the cache's internal queue. A parse in flight
// cannot repopulate it, though its UI delivery still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

// Enumerated off the calling thread; the completion runs on main.
- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
- (void)didLoadMetadata:(AudioTrack *)track;
@end

NS_ASSUME_NONNULL_END
