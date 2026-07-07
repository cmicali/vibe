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
// May synchronously re-read the audio FILE (cache-hit instances don't carry
// the art bytes) — never call on the main thread; a cloud placeholder file
// can block until it downloads. Use albumArtIfLoaded + albumArtNeedsLoad on
// the main thread instead.
@property (strong) NSImage *albumArt;

// Non-blocking: returns the art only if it can be produced without touching
// the audio file (already decoded, or decodable from in-memory bytes).
- (nullable NSImage *)albumArtIfLoaded;

// YES when albumArt would need a (potentially blocking) file read that hasn't
// been attempted yet — i.e. it's worth dispatching a background load.
- (BOOL)albumArtNeedsLoad;

// Set by the UI when it kicks off a background albumArt load, so repeated
// updateUI passes don't dispatch duplicates. Main-thread use only.
@property (assign) BOOL albumArtLoadDispatched;

// Downscaled copy of albumArt suitable for small table cells. Generated lazily
// the first time it's read and serialized to the on-disk cache, so cache hits
// get it for free.
- (nullable NSImage *)thumbnailAlbumArt;

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url;

- (bool)isLossless;

@end

NS_ASSUME_NONNULL_END
