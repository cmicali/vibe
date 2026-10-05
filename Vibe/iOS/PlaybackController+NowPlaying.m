//
//  PlaybackController+NowPlaying.m
//  Vibe (iOS)
//

#import "PlaybackController+NowPlaying.h"
#import "PlaybackControllerInternal.h"

#import "AppSettings.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"
#import "WidgetPublisher.h"

// Held once: the publisher's dirty check compares artwork by identity, and
// imageNamed: is an asset-catalog lookup on every tick otherwise.
static UIImage *VibeNowPlayingPlaceholderArt(void) {
    static UIImage *placeholder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        placeholder = [UIImage imageNamed:@"record-bg"];
    });
    return placeholder;
}

@implementation PlaybackController (NowPlaying)

- (void)offerWaveformToWidget:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track {
    // A neighbor page's preview would replace the current track's offer
    // before the widget publishes that track.
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    [_widgetPublisher offerWaveform:waveform forTrack:track];
}

// No art dispatch here: the pager's art window owns that decode and
// republishes when it lands; until then the lock screen shows the thumbnail.
- (void)publishNowPlaying {
    // Each player read is taken once, so the two surfaces cannot disagree.
    BOOL playing = _player.isPlaying;
    NowPlayingPlaybackState state = VibeNowPlayingStateForPlayer(playing, _player.isPaused);
    AudioTrack *track = self.displayedTrack;
    NSTimeInterval position = _trackStartPending ? 0 : _player.position;
    // The player's duration is 0 while pending or parked.
    NSTimeInterval playerDuration = _player.duration;
    NSTimeInterval duration = playerDuration > 0 ? playerDuration : track.duration;
    // A buffering hold is Playing at rate 0, so the lock screen's clock holds
    // with the audio.
    [_nowPlaying updateWithTrack:track
                  placeholderArt:VibeNowPlayingPlaceholderArt()
                        position:position
                        duration:duration
                           state:state
                            rate:_player.isBuffering ? 0.0 : 1.0
                         hasNext:_playlist.hasNextTrack
                     hasPrevious:_playlist.hasPreviousTrack];
    [_widgetPublisher updateWithTrack:track
                             position:position
                             duration:duration
                              playing:playing
                         startPending:_trackStartPending];
}

#pragma mark - NowPlayingControllerDelegate

// Remote Play and Pause name destination states, so they go to the player's
// idempotent operations: two quick Pauses both mean paused, where a toggle
// would cancel itself. isStopped only picks the funnel, and is safe stale
// either way — resume no-ops on a stopped player, and playCurrentTrack replays
// the current row.
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    if (_player.isStopped) {
        [self playCurrentTrack];
        return;
    }
    // Loading is a parked landing: resume flips it to playing, where a fresh
    // play: would restart the open and lose the re-park's position.
    [_audioSession activate];
    [_player resume];
    [_player recoverOutput];
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    [_player pause];
}

- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {
    [self playPause];
}

- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {
    [self next];
}

- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {
    [self previous];
}

- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {
    [self seekToPosition:position];
}

- (void)nowPlayingController:(NowPlayingController *)controller setShuffleEnabled:(BOOL)enabled {
    AppSettings.sharedInstance.shuffleEnabled = enabled;
    [self applyTrackTransitionSettings];
}

- (void)nowPlayingController:(NowPlayingController *)controller setRepeatMode:(VibeRepeatMode)mode {
    AppSettings.sharedInstance.repeatMode = mode;
    [self applyTrackTransitionSettings];
}

@end
