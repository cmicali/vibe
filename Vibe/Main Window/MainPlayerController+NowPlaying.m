//
//  MainPlayerController+NowPlaying.m
//  Vibe
//

#import "MainPlayerController+NowPlaying.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "PlaylistController.h"

@implementation MainPlayerController (NowPlaying)

// Publish the current track + playback state to the system Now Playing UI
// (Control Center, media keys). Driven off updateUI, plus seek, pitch-range
// change, and fader-gesture end — the things that move position/rate without
// an updateUI (a fader drag deliberately publishes once, at gesture end).
// Cheap and non-blocking.
- (void)updateNowPlaying {
    // displayedTrack, not currentTrack: the system sees the header's masked
    // view, so a play-error state clears the Now Playing slot instead of
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
    // Report pitch-adjusted (wall-clock) time so Control Center matches the
    // app's own time labels. Wall-clock elapsed advances at real time, so the
    // rate handed to the system is 1.0 — NOT the varispeed rate, which would
    // double-count against the already-scaled position.
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

// Commands arrive on the main thread; route them through the same transport
// entry points the on-screen buttons and keyboard use.

- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    // Discrete "play" — start/resume only if not already playing (playPause:
    // would otherwise pause a playing track).
    if (!self.audioPlayer.isPlaying) {
        [self playPause:nil];
    }
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    // Discrete "pause" — act only when something is actually playing.
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
    // publishes; the player seeks in file time — convert back with the same
    // rate.
    [self.audioPlayer seekToPosition:position * self.playbackRate];
}

@end
