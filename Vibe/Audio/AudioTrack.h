//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;

@property(nonatomic, strong) AudioTrackMetadata *metadata;

- (instancetype)initWithUrl:(NSURL *)url;
+ (AudioTrack *)withURL:(NSURL *)url;

- (NSString *)fileHash;
- (NSString *)calculateFileHash;

- (NSString *)title;
- (NSString *)artist;
- (NSTimeInterval)duration;

- (void)setDuration:(NSTimeInterval)len;

- (NSString *)durationString;
- (NSImage *)albumArt;

- (BOOL)hasArtistAndTitle;

- (NSString *)singleLineTitle;

@end

NS_ASSUME_NONNULL_END
