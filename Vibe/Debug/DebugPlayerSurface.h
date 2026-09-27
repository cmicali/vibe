//
//  DebugPlayerSurface.h
//  Vibe
//
//  What DebugCommonVerbs.m needs from the app: adopted by MainPlayerController
//  on macOS and RootViewController on iOS. Deliberately the smallest surface
//  that serves them; anything only one platform can answer belongs in that
//  platform's own table.
//

#if DEBUG

#import <Foundation/Foundation.h>

@class AudioPlayer;
@class AudioTrack;
@class AudioTrackMetadataCache;
@class AudioWaveformCache;

NS_ASSUME_NONNULL_BEGIN

@protocol VibeDebugPlayerSurface <NSObject>

// dump_state's whole reply; the keys are each platform's own.
- (NSDictionary *)debugStateDictionary;

// The reply every transport verb returns.
- (NSDictionary *)debugActionSummary;

- (void)debugPlayPause;
- (void)debugNext;
- (void)debugPrevious;
- (void)debugSeekToSeconds:(NSTimeInterval)seconds;

// Plays an arbitrary row, a load pattern next/previous cannot reach: on a
// cloud folder it lands where the sweep has not been, with neighbors nothing
// has prefetched. Out of range is a no-op.
- (void)debugPlayIndex:(NSUInteger)index;

// The platform's own open pipeline: the mac's expand-and-filter walk, the iOS
// folder session. Asynchronous, so the verb only acks; poll dump_state.
- (void)debugOpenPath:(NSString *)path;

// After set_pause_at_track_end writes the setting behind the pane's back,
// applies what the pane's writer would (the mac's EndOfTrack live effect, the
// iOS model's applyTrackTransitionSettings), so the parked successor is
// re-parked or dropped at once.
- (void)debugApplyEndOfTrackSetting;

// Appends instead of replacing, through each shell's Add: the mac's open
// funnel with appending:YES, the iOS folder session. Asynchronous.
- (void)debugAppendPath:(NSString *)path;

- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

// What DebugConsistency.m reads: facts rather than objects, since the mac's
// playlist lives behind PlaylistController and the iOS one is a bare Playlist.

- (AudioPlayer *)debugPlayer;

- (NSUInteger)debugPlaylistCount;
- (NSUInteger)debugPlaylistCurrentIndex;
- (nullable AudioTrack *)debugPlaylistCurrentTrack;
- (nullable AudioTrack *)debugPlaylistTrackAtIndex:(NSUInteger)index;

// The track the header shows: nil in the empty, error and launch-grace states,
// and not necessarily the playlist's current track.
- (nullable AudioTrack *)debugDisplayedTrack;

// Whether that track's open is in flight. Loading reports a zero position and
// duration by contract, so several checks stand down for it.
- (BOOL)debugIsLoading;

// The varispeed rate the app's labels and Now Playing divide file time by, for
// wall-clock comparisons.
- (double)debugPlaybackRate;

@optional

// This platform's own checks, appended after the shared ones. Returns how
// many ran, for the reply's "checked" count.
- (NSUInteger)debugCheckPlatform:(NSMutableArray<NSDictionary *> *)violations;

@end

NS_ASSUME_NONNULL_END

#endif
