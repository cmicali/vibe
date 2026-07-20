//
//  MainPlayerController+NowPlaying.h
//  Vibe
//
//  The system Now Playing bridge — publishing track/timing/state to
//  NowPlayingController and routing its remote commands back to the transport
//  actions — split from the main implementation purely for file size, like
//  MainPlayerController+Menus.
//
//  NowPlayingControllerDelegate conformance is declared on this category (not
//  the class extension) so the compiler checks its implementation in this file.
//

#import "MainPlayerController.h"
#import "NowPlayingController.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

// Main-class surface the NowPlaying category reads — the accessor is
// synthesized by the class extension, the methods implemented in
// MainPlayerController.m. There is deliberately no @implementation for THIS
// category (same pattern as MainPlayerController+Debug.h), so the compiler
// doesn't look for these in the NowPlaying implementation below.
@interface MainPlayerController (NowPlayingSupport)

@property (strong, readonly) NowPlayingController *nowPlayingController;
- (nullable AudioTrack *)displayedTrack;
- (double)playbackRate;

@end

@interface MainPlayerController (NowPlaying) <NowPlayingControllerDelegate>

// Publish the current track + playback state to the system Now Playing UI.
// Called out of the updateUI funnel and on seek / pitch-range change /
// fader-gesture end; see the implementation for the full contract.
- (void)updateNowPlaying;

@end

NS_ASSUME_NONNULL_END
