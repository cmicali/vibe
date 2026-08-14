//
//  MainPlayerController+Debug.h
//  Vibe
//
//  Extra surface for the debug command channel in Debug/DebugUtil.m: internal
//  outlets re-declared so that the state dump can read them. The accessors are
//  the ones the class extension in MainPlayerController.m synthesizes, and
//  there is deliberately no @implementation for this category. Debug builds
//  only.
//

#if DEBUG

#import "MainPlayerController.h"
// For the convert_to_flac, undo and redo verbs.
#import "MainPlayerController+Convert.h"

@class SymbolButton;
@class PitchControlPanel;
@class TrackDisplayController;
@class MainPlayerContentView;
@class PlaylistTableView;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Debug)

@property (weak, readonly) SymbolButton *nextButton;
@property (weak, readonly) SymbolButton *playButton;
// The header labels the state dump reads live behind this;
// TrackDisplayController exposes them readonly.
@property (strong, readonly) TrackDisplayController *trackDisplay;
// The synthetic drag verbs — drag_hover, drag_drop and drag_end — reach the
// playlist drop zone through this.
@property (weak, readonly) MainPlayerContentView *playerContentView;
// check_invariants compares the table's row count against the playlist's,
// which is the only way to catch a reloadData the model never got.
@property (weak, readonly) PlaylistTableView *playlistTableView;

- (PitchControlPanel *)pitchPanel;
- (void)debugRefreshUI;
// The dynamically scaled playback-UI tick rate, for the state dump: the only
// way to see what the playhead is actually being driven at. The expected one
// re-derives it from the live inputs, which check_invariants pairs with it.
- (NSUInteger)debugUIUpdateHz;
- (NSUInteger)debugExpectedUIUpdateHz;

@end

NS_ASSUME_NONNULL_END

#endif
