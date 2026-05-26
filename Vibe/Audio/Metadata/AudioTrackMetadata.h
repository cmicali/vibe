//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#define FILETYPE_MP3    @"MP3"
#define FILETYPE_FLAC   @"FLAC"
#define FILETYPE_MP4    @"MP4"
#define FILETYPE_AIFF   @"AIFF"
#define FILETYPE_WAV    @"WAV"
#define FILETYPE_OGG    @"OGG"

@interface AudioTrackMetadata : NSObject <NSCoding>

@property (copy) NSString *title;
@property (copy) NSString *artist;
@property (copy) NSString *fileType;
@property (copy) NSNumber *bitrate;
@property (copy) NSNumber *sampleRate;
@property (assign) NSTimeInterval duration;

@property (strong) NSImage *albumArt;

// Downscaled copy of albumArt suitable for small table cells. Generated lazily
// the first time it's read; not serialized to the on-disk cache (cheap to
// regenerate from albumArt on cache hit).
- (nullable NSImage *)thumbnailAlbumArt;

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url;

- (bool)isLossless;

@end

NS_ASSUME_NONNULL_END
