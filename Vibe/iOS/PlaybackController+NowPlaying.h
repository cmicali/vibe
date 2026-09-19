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

@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (NowPlaying) <NowPlayingControllerDelegate>

// Publishes the current track, position, duration and state. Called from
// notifyDidTick, so every event that moves one of them publishes with it.
// The home-screen widget's snapshot rides this: same concern, one trigger.
- (void)publishNowPlaying;

// The card's waveform delivery, offered for the widget's strip. The card owns
// the app's one waveform load, so re-reading the file model-side would be a
// second decode of it; whether the delivery is for the track the widget is
// describing is the model's call, not the view's. Partial envelopes are the
// caller's to filter — it already knows.
- (void)offerWaveformToWidget:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
