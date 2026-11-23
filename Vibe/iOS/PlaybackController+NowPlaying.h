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

// The widget's waveform settings, pushed into its publisher at launch and on
// every display-settings change, because the publisher reads no setting.
- (void)pushWidgetWaveformSettings;

@end

NS_ASSUME_NONNULL_END
