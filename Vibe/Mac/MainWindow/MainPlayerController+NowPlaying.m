//
//  MainPlayerController+NowPlaying.m
//  Vibe
//

#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerControllerInternal.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"
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
    // One currentTrack snapshot for the whole publish: displayState below and
    // the displayed track must describe the same instant — the trap is spelled
    // out on displayedTrack — so both derive from this read.
    AudioTrack *currentTrack = self.playlistController.currentTrack;
    TrackDisplayState displayState = [self displayStateForTrack:currentTrack];
    // Withheld after a launch restore until the first real play: a parked
    // start publishes like any other, and nothing may be published until a
    // track plays. The call still runs so next/previous availability follows
    // the playlist — the controller applies it before its nil-track return.
    AudioTrack *track = _nowPlayingWithheldForRestore
            ? nil : [self displayedTrackForState:displayState track:currentTrack];
    NowPlayingPlaybackState state = VibeNowPlayingStateForPlayer(self.audioPlayer.isPlaying,
                                                                 self.audioPlayer.isPaused);
    // Report pitch-adjusted, wall-clock time, so that Control Center matches
    // the app's own time labels. Wall-clock elapsed time advances at real
    // time, so the rate handed to the system is 1.0, not the varispeed rate,
    // which would double-count against the already-scaled position.
    double rate = self.playbackRate;
    NSTimeInterval duration;
    NSTimeInterval position;
    BOOL loadingGap = (displayState == TrackDisplayStateLoading);
    if (loadingGap) {
        // The same gate the header renders --:-- under: during a track change
        // the player's live position and duration still describe the previous
        // file, or read 0, so publishing them would pair the new track's
        // identity with the old track's elapsed for as long as a slow open
        // runs. Publish the displayed track's own values — zero elapsed, and
        // its known duration (metadata, or a prior play) when it has one.
        // didStartPlaying:'s updateUI republishes the live times.
        duration = track.duration;
        // A convert swap replays the same audio at the old playhead, so its
        // gap carries the resume position rather than rewinding the scrubber
        // to 0 and snapping back at didStartPlaying:.
        position = (track && track == self.convertSwapResumeTrack)
                ? self.convertSwapResumePosition : 0;
    }
    else {
        duration = self.audioPlayer.duration;
        position = self.audioPlayer.position;
    }
    if (rate > 0) {
        duration /= rate;
        position /= rate;
    }
    // The MediaPlayer rate is how fast the published elapsed advances: 1.0
    // while playing, since wall-clock elapsed advances at real time — except
    // in the Loading gap, whose state maps to Playing while the published
    // position is a placeholder, so freeze the readout there until
    // didStartPlaying:'s republish flips it live.
    [self.nowPlayingController updateWithTrack:track
                                      position:position
                                      duration:duration
                                         state:state
                                          rate:loadingGap ? 0.0 : 1.0
                                       hasNext:self.playlistController.hasNextTrack
                                   hasPrevious:self.playlistController.hasPreviousTrack];
}

#pragma mark - NowPlayingControllerDelegate (system media keys / Control Center)

// NowPlayingController marshals commands to the main thread. A system Play or
// Pause is a destination state, unlike the on-screen toggle, so hand that
// verdict to the player's idempotent operations, which decide beside the
// mutable state on the player queue rather than from a main-thread snapshot.
//
// The one main-thread read left is isStopped, and only to pick which funnel
// owns the request: a stopped player has no loaded row to resume, so the
// playlist has to choose and load one. It is safe stale in both directions —
// resume no-ops on a player that has since stopped, and PlaylistController.play
// replays the current row on one that has since started.

- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    if (self.audioPlayer.isStopped) {
        [self.playlistController play];
    }
    else {
        [self.audioPlayer resume];
    }
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    [self.audioPlayer pause];
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
