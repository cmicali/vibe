//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"
#import "MusicalKey.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;

// Atomic, so that the loader workers — utility QoS, up to four in flight —
// can publish new metadata while the main thread reads it for cell rendering
// and the currently-playing track header. It is nil until a loader delivers,
// and every consumer below nil-checks it.
@property(atomic, strong, nullable) AudioTrackMetadata *metadata;

// The tempo from the waveform decode pass; 0 means not yet analyzed or
// undetectable. It is transient, because persistence lives in the waveform
// cache, which re-delivers it on every load. A tagged tempo, metadata.bpm,
// takes precedence for display.
@property(atomic, assign) float detectedBPM;

// The tempo consumers should act on: the file's own tag, metadata.bpm, when
// present, otherwise the analyzed detectedBPM, and 0 when neither is known.
// This is the single home of the tag-over-analysis precedence, shared by the
// BPM label, the bar-aligned skips and the delay tap sync. It is the track's
// own tempo and is not pitch-adjusted, so a caller who wants the tempo as
// heard scales it by the varispeed rate.
- (float)bpm;

// The musical key from the waveform decode pass; VibeMusicalKeyNone (-1)
// means not yet analyzed or undetectable. Transient like detectedBPM, and
// every init path must set it to -1, because the zero-filled ivar default
// reads as C major. A tagged key, metadata.key, takes precedence for display.
@property(atomic, assign) VibeMusicalKey detectedKey;

// The key consumers should act on: the file's own tag, metadata.key, when
// present, otherwise the analyzed detectedKey, and VibeMusicalKeyNone when
// neither is known. The single home of the tag-over-analysis precedence,
// mirroring bpm.
- (VibeMusicalKey)key;

- (instancetype)initWithUrl:(NSURL *)url;
+ (AudioTrack *)withURL:(NSURL *)url;

// The memoized file-identity key for the metadata and waveform caches; see
// NSURL+Hash. It is nil when the file cannot be statted, which is treated as
// transient and not memoized, so a later call retries. Callers must skip
// caching when it is nil.
- (nullable NSString *)cacheKey;

- (NSString *)title;
- (NSString *)artist;
- (NSTimeInterval)duration;

- (void)setDuration:(NSTimeInterval)len;

- (NSString *)durationString;
// Non-blocking, through metadata.cachedArt: nil until the art is
// decoded.
- (nullable VibeImage *)cachedArt;
- (nullable VibeImage *)cachedThumbnail;

- (BOOL)hasArtistAndTitle;

- (NSString *)singleLineTitle;

@end

NS_ASSUME_NONNULL_END
