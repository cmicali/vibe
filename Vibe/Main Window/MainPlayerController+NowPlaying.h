//
//  MainPlayerController+NowPlaying.h
//  Vibe
//
//  The system Now Playing bridge: it publishes the track, timing and state to
//  NowPlayingController and routes that controller's remote commands back to
//  the transport actions. It was split from the main implementation purely for
//  file size, as MainPlayerController+Menus was.
//
//  The NowPlayingControllerDelegate conformance is declared on this category
//  rather than the class extension, so that the compiler checks its
//  implementation in this file.
//

#import "MainPlayerController.h"
#import "NowPlayingController.h"
#import "TrackDisplayController.h" // TrackDisplayState

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

// The main-class surface the NowPlaying category reads. The class extension
// synthesizes the accessor, and MainPlayerController.m implements the methods.
// There is deliberately no @implementation for this category, the same pattern
// as MainPlayerController+Debug.h, so that the compiler does not look for
// these in the NowPlaying implementation below.
@interface MainPlayerController (NowPlayingSupport)

@property (strong, readonly) NowPlayingController *nowPlayingController;
// The convert swap's resume hint; see the class extension in
// MainPlayerController.m. Read gated on the track identity, because a track
// change can race the swap's replay.
@property (weak, readonly) AudioTrack *convertSwapResumeTrack;
@property (readonly) NSTimeInterval convertSwapResumePosition;
- (TrackDisplayState)displayState;
- (nullable AudioTrack *)displayedTrack;

@end

@interface MainPlayerController (NowPlaying) <NowPlayingControllerDelegate>

// Publishes the current track and the playback state to the system Now Playing
// UI. It is called from the updateUI funnel, and on a seek, a pitch-range
// change and the end of a fader gesture. See the implementation for the full
// contract.
- (void)updateNowPlaying;

@end

NS_ASSUME_NONNULL_END
