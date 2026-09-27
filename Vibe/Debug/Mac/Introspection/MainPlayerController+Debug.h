//
//  MainPlayerController+Debug.h
//  Vibe
//
//  Declaration-only: the debug accessors MainPlayerController.m implements.
//  The outlets and state the dumps read come from
//  MainPlayerControllerInternal.h, so nothing is re-declared here.
//

#if DEBUG

#import "MainPlayerController.h"
// For the convert_to_flac, undo and redo verbs.
#import "MainPlayerController+Convert.h"

@class ArtworkDisplayController;
@class PitchControlPanel;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Debug)

// Read through ArtworkDisplayController+Debug.h by the artwork ownership checks.
@property (strong, readonly) ArtworkDisplayController *debugArtworkController;

- (PitchControlPanel *)pitchPanel;
- (void)debugRefreshUI;
// The scaled UI tick rate the playhead is actually driven at, and the rate
// its live inputs ask for; check_consistency compares the two.
- (NSUInteger)debugUIUpdateHz;
- (NSUInteger)debugExpectedUIUpdateHz;
// The container mirror as read back from disk: {exists, rows, currentIndex}.
- (NSDictionary *)debugLastPlaylistDictionary;

@end

NS_ASSUME_NONNULL_END

#endif
