//
//  MainPlayerController+Debug.h
//  Vibe
//
//  Extra surface for the debug command channel (Debug/DebugUtil.m) — internal
//  outlets re-declared so the state dump can read them. The accessors are the
//  ones synthesized by the class extension in MainPlayerController.m; there is
//  deliberately no @implementation for this category. Debug builds only.
//

#if DEBUG

#import "MainPlayerController.h"

@class SymbolButton;
@class PitchControlPanel;
@class TrackDisplayController;
@class MainPlayerContentView;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Debug)

@property (weak, readonly) SymbolButton *nextButton;
@property (weak, readonly) SymbolButton *playButton;
// The header labels the state dump reads live behind this
// (TrackDisplayController exposes them readonly).
@property (strong, readonly) TrackDisplayController *trackDisplay;
// The synthetic drag verbs (drag_hover/drag_drop/drag_end) reach the playlist
// drop zone through this.
@property (weak, readonly) MainPlayerContentView *playerContentView;

- (PitchControlPanel *)pitchPanel;
- (void)debugRefreshUI;

@end

NS_ASSUME_NONNULL_END

#endif
