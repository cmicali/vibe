//
//  AudioTrack.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"
#import "MusicalKey.h"
#import "AudioTrackMetadataHolder.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrackMetadata;
@class PlaylistEntry;

// A playlist row: a file whole, or a cue sheet's window of one. What the
// player and the caches read of it is VibePlayableItem. The metadata loader
// installs its results through AudioTrackMetadataHolder, which extends it.
// TRAP: the player's id<VibePlayableItem> needs an explicit cast to become an
// AudioTrack *. clang converts it implicitly only when the playable item
// inherits every protocol the class adopts, and it does not inherit the holder.
@interface AudioTrack : NSObject <AudioTrackMetadataHolder>

@property (copy, readonly) NSURL *url;

// The tempo from the waveform decode pass; 0 means not yet analyzed or
// undetectable. Transient: the waveform cache re-delivers it on every load.
@property(atomic, assign) float detectedBPM;

// The metadata whose tags describe this row: nil for a windowed row, whose
// file's tags describe the whole image. One read, so a caller comparing tags
// against bpm and key sees one snapshot.
- (nullable AudioTrackMetadata *)rowTagMetadata;

// The tempo to act on: rowTagMetadata.bpm when tagged, else detectedBPM, else
// 0 — the single home of the tag-over-analysis precedence. Not pitch-adjusted:
// a caller wanting the tempo as heard scales it by the varispeed rate.
- (float)bpm;

// The musical key from the waveform decode pass; VibeMusicalKeyNone means not
// yet analyzed or undetectable. Transient like detectedBPM. Every init path
// must set it to VibeMusicalKeyNone: a zero-filled ivar reads as C major.
@property(atomic, assign) VibeMusicalKey detectedKey;

// The key to act on: rowTagMetadata.key when tagged, else detectedKey, else
// VibeMusicalKeyNone. Mirrors bpm.
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
// one file differ. An identity to compare, never a path to open. Fixed at
// init, so a per-tick comparison allocates nothing.
- (NSString *)sourceKey;

// The same over the standardized path, for a key that must survive a
// provider spelling the file's path another way — dedupe across opens, the
// remembered track. It reads the spelling alone (VibeComparablePath) and never
// stats. It allocates, unlike sourceKey. Keep it off a per-frame path.
- (nullable NSString *)standardizedSourceKey;

// `key` with this row's window appended (VibeKeyByAppendingCueWindow).
- (nullable NSString *)keyByAppendingWindowTo:(nullable NSString *)key;

// The one place rows are made from playlist entries, a fresh row each, and
// the one place rows become entries for the writer, with their duration and
// display names.
+ (NSArray<AudioTrack *> *)rowsForEntries:(NSArray<PlaylistEntry *> *)entries;
+ (NSArray<PlaylistEntry *> *)entriesForRows:(NSArray<AudioTrack *> *)rows;

// A fresh row for this one's audio at another URL — Convert's swap: the
// window, names, duration and analysis carry across. Minted rather than
// re-pointed, since the memoized cache key would file the new file's
// waveform and metadata under the old entries.
- (AudioTrack *)replacementAtURL:(NSURL *)url;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// The memoized NSURL+Hash key for the metadata and waveform caches — the
// file's, which a waveform entry extends with the window. nil when the file
// cannot be statted — not memoized, so a later call retries — and a caller
// must then skip caching. NSURL invalidateMemoizedCacheKeys retires the memo.
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
// cue row's own before its file's tags, and an untitled windowed row as
// "Track n" rather than its image's title — else the single line as the title
// and a nil artist, which means no second line rather than an empty one.
- (NSString *)displayTitle;
- (nullable NSString *)displayArtist;

@end

NS_ASSUME_NONNULL_END
