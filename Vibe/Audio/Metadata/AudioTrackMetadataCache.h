//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioTrackMetadataCacheDelegate;
@class AudioTrack;
@class AudioLoadingConfiguration;

@interface AudioTrackMetadataCache : NSObject

@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;
@property (nonatomic, readonly) AudioLoadingConfiguration *loadingConfiguration;

- (instancetype)initWithLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration
        NS_DESIGNATED_INITIALIZER;

// Applies only to loaders constructed after this call. A scan already running
// keeps its snapshot; the priority loader retires after its submitted work and
// the next priority request gets a loader built from the new configuration.
// Main thread only, like the loading entry points below.
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

// The PINCache store name, which embeds the archive-format version; see the
// implementation. It is the single source for init and for anything that
// reports the name, such as the debug clear_caches reply.
+ (NSString *)cacheName;

- (void)loadMetadata:(NSArray<AudioTrack *> *)tracks;

// Cancels the playlist-wide scan and releases its loader, which strongly holds
// every track it queued, thumbnails included. Call it on File > Close. Main
// thread only.
- (void)cancelAll;

// A jump-the-queue load for the track the user has just started. The
// playlist-wide scan must not delay the current track's header tags and art. A
// cache hit publishes immediately at user-initiated QoS. A miss takes a
// MetadataPriority materialization claim, atomically joining a same-path
// foreground open, then queues its parse on the priority workers. It is a no-op
// for already-parsed tracks, so it is cheap to call on every track start. Main
// thread only, like loadMetadata:.
- (void)loadMetadataNow:(AudioTrack *)track;

// The foreground-download hold: the one open the user is waiting on outranks
// every background parse that would download a file of its own. Held, the
// scan stops registering materialization requests; both lanes' stage-1 cache
// checks — a stat and a small disk read — carry on, so rows keep populating
// from cache while the current track materializes. The cache also owns the
// corresponding central hold. It survives loadMetadata:, which mints a fresh loader.
// Set it while the player's own open is in flight and clear it when that open
// lands or fails; both screens hang it off the download monitor's lifetime.
// Main thread only, like the two loads above.
- (void)setCloudParsesHeld:(BOOL)held;

// The neighborhood: the tracks worth parsing before the rest of the sweep, in
// the order given — next up first, then the one after, then the one behind.
// It reorders the scan's one-at-a-time materialization submissions, because a
// miss may be a whole file coming down a wire and a listener reaches the next
// track long before the folder's tail. Ready files still parse concurrently.
// Re-send it on every track change; like the hold, it survives a loadMetadata:.
// Main thread only.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;

// The same ranking, expressed as a playlist position — which is what a shell
// actually has at hand. The offset table lives here rather than in each shell,
// so there is one of it rather than one per platform: both shells call this
// from their single current-index funnel, and the shell left to compute its
// own ended up not calling at all. Main thread only.
- (void)setNeighborhoodAroundIndex:(NSUInteger)index
                          inTracks:(NSArray<AudioTrack *> *)tracks;

// Empties the disk cache. The completion fires on the cache's internal queue
// once the entries are gone. A parse already in flight cannot repopulate it:
// a cache-generation check drops its disk write, though its UI delivery
// still happens.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

// The backing store's entry count and total bytes on disk, enumerated off the
// calling thread; the completion runs on the main thread.
- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
- (void)didLoadMetadata:(AudioTrack *)track;
@end

NS_ASSUME_NONNULL_END
