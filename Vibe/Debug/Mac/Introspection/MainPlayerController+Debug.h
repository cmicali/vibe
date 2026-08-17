//
//  MainPlayerController+Debug.h
//  Vibe
//
//  Extra surface for the debug command channel in Debug/DebugUtil.m: internal
//  outlets re-declared so that the state dump can read them. The accessors are
//  the ones the class extension in MainPlayerController.m synthesizes, and
//  there is deliberately no @implementation for this category — the
//  VibeDebugPlayerSurface conformance is a separate one, in
//  MainPlayerController+DebugPlayerSurface. Debug builds only.
//

#if DEBUG

#import "MainPlayerController.h"
// For the convert_to_flac, undo and redo verbs.
#import "MainPlayerController+Convert.h"
// TrackDisplayState, which displayState below returns.
#import "TrackDisplayController.h"

@class AudioTrack;
@class SymbolButton;
@class PitchControlPanel;
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
// check_consistency compares the table's row count against the playlist's,
// which is the only way to catch a reloadData the model never got.
@property (weak, readonly) PlaylistTableView *playlistTableView;

// The header's resolved state, and the track it describes — nil while the
// empty or error state is up. dump_state reports both, and check_consistency
// pairs them against the player and the playlist. Implemented in
// MainPlayerController.m, where the resolution lives.
- (TrackDisplayState)displayState;
- (nullable AudioTrack *)displayedTrack;

- (PitchControlPanel *)pitchPanel;
- (void)debugRefreshUI;
// The dynamically scaled playback-UI tick rate, for the state dump: the only
// way to see what the playhead is actually being driven at. The expected one
// re-derives it from the live inputs, which check_consistency pairs with it.
- (NSUInteger)debugUIUpdateHz;
- (NSUInteger)debugExpectedUIUpdateHz;

// Fired on the main thread when an undo or redo of a conversion settles,
// success or failure; cleared before it runs, so a handler a timed-out debug
// command left behind cannot fire on a later menu undo. DebugUtil's undo/redo
// verbs are the only setter; synthesized in MainPlayerController.m.
@property (copy, nullable) void (^conversionUndoRedoSettledHandler)(void);

@end

NS_ASSUME_NONNULL_END

#endif
