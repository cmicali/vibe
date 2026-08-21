//
//  PlaybackController+NowPlaying.h
//  Vibe (iOS)
//
//  The Now Playing publish and the remote-command routing: what the lock
//  screen, Control Center and the hardware transport controls see and send
//  back. The commands route to the same transport entry points the on-screen
//  controls use, so the lock screen and the screen cannot take different paths
//  to the same action.
//

#import "PlaybackController.h"
#import "NowPlayingController.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (NowPlaying) <NowPlayingControllerDelegate>

// Publishes the current track, position, duration and state. Called from
// notifyDidTick, so every event that moves one of them publishes with it.
- (void)publishNowPlaying;

@end

NS_ASSUME_NONNULL_END
