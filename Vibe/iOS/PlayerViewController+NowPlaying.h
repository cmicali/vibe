//
//  PlayerViewController+NowPlaying.h
//  Vibe (iOS)
//
//  The Now Playing publish and the remote-command routing: what the lock
//  screen, Control Center and the hardware transport controls see and send
//  back. The commands route to the same transport entry points the on-screen
//  controls use.
//

#import "PlayerViewController.h"
#import "NowPlayingController.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlayerViewController (NowPlaying) <NowPlayingControllerDelegate>

// Publishes the current track, position, duration and state. Called from the
// update funnel and from every player event that moves one of them.
- (void)publishNowPlaying;

@end

NS_ASSUME_NONNULL_END
