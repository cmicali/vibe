//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class AudioTrackMetadata;

@interface AudioTrackMetadataCache : NSObject

- (void)invalidate;

- (void)metadataForTrack:(AudioTrack *)track block:(void (^)(AudioTrackMetadata *))block;
- (AudioTrackMetadata *)metadataForTrack:(AudioTrack *)track orLoad:(void (^)(AudioTrackMetadata *))block;

@end

NS_ASSUME_NONNULL_END
