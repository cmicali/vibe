//
//  MainPlayerController+NowPlaying.h
//  Vibe
//
//  Publishes to NowPlayingController and routes its remote commands to the
//  transport actions.
//

#import "MainPlayerController.h"
#import "NowPlayingController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (NowPlaying) <NowPlayingControllerDelegate>

// Called from updateUI, and on a seek, a pitch-range change, a fader
// gesture's end and a buffering edge.
- (void)updateNowPlaying;

@end

NS_ASSUME_NONNULL_END
