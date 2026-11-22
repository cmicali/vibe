//
//  PlaybackController+NowPlaying.h
//  Vibe (iOS)
//
//  The Now Playing publish and the remote commands, which route to the same
//  transport entry points the on-screen controls use.
//

#import "PlaybackController.h"
#import "NowPlayingController.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (NowPlaying) <NowPlayingControllerDelegate>

// Called from notifyDidTick. The widget's snapshot rides the same publish.
- (void)publishNowPlaying;

@end

NS_ASSUME_NONNULL_END
