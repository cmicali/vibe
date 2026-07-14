//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy) NSURL *url;

// atomic so the loader workers (utility QoS, up to 4 in flight) can publish
// new metadata while the main thread reads it for cell rendering and the
// "currently playing" track header.
@property(atomic, strong) AudioTrackMetadata *metadata;

// Tempo from the waveform decode pass (0 = not yet analyzed / undetectable).
// Transient — persistence lives in the waveform cache, which re-delivers it
// on every load. A tagged tempo (metadata.bpm) takes precedence for display.
@property(atomic, assign) float detectedBPM;

- (instancetype)initWithUrl:(NSURL *)url;
+ (AudioTrack *)withURL:(NSURL *)url;

- (NSString *)cacheKey;

- (NSString *)title;
- (NSString *)artist;
- (NSTimeInterval)duration;

- (void)setDuration:(NSTimeInterval)len;

- (NSString *)durationString;
- (NSImage *)albumArt;
- (nullable NSImage *)thumbnailAlbumArt;

- (BOOL)hasArtistAndTitle;

- (NSString *)singleLineTitle;

@end

NS_ASSUME_NONNULL_END
