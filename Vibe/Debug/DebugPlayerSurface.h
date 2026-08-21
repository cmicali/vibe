//
//  DebugPlayerSurface.h
//  Vibe
//
//  What the debug channel's cross-platform verbs need from whichever object is
//  "the app's player" — MainPlayerController on macOS, PlayerViewController on
//  iOS. It exists so those verbs are written once (DebugCommonVerbs.m) instead
//  of once per platform, and it is deliberately the SMALLEST surface that
//  serves them: anything only one platform can answer belongs in that
//  platform's own table, not here.
//
//  Debug builds only, like everything in this directory.
//

#if DEBUG

#import <Foundation/Foundation.h>

@class AudioPlayer;
@class AudioTrack;
@class AudioTrackMetadataCache;
@class AudioWaveformCache;

NS_ASSUME_NONNULL_BEGIN

@protocol VibeDebugPlayerSurface <NSObject>

// dump_state's whole reply. Each platform reports what it has; nothing here
// prescribes the keys, because the two screens genuinely differ.
- (NSDictionary *)debugStateDictionary;

// The compact reply every transport verb returns, so play_pause, next,
// previous and seek all answer in one shape.
- (NSDictionary *)debugActionSummary;

- (void)debugPlayPause;
- (void)debugNext;
- (void)debugPrevious;
- (void)debugSeekToSeconds:(NSTimeInterval)seconds;

// Play an arbitrary row, which next/previous cannot reach: a listener picking
// track 56 out of a folder is a different load pattern from walking to it, and
// on a cloud folder it is THE pattern — it lands somewhere the background sweep
// has not been, with neighbors nothing has prefetched. Out-of-range is a no-op,
// like every other transport verb on an empty playlist.
- (void)debugPlayIndex:(NSUInteger)index;

// The platform's own open pipeline — the mac's expand-and-filter walk, the
// iOS folder session — behind one name. Asynchronous on both, so the verb
// only acks; poll dump_state for the resulting playlist.
- (void)debugOpenPath:(NSString *)path;

// clear_caches empties both of these; file_cache and file_clear_cache drive
// the waveform one per file.
- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

// ---- What the shared consistency checks read (DebugConsistency.m).
//
// Facts rather than objects, deliberately: the mac's playlist lives behind
// PlaylistController and the iOS one is a bare Playlist, and neither needs to
// leak out for a check to ask how many tracks there are.

- (AudioPlayer *)debugPlayer;

- (NSUInteger)debugPlaylistCount;
- (NSUInteger)debugPlaylistCurrentIndex;
- (nullable AudioTrack *)debugPlaylistCurrentTrack;
- (nullable AudioTrack *)debugPlaylistTrackAtIndex:(NSUInteger)index;

// The track the header is showing, which is nil in the empty, error and
// launch-grace states — not necessarily the playlist's current track.
- (nullable AudioTrack *)debugDisplayedTrack;

// Whether that track's open is still in flight. Loading reports position and
// duration of zero by contract, so several checks stand down for it.
- (BOOL)debugIsLoading;

// The varispeed rate the app's own labels and the Now Playing publish divide
// file time by, so a wall-clock comparison can be made against them.
- (double)debugPlaybackRate;

@optional

// Checks that hold on this platform alone, appended after the shared ones.
// Returns how many it ran, so the reply's "checked" count stays honest.
- (NSUInteger)debugCheckPlatform:(NSMutableArray<NSDictionary *> *)violations;

@end

NS_ASSUME_NONNULL_END

#endif
