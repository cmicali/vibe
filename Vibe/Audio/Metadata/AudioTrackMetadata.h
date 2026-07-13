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

@interface AudioTrackMetadata : NSObject <NSSecureCoding>

// All nullable: a failed parse populates only the filename-derived title, a
// tagless file carries no artist, audioProperties can be absent (no
// bitrate/sampleRate), and a validated cache decode can hand back nil for any
// field (initWithCoder: treats them all as optional).
@property (copy, nullable) NSString *title;
@property (copy, nullable) NSString *artist;
@property (copy, nullable) NSString *fileType;
@property (copy, nullable) NSNumber *bitrate;
@property (copy, nullable) NSNumber *sampleRate;
@property (assign) NSTimeInterval duration;

// YES only when TagLib actually opened the file and read its tag. NO means
// the parse failed (dataless cloud placeholder, transient I/O error) and only
// the filename-derived title is populated — such an instance must not be
// persisted to the cache, or the empty entry shadows the real tags until the
// cache key changes.
@property (readonly) BOOL parsedOK;

// Full-resolution art, lazily decoded from the original compressed bytes on
// first access. Only the decoded image of tracks actually displayed full-res
// ever lives in memory; the on-disk cache stores the compressed bytes.
// May synchronously re-read the audio FILE (cache-hit instances don't carry
// the art bytes) — never call on the main thread; a cloud placeholder file
// can block until it downloads. Use albumArtIfLoaded + albumArtNeedsLoad on
// the main thread instead. nil for artless tracks and unreadable files.
@property (strong, nullable) NSImage *albumArt;

// Non-blocking: returns the art only if it has already been decoded. Never
// does decode work — a full-res ImageIO decode is a 10-100ms hitch on the
// main thread.
- (nullable NSImage *)albumArtIfLoaded;

// YES when producing albumArt requires background work that hasn't happened
// yet — a (potentially blocking) file read, or a decode of in-memory art
// bytes — i.e. it's worth dispatching a background load.
- (BOOL)albumArtNeedsLoad;

// Drops the full-size compressed art bytes once the thumbnail exists. Freshly
// parsed instances otherwise pin 0.5-5MB per track for the session; after
// this call the instance behaves exactly like a cache hit — the albumArt
// getter re-reads the audio file on demand for the one track displayed
// full-res. Does NOT invalidate an in-flight or completed decode of those
// bytes (only discardDecodedAlbumArt does): the loader calls this right
// after publishing metadata, racing the current track's first full-res
// decode.
- (void)discardAlbumArtData;

// Demotes a track no longer displayed full-res: drops the decoded full-size
// image AND the compressed bytes (keeping the thumbnail), and re-arms the
// on-demand load so the art comes back if the track becomes current again.
// Without this every track played in a session pins ~4MB of decoded art for
// the playlist's lifetime. Main-thread use only (resets albumArtLoadDispatched).
- (void)discardDecodedAlbumArt;

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
