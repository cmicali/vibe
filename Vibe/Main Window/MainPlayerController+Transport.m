//
//  MainPlayerController+Transport.m
//  Vibe
//

#import "MainPlayerController+Transport.h"
#import "AudioPlayer.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "PlaylistManager.h"

// Skip distances. When the track's tempo is known (tagged BPM wins over the
// analyzed one, same precedence as the BPM label) a skip moves by whole bars
// (4 beats) — a fixed span of *file* time, so the jump stays on the musical
// grid at any pitch. Without a tempo the fallback is the fixed wall-clock
// distance.
static const NSTimeInterval kSkipSeconds = 10.0;
static const NSTimeInterval kSkipMoreSeconds = 30.0;
static const NSTimeInterval kSkipMostSeconds = 60.0;
static const double kSkipBars = 8.0;
static const double kSkipMoreBars = 16.0;
static const double kSkipMostBars = 32.0;

@implementation MainPlayerController (Transport)

- (NSTimeInterval)skipFileSecondsForBars:(double)bars fallbackWallClockSeconds:(NSTimeInterval)wallSeconds {
    AudioTrack *track = self.playlistManager.currentTrack;
    float bpm = track.metadata.bpm > 0 ? track.metadata.bpm : track.detectedBPM;
    if (bpm > 0) {
        return bars * 4.0 * 60.0 / bpm;
    }
    // The fallback is expressed in the wall-clock seconds the user reads off
    // the time label; convert to file time (the player's units) with the same
    // varispeed rate the labels divide by, so a skip advances the displayed
    // clock by exactly the stated amount at any pitch.
    return wallSeconds * self.playbackRate;
}

- (IBAction)skipForward:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:kSkipBars fallbackWallClockSeconds:kSkipSeconds]];
}

- (IBAction)skipForwardMore:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:kSkipMoreBars fallbackWallClockSeconds:kSkipMoreSeconds]];
}

- (IBAction)skipForwardMost:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:kSkipMostBars fallbackWallClockSeconds:kSkipMostSeconds]];
}

- (IBAction)skipBack:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:kSkipBars fallbackWallClockSeconds:kSkipSeconds]];
}

- (IBAction)skipBackMore:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:kSkipMoreBars fallbackWallClockSeconds:kSkipMoreSeconds]];
}

- (IBAction)skipBackMost:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:kSkipMostBars fallbackWallClockSeconds:kSkipMostSeconds]];
}

- (void)skipByFileSeconds:(NSTimeInterval)fileDelta {
    // Stopped (end of playlist, post-error): the finished file stays open, so
    // duration alone looks seekable with no node left to seek. Menu validation
    // mirrors this; the guard here covers the bare keys, which bypass it.
    if (!self.playlistManager.currentTrack || self.audioPlayer.isStopped) {
        return;
    }
    NSTimeInterval duration = self.audioPlayer.duration;
    if (duration <= 0) {
        return; // Nothing seekable yet (loading, or no file open).
    }
    NSTimeInterval target = self.audioPlayer.position + fileDelta;
    if (target >= duration) {
        // Past the end: finish the track like a natural end — the delegate
        // (didFinishPlaying:) advances to the next track, or stops at the end
        // of the playlist.
        [self.audioPlayer finishCurrentTrack];
        return;
    }
    if (target < 0) {
        target = 0; // Skipping before the start seeks to the beginning.
    }
    [self.audioPlayer seekToPosition:target];
}

#pragma mark - Performance effects (bare-key holds; see TransportKeyMonitor)

- (IBAction)toggleLowKill:(nullable id)sender {
    self.audioPlayer.fx.lowKillEnabled = !self.audioPlayer.fx.lowKillEnabled;
}

- (void)setLowKillBoostActive:(BOOL)active {
    self.audioPlayer.fx.lowKillBoostActive = active;
}

- (void)setReverbSendActive:(BOOL)active {
    self.audioPlayer.fx.reverbSendEnabled = active;
}

- (void)setDelaySendActive:(BOOL)active {
    self.audioPlayer.fx.delaySendEnabled = active;
}

- (void)setShortDelaySendActive:(BOOL)active {
    self.audioPlayer.fx.shortDelaySendEnabled = active;
}

@end
