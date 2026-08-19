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

- (void)loadMetadata:(NSArray<AudioTrack *> *)tracks;

// Cancels the playlist-wide scan and releases its loader, which strongly holds
// every track it queued, including each thumbnail's compact bytes. Decoded
// thumbnail pixels are held separately by a bounded shared cache. Call it on
// File > Close. Main thread only.
- (void)cancelScan;

// A jump-the-queue load for the track the user has just started. The
// playlist-wide scan must not delay the current track's header tags and art. A
// cache hit publishes immediately at user-initiated QoS. A miss takes a
// MetadataPriority materialization claim, atomically joining a same-path
// foreground open, then queues its parse on the priority workers. It is a no-op
// for already-parsed tracks, so it is cheap to call on every track start. Main
// thread only, like loadMetadata:.
- (void)loadMetadataNow:(AudioTrack *)track;

// Holds background file materialization while the foreground open is in
// flight. Cache checks continue, so already-known rows still populate. Main
// thread only; the state survives replacement of the scan loader.
- (void)setBackgroundMaterializationHeld:(BOOL)held;

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
