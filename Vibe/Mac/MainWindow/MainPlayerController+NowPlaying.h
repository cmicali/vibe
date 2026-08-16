//
//  MainPlayerController+NowPlaying.h
//  Vibe
//
//  The system Now Playing bridge: it publishes the track, timing and state to
//  NowPlayingController and routes that controller's remote commands back to
//  the transport actions.
//

#import "MainPlayerController.h"
#import "NowPlayingController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (NowPlaying) <NowPlayingControllerDelegate>

// Publishes the current track and the playback state to the system Now Playing
// UI. It is called from the updateUI funnel, and on a seek, a pitch-range
// change and the end of a fader gesture. See the implementation for the full
// contract.
- (void)updateNowPlaying;

@end

NS_ASSUME_NONNULL_END
