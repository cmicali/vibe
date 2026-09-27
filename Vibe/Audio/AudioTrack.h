//
//  AudioTrack.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"
#import "MusicalKey.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;

@interface AudioTrack : NSObject

@property (copy, readonly) NSURL *url;

// Atomic: loader workers publish it while main reads it. nil until a loader
// delivers.
@property(atomic, strong, nullable, readonly) AudioTrackMetadata *metadata;

// The tempo from the waveform decode pass; 0 means not yet analyzed or
// undetectable. Transient: the waveform cache re-delivers it on every load.
@property(atomic, assign) float detectedBPM;

// The tempo to act on: metadata.bpm when tagged, else detectedBPM, else 0 —
// the single home of the tag-over-analysis precedence. Not pitch-adjusted: a
// caller wanting the tempo as heard scales it by the varispeed rate.
- (float)bpm;

// The musical key from the waveform decode pass; VibeMusicalKeyNone means not
// yet analyzed or undetectable. Transient like detectedBPM. Every init path
// must set it to VibeMusicalKeyNone: a zero-filled ivar reads as C major.
@property(atomic, assign) VibeMusicalKey detectedKey;

// The key to act on: metadata.key when tagged, else detectedKey, else
// VibeMusicalKeyNone. Mirrors bpm.
- (VibeMusicalKey)key;

- (instancetype)initWithURL:(NSURL *)url NS_DESIGNATED_INITIALIZER;
+ (AudioTrack *)withURL:(NSURL *)url;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// The memoized NSURL+Hash key for the metadata and waveform caches. nil when
// the file cannot be statted — not memoized, so a later call retries — and a
// caller must then skip caching.
- (nullable NSString *)cacheKey;

- (NSString *)title;
- (NSString *)artist;
- (NSTimeInterval)duration;

- (void)setDuration:(NSTimeInterval)len;

- (NSString *)durationString;
// Non-blocking: nil until the art is decoded.
- (nullable VibeImage *)cachedArt;
- (nullable VibeImage *)cachedThumbnail;

- (BOOL)hasArtistAndTitle;

- (NSString *)singleLineTitle;

// How every surface names a track: the tagged title and artist when both
// exist, else the filename-derived single line as the title and a nil artist,
// which means no second line rather than an empty one.
- (NSString *)displayTitle;
- (nullable NSString *)displayArtist;

// The last path component without its extension, trimmed: title until
// metadata loads, and what a tagless file records, so the row does not change
// when metadata arrives. Not standardized, which would stat the path.
+ (NSString *)filenameTitleForURL:(NSURL *)url;

@end

// Rows by index, so a caller wanting a few neighbours need not take the mac
// playlist's defensive copy, O(playlist) retains on every play.
@protocol AudioTrackIndexedSource <NSObject>
- (nullable AudioTrack *)trackAtIndex:(NSUInteger)index;
- (NSUInteger)count;
@end

NS_ASSUME_NONNULL_END
