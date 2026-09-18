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

// The card's waveform delivery, offered to the widget. The card owns the one
// load (PageWaveformCoordinator) and this is the model half deciding what to
// do with it, as the card already does for publishNowPlaying: a delivery for
// anything but the displayed track is dropped, and a partial one is ignored —
// the widget shows a whole envelope or none.
- (void)publishWidgetWaveform:(CodableAudioWaveform *)waveform
                     forTrack:(AudioTrack *)track
                     complete:(BOOL)complete;

@end

NS_ASSUME_NONNULL_END
