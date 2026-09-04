//
//  MainPlayerController+Debug.h
//  Vibe
//
//  Extra surface for the debug command channel: the debug-only accessors
//  MainPlayerController.m implements for it. The outlets and state the dumps
//  read are MainPlayerControllerInternal.h's, which the channel imports beside
//  this, so nothing is re-declared here. There is deliberately no
//  @implementation for this category — the VibeDebugPlayerSurface conformance
//  is a separate one, in MainPlayerController+DebugPlayerSurface. Debug builds
//  only.
//

#if DEBUG

#import "MainPlayerController.h"
// For the convert_to_flac, undo and redo verbs.
#import "MainPlayerController+Convert.h"

@class ArtworkDisplayController;
@class PitchControlPanel;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Debug)

// The artwork ownership oracle reads the renderer's exact target, installed
// owner, default and pending state through its own Debug declaration header.
@property (strong, readonly) ArtworkDisplayController *debugArtworkController;

- (PitchControlPanel *)pitchPanel;
- (void)debugRefreshUI;
// The dynamically scaled playback-UI tick rate, for the state dump: the only
// way to see what the playhead is actually being driven at. The expected one
// re-derives it from the live inputs, which check_consistency pairs with it.
- (NSUInteger)debugUIUpdateHz;
- (NSUInteger)debugExpectedUIUpdateHz;
// The container mirror as read back from disk: {exists, rows, currentIndex}.
- (NSDictionary *)debugLastPlaylistDictionary;

@end

NS_ASSUME_NONNULL_END

#endif
