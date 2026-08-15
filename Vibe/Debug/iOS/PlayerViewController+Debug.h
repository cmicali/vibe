//
//  PlayerViewController+Debug.h
//  Vibe (iOS)
//
//  Extra surface for the debug command channel (Vibe/Debug/iOS/DebugCommands.m),
//  the iOS twin of Introspection/MainPlayerController+Debug.h. Declaration only,
//  implemented at the bottom of PlayerViewController.m for ivar access, and it
//  lives here so the shipping header carries no conditional about a tool that
//  does not ship. Debug builds only.
//

#if DEBUG

#import "PlayerViewController.h"
#import "DebugPlayerSurface.h"

@class AudioTrackMetadataCache;
@class AudioWaveformCache;

@interface PlayerViewController (Debug) <VibeDebugPlayerSurface>

- (NSDictionary *)debugStateDictionary;
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
