//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"
#import "MusicalKey.h"

NS_ASSUME_NONNULL_BEGIN

// Rendered verbatim in the codec label, as "<fileType> | <bitrate> | <kHz>".
// MP2 and AAC are MPEG streams told apart by layer and ADTS. ALAC is the
// lossless codec inside an MP4 container; plain FILETYPE_MP4 is AAC in MP4.
// Never localized: format acronyms, compared with isEqualToString:, and
// archived into the on-disk metadata cache.
#define FILETYPE_MP3    @"MP3"
#define FILETYPE_MP2    @"MP2"
#define FILETYPE_AAC    @"AAC"
#define FILETYPE_FLAC   @"FLAC"
#define FILETYPE_MP4    @"MP4"
#define FILETYPE_ALAC   @"ALAC"
#define FILETYPE_AIFF   @"AIFF"
#define FILETYPE_WAV    @"WAV"

@interface AudioTrackMetadata : NSObject <NSSecureCoding>

// All nullable. A failed parse populates only the filename-derived title, a
// tagless file carries no artist, audioProperties can be absent, leaving no
// bitrate or sample rate, and a validated cache decode can hand back nil for
// any field, since initWithCoder: treats them all as optional.
@property (copy, nullable) NSString *title;
@property (copy, nullable) NSString *artist;
@property (copy, nullable) NSString *fileType;
@property (copy, nullable) NSNumber *bitrate;
@property (copy, nullable) NSNumber *sampleRate;
@property (assign) NSTimeInterval duration;

// The producer-tagged tempo, from ID3 TBPM, MP4 tmpo or Vorbis and FLAC BPM,
// and 0 when the file carries none. A tagged value beats the decode-pass
// analysis in AudioTrack.detectedBPM, because DJs curate their tags.
@property (assign) float bpm;

// The producer-tagged musical key, parsed from ID3 TKEY, Vorbis and FLAC
// INITIALKEY, or the MP4 initialkey freeform atom, in any of the notations
// VibeMusicalKeyFromString reads. VibeMusicalKeyNone (-1) when the file
// carries none or the tag is unparseable — the ivar default of 0 would read
// as C major, so every init path must set it. A tagged value beats the
// decode-pass analysis in AudioTrack.detectedKey, like bpm.
@property (assign) VibeMusicalKey key;

// YES only when TagLib actually opened the file and read its tag. NO means the
// parse failed, on a dataless cloud placeholder or a transient I/O error, and
// only the filename-derived title is populated. Such an instance must never be
// persisted to the cache, or the empty entry shadows the real tags until the
// cache key changes.
@property (readonly) BOOL parsedOK;

// Full-resolution art, decoded lazily from the original compressed bytes on
// first access. Only the decoded image of a track actually displayed at full
// resolution ever lives in memory; the on-disk cache stores the compressed
// bytes. This may synchronously re-read the audio file, because cache-hit
// instances do not carry the art bytes, so never call it on the main thread: a
// cloud placeholder can block until it downloads. Use albumArtIfLoaded and
// albumArtNeedsLoad on the main thread instead. It is nil for artless tracks
// and unreadable files. It is readonly because art only ever comes from the
// file itself, through a parse or an on-demand re-extraction, or — for a file
// carrying none — from a cover beside it via FolderArtwork; there is
// deliberately no injection path.
@property (readonly, strong, nullable) VibeImage *albumArt;

// Non-blocking: it returns the art only if it has already been decoded, and
// never does decode work, since a full-resolution ImageIO decode is a 10-100ms
// hitch on the main thread.
- (nullable VibeImage *)albumArtIfLoaded;

// YES when producing albumArt still needs background work: a file read, which
// may block, or a decode of in-memory art bytes. In other words, YES means a
// background load is worth dispatching.
- (BOOL)albumArtNeedsLoad;

// Drops the full-size compressed art bytes once the thumbnail exists. Freshly
// parsed instances otherwise pin 0.5-5MB per track for the whole session.
// After this call the instance behaves exactly like a cache hit: the albumArt
// getter re-reads the audio file on demand for the one track displayed at full
// resolution. It does not invalidate an in-flight or completed decode of those
// bytes — only discardDecodedAlbumArt does — because the loader calls this
// right after publishing metadata, racing the current track's first
// full-resolution decode.
- (void)discardAlbumArtData;

// Demotes a track no longer displayed at full resolution. It drops both the
// decoded full-size image and the compressed bytes, keeps the thumbnail, and
// re-arms the on-demand load so the art returns if the track becomes current
// again. Without it, every track played in a session pins about 4MB of decoded
// art for the playlist's lifetime. Main thread only, since it resets
// albumArtLoadDispatched.
- (void)discardDecodedAlbumArt;

// Set by the UI when it starts a background albumArt load, so that repeated
// updateUI passes do not dispatch duplicates. Main thread only.
@property (assign) BOOL albumArtLoadDispatched;

// A downscaled copy of albumArt, suited to small table cells. Generated lazily
// on first read, and **the file's own thumbnail — never a folder cover — is
// what gets serialized to the on-disk cache**, so cache hits get it for free;
// see FolderArtwork for why the fallback is never persisted. Safe to call while
// drawing: it uses the fallback's non-blocking accessor.
- (nullable VibeImage *)thumbnailAlbumArt;

// Metadata-loader warm-up for embedded art only. Folder fallback stays driven
// by visible rows and the current track.
- (void)prewarmEmbeddedThumbnailAlbumArt;

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url;

- (bool)isLossless;

@end

NS_ASSUME_NONNULL_END
