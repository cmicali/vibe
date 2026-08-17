//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioTrackMetadataCacheDelegate;
@class AudioTrack;

@interface AudioTrackMetadataCache : NSObject

@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

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
// playlist-wide loadMetadata: scan is FIFO across a handful of workers that a
// cloud-heavy folder can keep blocked for minutes, and the current track's
// header tags and art must never wait behind it. A cache hit publishes
// immediately at user-initiated QoS. A cache miss parses the file inline
// unless it is a dataless cloud placeholder, in which case the player's own
// open is already downloading it: call again once playback starts and the
// parse runs then. It is a no-op for already-parsed tracks, so it is cheap to
// call on every track start. Main thread only, like loadMetadata:.
- (void)loadMetadataNow:(AudioTrack *)track;

// The foreground-download hold: the one open the user is waiting on outranks
// every background parse that would download a file of its own. Held, the
// scan's cloud lane stops starting parses of dataless files; the wide lane's
// local parses and both lanes' stage-1 cache checks — a stat and a small disk
// read — carry on, so rows keep populating from cache while the current track
// materializes. It survives a loadMetadata:, which mints a fresh loader.
// Set it while the player's own open is in flight and clear it when that open
// lands or fails; both screens hang it off the download monitor's lifetime.
// Main thread only, like the two loads above.
- (void)setCloudParsesHeld:(BOOL)held;

// The neighborhood: the tracks worth parsing before the rest of the sweep, in
// the order given — next up first, then the one after, then the one behind.
// It only reorders the cloud lane, where the order is the whole story, because
// each of those parses is a whole file coming down a wire one at a time and a
// listener reaches the next track long before the folder's tail. Local parses
// need no such help: they are milliseconds apart. Re-send it on every track
// change; like the hold, it survives a loadMetadata:. Main thread only.
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;

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
