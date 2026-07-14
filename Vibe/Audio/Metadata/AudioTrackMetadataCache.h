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

// Empties the disk cache. Completion fires on the cache's internal queue once
// the entries are gone; a load already in flight keeps its snapshot and may
// still write entries after the clear.
- (void)invalidateWithCompletion:(nullable dispatch_block_t)completion;

@end

@protocol AudioTrackMetadataCacheDelegate <NSObject>
@optional
- (void)didLoadMetadata:(AudioTrack *)track;
@end

NS_ASSUME_NONNULL_END
