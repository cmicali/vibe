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

// Empties the disk cache. The completion fires on the cache's internal queue
// once the entries are gone. A load already in flight keeps its snapshot and
// may still write entries after the clear.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
- (void)didLoadMetadata:(AudioTrack *)track;
@end

NS_ASSUME_NONNULL_END
