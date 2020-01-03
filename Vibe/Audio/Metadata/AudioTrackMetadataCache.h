//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioTrackMetadataManagerDelegate;
@class AudioTrack;

@interface AudioTrackMetadataCache : NSObject

@property (nullable, weak) id <AudioTrackMetadataManagerDelegate> delegate;

- (void)loadMetadata:(NSArray<AudioTrack *> *)tracks;

@end

@protocol AudioTrackMetadataManagerDelegate <NSObject>
@optional
- (void)didLoadMetadata:(AudioTrack *)track;
@end

NS_ASSUME_NONNULL_END
