//
//  PlayerViewController+NowPlaying.m
//  Vibe (iOS)
//
//  See PlayerViewController+NowPlaying.h. The commands route to the same
//  transport entry points the on-screen controls use, so the lock screen and
//  the screen cannot take different paths to the same action.
//

#import "PlayerViewController+NowPlaying.h"
#import "PlayerViewControllerInternal.h"

#import "AudioPlayer.h"
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"

@implementation PlayerViewController (NowPlaying)

// The card's art is not dispatched here: the current page's art is the same
// decode, and the pager's art window (PlayerViewController+Pager) owns it and
// republishes the card when it lands. Until then cachedArt reads nil and the
// card falls back to the thumbnail, which is more than large enough for it.
- (void)publishNowPlaying {
    NowPlayingPlaybackState state = VibeNowPlayingStateForPlayer(_player.isPlaying,
                                                                 _player.isPaused);
    AudioTrack *track = [self displayedTrack];
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
    if (!_player.isPlaying) {
        [self playPauseTapped];
    }
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    // Through the funnel, not [_player playPause] directly: the guard puts it
    // on the same branch either way today, and this keeps it there when the
    // funnel grows.
    if (_player.isPlaying) {
        [self playPauseTapped];
    }
}

- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {
    [self playPauseTapped];
}

- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {
    [self nextTapped];
}

- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
    else {
        [_player seekToPosition:0];
    }
}

- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {
    [_player seekToPosition:position];
}

@end
