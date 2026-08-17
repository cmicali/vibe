//
//  RootViewController+Debug.h
//  Vibe (iOS)
//
//  Extra surface for the debug command channel (Vibe/Debug/iOS/DebugCommands.m),
//  the iOS twin of Introspection/MainPlayerController+Debug.h. The shell is
//  what adopts VibeDebugPlayerSurface, because it is the one object that can
//  see the whole app: it forwards the player and playlist reads to its
//  PlaybackController and the pager reads to its card.
//
//  It lives here, with its implementation beside it, so the shipping header
//  carries no conditional about a tool that does not ship. Debug builds only.
//

#if DEBUG

#import "RootViewController.h"
#import "DebugPlayerSurface.h"

@class AudioTrackMetadataCache;
@class AudioWaveformCache;

@interface RootViewController (Debug) <VibeDebugPlayerSurface>

- (NSDictionary *)debugStateDictionary;
// The pager's art window and each page's art state. Nothing on screen tells
// "not decoded yet" from "no art at all" — both are the placeholder — so this
// is the only way to see whether the prefetch is keeping up.
- (NSDictionary *)debugArtDictionary;
// The compact reply the transport verbs share.
- (NSDictionary *)debugActionSummary;
- (void)debugPlayPause;
- (void)debugNext;
- (void)debugPlayIndex:(NSUInteger)index;
- (void)debugPrevious;
// Routes through the scrubber's didSeek path so the seek-in-flight guard
// behaves exactly as a real drag's release.
- (void)debugSeekToSeconds:(NSTimeInterval)seconds;
- (void)debugOpenPath:(NSString *)path;
- (AudioTrackMetadataCache *)debugMetadataCache;
- (AudioWaveformCache *)debugWaveformCache;

@end

#endif
