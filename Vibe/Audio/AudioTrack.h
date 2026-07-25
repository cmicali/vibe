//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;

// atomic so the loader workers (utility QoS, up to 4 in flight) can publish
// new metadata while the main thread reads it for cell rendering and the
// "currently playing" track header. nil until a loader delivers (every
// consumer below nil-checks it).
@property(atomic, strong, nullable) AudioTrackMetadata *metadata;

// Tempo from the waveform decode pass (0 = not yet analyzed / undetectable).
// Transient — persistence lives in the waveform cache, which re-delivers it
// on every load. A tagged tempo (metadata.bpm) takes precedence for display.
@property(atomic, assign) float detectedBPM;

// The tempo consumers should act on: the file's own tag (metadata.bpm) when
// present, else the analyzed detectedBPM; 0 when neither is known. The single
// home of the tag-over-analysis precedence (BPM label, bar-aligned skips,
// delay tap sync). This is the track's own tempo, NOT pitch-adjusted — a
// caller that wants the tempo as heard scales it by the varispeed rate.
- (float)bpm;

- (instancetype)initWithUrl:(NSURL *)url;
+ (AudioTrack *)withURL:(NSURL *)url;

// Memoized file-identity key for the metadata/waveform caches (see
// NSURL+Hash). nil when the file can't be statted — treated as transient and
// not memoized, so a later call retries; callers must skip caching on nil.
- (nullable NSString *)cacheKey;

- (NSString *)title;
- (NSString *)artist;
- (NSTimeInterval)duration;

- (void)setDuration:(NSTimeInterval)len;

- (NSString *)durationString;
// Non-blocking (metadata.albumArtIfLoaded): nil until the art is decoded.
- (nullable NSImage *)albumArt;
- (nullable NSImage *)thumbnailAlbumArt;

- (BOOL)hasArtistAndTitle;

- (NSString *)singleLineTitle;

@end

NS_ASSUME_NONNULL_END
