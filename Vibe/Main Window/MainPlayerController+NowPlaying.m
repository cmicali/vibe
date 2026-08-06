//
//  MainPlayerController+NowPlaying.m
//  Vibe
//

#import "MainPlayerController+NowPlaying.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "PlaylistController.h"

@implementation MainPlayerController (NowPlaying)

// Publishes the current track and the playback state to the system Now Playing
// UI: Control Center and the media keys. It is driven off updateUI, plus a
// seek, a pitch-range change and the end of a fader gesture — the things that
// move position or rate without an updateUI. A fader drag deliberately
// publishes once, at the end of the gesture. This is cheap and non-blocking.
- (void)updateNowPlaying {
    // displayedTrack, not currentTrack. The system sees the header's masked
    // view, so a play-error state clears the Now Playing slot rather than
    // advertising a track that never produced audio.
    AudioTrack *track = [self displayedTrack];
    NowPlayingPlaybackState state;
    if (self.audioPlayer.isPaused) {
        state = NowPlayingPlaybackStatePaused;
    }
    else if (self.audioPlayer.isPlaying) { // Playing or Loading
        state = NowPlayingPlaybackStatePlaying;
    }
    else {
        state = NowPlayingPlaybackStateStopped;
    }
    // Report pitch-adjusted, wall-clock time, so that Control Center matches
    // the app's own time labels. Wall-clock elapsed time advances at real
    // time, so the rate handed to the system is 1.0, not the varispeed rate,
    // which would double-count against the already-scaled position.
    double rate = self.playbackRate;
    NSTimeInterval duration = self.audioPlayer.duration;
    NSTimeInterval position = self.audioPlayer.position;
    if (rate > 0) {
        duration /= rate;
        position /= rate;
    }
    [self.nowPlayingController updateWithTrack:track
                                      position:position
                                      duration:duration
                                         state:state
                                          rate:1.0
                                       hasNext:self.playlistController.hasNextTrack
                                   hasPrevious:self.playlistController.hasPreviousTrack];
}

#pragma mark - NowPlayingControllerDelegate (system media keys / Control Center)

// Commands arrive on the main thread. Route them through the same transport
// entry points the on-screen buttons and the keyboard use.

- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    // A discrete play: start or resume only if not already playing, since
    // playPause: would otherwise pause a playing track.
    if (!self.audioPlayer.isPlaying) {
        [self playPause:nil];
    }
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    // A discrete pause: act only when something is actually playing.
    if (self.audioPlayer.isPlaying) {
        [self playPause:nil];
    }
}

- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {
    [self playPause:nil];
}

- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {
    [self next:nil];
}

- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {
    [self previous:nil];
}

- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {
    // The scrubber position arrives in the wall-clock time updateNowPlaying
    // publishes, while the player seeks in file time, so convert back with the
    // same rate.
    [self.audioPlayer seekToPosition:position * self.playbackRate];
}

@end
