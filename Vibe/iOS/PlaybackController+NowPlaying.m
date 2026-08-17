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
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"

@implementation PlaybackController (NowPlaying)

// The card's art is not dispatched here: the current page's art is the same
// decode, and the pager's art window (PlayerViewController+Pager) owns it and
// republishes the card when it lands. Until then cachedArt reads nil and the
// card falls back to the thumbnail, which is more than large enough for it.
- (void)publishNowPlaying {
    NowPlayingPlaybackState state = VibeNowPlayingStateForPlayer(_player.isPlaying,
                                                                 _player.isPaused);
    AudioTrack *track = self.displayedTrack;
    // The player's duration is 0 while pending or parked-unopened; the
    // track's metadata duration keeps the card's timeline real there.
    NSTimeInterval playerDuration = _player.duration;
    [_nowPlaying updateWithTrack:track
                        position:(_trackStartPending ? 0 : _player.position)
                        duration:(playerDuration > 0 ? playerDuration : track.duration)
                           state:state
                            rate:1.0
                         hasNext:_playlist.hasNextTrack
                     hasPrevious:_playlist.hasPreviousTrack];
}

#pragma mark - NowPlayingControllerDelegate

- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    if (_player.isStopped) {
        [self playCurrentTrack];
        return;
    }
    [_audioSession activate];
    [_player resume];
    [_player recoverFromEngineConfigurationChange];
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
