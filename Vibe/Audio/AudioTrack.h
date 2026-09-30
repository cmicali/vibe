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
// the single home of the tag-over-analysis precedence. A windowed row skips
// the tag, which describes its whole file. Not pitch-adjusted: a caller
// wanting the tempo as heard scales it by the varispeed rate.
- (float)bpm;

// The musical key from the waveform decode pass; VibeMusicalKeyNone means not
// yet analyzed or undetectable. Transient like detectedBPM. Every init path
// must set it to VibeMusicalKeyNone: a zero-filled ivar reads as C major.
@property(atomic, assign) VibeMusicalKey detectedKey;

// The key to act on: metadata.key when tagged, else detectedKey, else
// VibeMusicalKeyNone. Mirrors bpm, a windowed row included.
- (VibeMusicalKey)key;

- (instancetype)initWithURL:(NSURL *)url NS_DESIGNATED_INITIALIZER;
+ (AudioTrack *)withURL:(NSURL *)url;

// A cue sheet's row: a window of its file and the sheet's names for it, set
// once here before the track crosses a thread. Never written into
// AudioTrackMetadata, which is cached under the file's key and shared by every
// row of it. The window is in CD frames (1/75 s), start inclusive and end
// exclusive; an end of 0 runs to the file's end.
- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end
                      title:(nullable NSString *)title performer:(nullable NSString *)performer
                      sheet:(nullable NSURL *)sheet trackNumber:(NSInteger)trackNumber;
@property (readonly) NSUInteger cueStart;
@property (readonly) NSUInteger cueEnd;
@property (copy, readonly, nullable) NSString *cueTitle;
@property (copy, readonly, nullable) NSString *cuePerformer;
@property (copy, readonly, nullable) NSURL *cueSheetURL;
@property (readonly) NSInteger cueTrackNumber;

// YES when the row plays less than its whole file.
- (BOOL)isWindowed;

// What sounds: the file's path, plus the window for a windowed row, so rows of
// one file differ. An identity to compare, never a path to open.
- (NSString *)sourceKey;

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

// How every surface names a track: the title and artist when both exist — a
// cue row's own before its file's tags — else the single line as the title
// and a nil artist, which means no second line rather than an empty one.
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
