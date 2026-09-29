//
//  PlaybackController+PlayerEvents.m
//  Vibe (iOS)
//
//  Two rules govern this file. Every callback can be stale, so each handler
//  matches the delivered track against the playlist's current one first.
//  AudioPlayer.stop fires no callback, so nothing here advances off it;
//  track-end and skip-past-end both funnel through didFinishPlaying:.
//

#import "PlaybackController+PlayerEvents.h"
#import "PlaybackControllerInternal.h"
#import "PlaybackController+NowPlaying.h"

#import "AppSettings.h"
#import "AppStats.h"
#import "AudioErrorRules.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "CloudTransferRegistry.h"
#import "DownloadProgressMonitor.h"
#import "PlaybackDeliveryRules.h"
#import "UIUpdateTimer.h"

@implementation PlaybackController (PlayerEvents)

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeOutputAudioActive:(BOOL)outputAudioActive {
    // Actual output, not play intent, gates the equalizer and its FFT.
    [self notifyDidChangePlayState];
}

- (void)audioPlayerOutputDidBecomeIdle:(AudioPlayer *)audioPlayer {
    [_audioSession deactivateIfIdle];
}

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
     didBeginLoading:(AudioTrack *)track
openRequestIdentifier:(uint64_t)openRequestIdentifier {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    [self notifyDidBeginLoading];
    // The monitor is built here, not at play:, so a fast local play never
    // builds one it cancels moments later.
    if (!_downloadMonitor
            || _downloadMonitorOpenRequestIdentifier != openRequestIdentifier) {
        __weak PlaybackController *weakSelf = self;
        [CloudTransferRegistry.sharedRegistry beginExternalProgressForURL:track.url];
        _downloadMonitor = [DownloadProgressMonitor
                monitorReplacing:_downloadMonitor
                          forURL:track.url
                      currentURL:^NSURL *{
            PlaybackController *self = weakSelf;
            return self ? self->_playlist.currentTrack.url : nil;
        }                movement:^{
            PlaybackController *self = weakSelf;
            if (self) {
                [self->_player
                        noteOpenProgressForOpenRequestIdentifier:openRequestIdentifier];
            }
        }                handler:^(float fraction) {
            [weakSelf notifyDidUpdateLoadingProgress:fraction];
            [CloudTransferRegistry.sharedRegistry noteProgress:fraction
                                                        forURL:track.url];
        }];
        _downloadMonitorOpenRequestIdentifier = openRequestIdentifier;
    }
    [self publishNowPlaying];
}

// A pause toggled mid-open decides whether the load lands playing or parked.
// No audio has started, so only the glyph and the lock screen change.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeLoadingPaused:(BOOL)paused
                  forTrack:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    [self notifyDidChangePlayState];
    [self publishNowPlaying];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    _errorText = nil;
    _trackStartPending = NO;
    // Includes the parked seek that OPENED this file, which gets no
    // didFinishSeeking:.
    _seekInFlight = NO;
    [self teardownDownloadMonitor];
    // Before the repaint and the metadata kicks, so a quick second Next finds
    // the successor parked.
    [_player prefetchTrack:self.successorPrefetchTrack];
    [self notifyDidRenderCurrentTrack];
    // Clears the download fill only; the waveform decode may still be
    // streaming.
    [self notifyDidFinishLoading];
    // Retries a parse skipped while this open was materializing the file.
    [_metadataCache loadMetadataNow:track];
    [self startPendingMetadataLoad];
    _folderSession.persistedTrackPath = track.url.URLByStandardizingPath.path;
    // A parked landing releases the session as a pause does.
    BOOL playing = _player.isPlaying;
    _updateTimer.wanted = playing;
    if (!playing) {
        [_audioSession deactivateWhenIdle];
    }
    else {
        [[AppStats sharedInstance] playbackStarted];
    }
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    [[AppStats sharedInstance] playbackStopped];
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    // A resume from a re-park goes through playPause, never playCurrentTrack.
    _parked = NO;
    // A refused start parks Paused with an error; a resume proves it wrong.
    // Left set, the Error state hides the playing track from Now Playing and
    // the mini player.
    if (_errorText) {
        _errorText = nil;
        [self notifyDidRenderCurrentTrack];
    }
    [[AppStats sharedInstance] playbackStarted];
    _updateTimer.wanted = YES;
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    // Nil is the settle for a seek with nothing loaded, judged against the
    // PLAYER: an end-of-playlist park keeps a current row with no loaded track,
    // and dropping the settle strands _seekInFlight, which freezes the
    // scrubber's position sync.
    if ((track && ![_playlist isCurrentTrack:track])
            || (!track && !audioPlayer.isStopped)) {
        return;
    }
    _seekInFlight = NO;
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    // A replace plays without stopping first, so a natural end can land after
    // it; advancing then would skip the track just picked.
    if (track && ![_playlist isCurrentTrack:track]) {
        // Stop the stats run unless the replacement is already playing; an
        // emptied playlist (both sides nil) is not that case.
        AudioTrack *playlistTrack = _playlist.currentTrack;
        if (!playlistTrack || audioPlayer.currentTrack != playlistTrack) {
            [[AppStats sharedInstance] playbackStopped];
        }
        return;
    }
    [[AppStats sharedInstance] playbackStopped];
    // The second of On track end's two reads (root AGENTS.md): this one
    // decides from the playlist alone.
    if (VibePlaybackShouldAdvanceAtTrackEnd(_playlist.hasNextTrack,
                                            AppSettings.sharedInstance.pauseAtTrackEnd)
            && [_playlist next]) {
        [self playCurrentTrack];
        return;
    }
    _parked = YES;
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didAutoAdvanceFromTrack:(AudioTrack *)finishedTrack
                    toTrack:(AudioTrack *)startedTrack {
    // A gapless splice: audio never stopped, so this moves the cursor and
    // refreshes without play:.
    if (![_playlist isCurrentTrack:finishedTrack]) {
        return;
    }
    // A replace raced the boundary: the playlist owns "next", so treat it as
    // a plain track end and play the real successor.
    if (startedTrack != [_playlist trackAtIndex:_playlist.currentIndex + 1]) {
        [self audioPlayer:audioPlayer didFinishPlaying:finishedTrack];
        return;
    }
    [_playlist next];
    [self notifyDidMoveToCurrentTrackAnimated:YES];
    // The rest of the refresh is didStartPlaying:'s, whose guard now passes.
    [self audioPlayer:audioPlayer didStartPlaying:startedTrack];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]
            && error.code == VibeAudioErrorNotPlaying) {
        // A toggle raced a track end, or nothing is loaded: benign.
        return;
    }
    NSURL *url = error.userInfo[kVibeAudioErrorTrackURLKey];
    AudioTrack *current = _playlist.currentTrack;
    if (url && current && ![url isEqual:current.url]) {
        return;
    }
    _errorText = VibeStatusForPlayError(error);
    _seekInFlight = NO;
    _trackStartPending = NO;
    [self teardownDownloadMonitor];
    [self startPendingMetadataLoad];
    [self notifyDidFailCurrentTrack];
    if (current) {
        [self notifyDidRenderCurrentTrack];
    }
    [[AppStats sharedInstance] playbackStopped];
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    [self notifyDidChangePlayState];
    [self publishNowPlaying];
}

@end
