//
//  MainPlayerController+NowPlaying.m
//  Vibe
//

#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerControllerInternal.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"
#import "PlaylistController.h"

@implementation MainPlayerController (NowPlaying)

// A fader drag publishes once, at the gesture's end.
- (void)updateNowPlaying {
    // The displayed track, so a play error clears the slot. One currentTrack
    // read (displayedTrack's trap).
    AudioTrack *currentTrack = self.playlistController.currentTrack;
    TrackDisplayState displayState = [self displayStateForTrack:currentTrack];
    AudioTrack *track = [self displayedTrackForState:displayState track:currentTrack];
    NowPlayingPlaybackState state = VibeNowPlayingStateForPlayer(self.audioPlayer.isPlaying,
                                                                 self.audioPlayer.isPaused);
    // Wall-clock time, matching the labels; the system rate is 1.0, since the
    // position is already scaled.
    double rate = self.playbackRate;
    NSTimeInterval duration;
    NSTimeInterval position;
    BOOL loadingGap = (displayState == TrackDisplayStateLoading);
    if (loadingGap) {
        // The player's times still describe the previous file, or read 0.
        duration = track.duration;
        // A convert swap resumes at the old playhead; no snap to 0 and back.
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
    // Frozen in the Loading gap, which maps to Playing over a placeholder.
    [self.nowPlayingController updateWithTrack:track
                                placeholderArt:[AppSettings.sharedInstance.currentTheme
                                                       defaultArtworkImageForAppearance:self.window.effectiveAppearance]
                                      position:position
                                      duration:duration
                                         state:state
                                          rate:loadingGap ? 0.0 : 1.0
                                       hasNext:self.playlistController.hasNextTrack
                                   hasPrevious:self.playlistController.hasPreviousTrack];
}

#pragma mark - NowPlayingControllerDelegate (system media keys / Control Center)

// A system Play or Pause is a destination state, so it goes to the player's
// idempotent operations, decided on the player queue. isStopped only picks
// the funnel and is safe stale either way: resume no-ops on a stopped player,
// and PlaylistController.play replays the current row on a started one.

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
    // Wall-clock back to file time.
    [self.audioPlayer seekToPosition:position * self.playbackRate];
}

@end
