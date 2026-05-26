//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;

// atomic so the loader workers (utility QoS, up to 4 in flight) can publish
// new metadata while the main thread reads it for cell rendering and the
// "currently playing" track header.
@property(atomic, strong) AudioTrackMetadata *metadata;

- (instancetype)initWithUrl:(NSURL *)url;
+ (AudioTrack *)withURL:(NSURL *)url;

- (NSString *)cacheKey;

- (NSString *)title;
- (NSString *)artist;
- (NSTimeInterval)duration;

- (void)setDuration:(NSTimeInterval)len;

- (NSString *)durationString;
- (NSImage *)albumArt;
- (nullable NSImage *)thumbnailAlbumArt;

- (BOOL)hasArtistAndTitle;

- (NSString *)singleLineTitle;

@end

NS_ASSUME_NONNULL_END
