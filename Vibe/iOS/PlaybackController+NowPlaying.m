//
//  PlaybackController+NowPlaying.m
//  Vibe (iOS)
//
//  See PlaybackController+NowPlaying.h.
//

#import "PlaybackController+NowPlaying.h"
#import "PlaybackControllerInternal.h"

#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"
#import "WidgetPublisher.h"

@implementation PlaybackController (NowPlaying)

- (void)offerWaveformToWidget:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track {
    [_widgetPublisher offerWaveform:waveform forTrack:track];
}

// The card's art is not dispatched here: the current page's art is the same
// decode, and the pager's art window (PlayerViewController+Pager) owns it and
// republishes the card when it lands. Until then cachedArt reads nil and the
// card falls back to the thumbnail, which is more than large enough for it.
- (void)publishNowPlaying {
    // Each player read is a lock round-trip, so each is taken once and both
    // surfaces are told the same facts from the same locals: two surfaces
    // describing one playback must never be able to disagree.
    BOOL playing = _player.isPlaying;
    NowPlayingPlaybackState state = VibeNowPlayingStateForPlayer(playing, _player.isPaused);
    AudioTrack *track = self.displayedTrack;
    NSTimeInterval position = _trackStartPending ? 0 : _player.position;
    // The player's duration is 0 while pending or parked-unopened; the
    // track's metadata duration keeps the card's timeline real there.
    NSTimeInterval playerDuration = _player.duration;
    NSTimeInterval duration = playerDuration > 0 ? playerDuration : track.duration;
    // The pager's no-artwork image, so the card and the page agree.
    [_nowPlaying updateWithTrack:track
                  placeholderArt:[UIImage imageNamed:@"record-bg"]
                        position:position
                        duration:duration
                           state:state
                            rate:1.0
                         hasNext:_playlist.hasNextTrack
                     hasPrevious:_playlist.hasPreviousTrack];
    [_widgetPublisher updateWithTrack:track
                             position:position
                             duration:duration
                              playing:playing
                         startPending:_trackStartPending];
}

#pragma mark - NowPlayingControllerDelegate

// Play and Pause from the lock screen, Control Center or a car head unit name
// destination states, unlike the on-screen toggle, so they go to the player's
// idempotent operations, which decide beside the mutable state on the player
// queue rather than from a main-thread snapshot. Two Pause commands in quick
// succession therefore both mean paused, where a toggle would have cancelled
// itself. Same rule as the mac's MainPlayerController+NowPlaying.
//
// The one main-thread read left is isStopped, and only to pick which funnel
// owns the request: a stopped player has no loaded row to resume, so the
// playlist has to choose and load one. Safe stale in both directions — resume
// no-ops on a player that has since stopped, and playCurrentTrack replays the
// current row on one that has since started.
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    if (_player.isStopped) {
        [self playCurrentTrack]; // activates the session itself
        return;
    }
    // Loading is not the exception it looks like: it is a parked landing (a
    // pause verdict mid-load, or the media-reset re-park), and resume flips
    // that landing to playing without a fresh play: that would restart the
    // open and lose the re-park's captured position. Same verdict playPause
    // reaches for the same state.
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

@end
