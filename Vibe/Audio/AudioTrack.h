//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;

@property(nonatomic, strong) AudioTrackMetadata *metadata;

+ (AudioTrack *)withURL:(NSURL *)url;
+ (AudioTrack *)empty;

- (instancetype)initWithUrl:(NSURL *)url;

- (NSString *)title;
- (NSString *)artist;
- (NSUInteger)length;
- (NSString *)lengthString;
- (NSImage *)albumArt;

- (BOOL)hasArtistAndTitle;

- (NSString *)singleLineTitle;

@end

NS_ASSUME_NONNULL_END
