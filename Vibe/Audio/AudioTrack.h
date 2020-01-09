//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;
@property (copy) NSString *title;
@property (copy) NSString *artist;
@property (assign) BOOL metadataLoaded;

- (instancetype)initWithUrl:(NSURL *)url;
+ (AudioTrack *)withURL:(NSURL *)url;

- (NSString *)fileHash;
- (NSString *)calculateFileHash;

- (NSTimeInterval)duration;
- (void)setDuration:(NSTimeInterval)len;
- (NSString *)durationString;

- (BOOL)hasArtistAndTitle;
- (NSString *)singleLineTitle;

@end

NS_ASSUME_NONNULL_END
