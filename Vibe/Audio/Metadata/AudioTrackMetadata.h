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

// Full-resolution art, lazily decoded from the original compressed bytes on
// first access. Only the decoded image of tracks actually displayed full-res
// ever lives in memory; the on-disk cache stores the compressed bytes.
@property (strong) NSImage *albumArt;

// Downscaled copy of albumArt suitable for small table cells. Generated lazily
// the first time it's read and serialized to the on-disk cache, so cache hits
// get it for free.
- (nullable NSImage *)thumbnailAlbumArt;

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url;

- (bool)isLossless;

@end

NS_ASSUME_NONNULL_END
