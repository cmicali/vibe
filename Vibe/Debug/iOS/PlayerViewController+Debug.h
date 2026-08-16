//
//  PlayerViewController+Debug.h
//  Vibe (iOS)
//
//  Extra surface for the debug command channel (Vibe/Debug/iOS/DebugCommands.m),
//  the iOS twin of Introspection/MainPlayerController+Debug.h. It lives here,
//  with its implementation beside it, so the shipping header carries no
//  conditional about a tool that does not ship; the implementation reaches the
//  screen's state through PlayerViewControllerInternal.h. Debug builds only.
//

#if DEBUG

#import "PlayerViewController.h"
#import "DebugPlayerSurface.h"

@class AudioTrackMetadataCache;
@class AudioWaveformCache;

@interface PlayerViewController (Debug) <VibeDebugPlayerSurface>

- (NSDictionary *)debugStateDictionary;
// The pager's art window and each page's art state. Nothing on screen tells
// "not decoded yet" from "no art at all" — both are the placeholder — so this
// is the only way to see whether the prefetch is keeping up.
- (NSDictionary *)debugArtDictionary;
// The compact reply the transport verbs share.
- (NSDictionary *)debugActionSummary;
- (void)debugPlayPause;
- (void)debugNext;
- (void)debugPrevious;
// Routes through the scrubber's didSeek path so the seek-in-flight guard
// behaves exactly as a real drag's release.
- (void)debugSeekToSeconds:(NSTimeInterval)seconds;
- (void)debugOpenPath:(NSString *)path;
- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

@end

#endif
