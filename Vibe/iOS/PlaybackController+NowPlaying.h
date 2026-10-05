//
//  PlaybackController+NowPlaying.h
//  Vibe (iOS)
//
//  The Now Playing publish and the remote commands, which route to the same
//  transport entry points the on-screen controls use.
//

#import "PlaybackController.h"
#import "NowPlayingController.h"

@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (NowPlaying) <NowPlayingControllerDelegate>

// Called from notifyDidTick. The widget's snapshot rides the same publish.
- (void)publishNowPlaying;

// The card's waveform delivery, reused for the widget's strip rather than a
// second decode. Dropped unless the track is current; the publisher matches
// it to the widget's track; the caller filters partial envelopes.
- (void)offerWaveformToWidget:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
