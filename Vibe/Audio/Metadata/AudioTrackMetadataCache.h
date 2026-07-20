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

// Jump-the-queue load for the track the user just started. The playlist-wide
// loadMetadata: scan is FIFO with a handful of workers that a cloud-heavy
// folder can keep blocked for minutes, and the current track's header
// tags/art must never wait behind it. Cache hits publish immediately at
// user-initiated QoS; a cache miss parses the file inline unless it's a
// dataless cloud placeholder (the player's own open is already downloading
// it — call again once playback starts and the parse runs then). No-op for
// already-parsed tracks, so it's cheap to call on every track start.
// Main thread only (like loadMetadata:).
- (void)loadMetadataNow:(AudioTrack *)track;

// Empties the disk cache. Completion fires on the cache's internal queue once
// the entries are gone; a load already in flight keeps its snapshot and may
// still write entries after the clear.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
- (void)didLoadMetadata:(AudioTrack *)track;
@end

NS_ASSUME_NONNULL_END
