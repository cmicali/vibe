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
#import "AudioFileOpenRules.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
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
    if (_loadingOpenRequestIdentifier != openRequestIdentifier) {
        _loadingURL = track.url;
        _loadingPath = VibeStandardizedAudioOpenPath(track.url);
        _loadingOpenRequestIdentifier = openRequestIdentifier;
        _loadingProgress = -1;
    }
    // The transfer may be well under way by the slow-open threshold.
    [self cloudTransferRegistryDidChange:CloudTransferRegistry.sharedRegistry];
    [self publishNowPlaying];
}

// A stream holding for its download stops Now Playing's clock
// (publishNowPlaying) and leaves the card's waveform alone: a slow open's
// begin-loading resets the scrubber, which wiped the drawn waveform and left
// nothing to scrub back into the downloaded part. Its end still asks again for
// a waveform the open skipped.
- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeBuffering:(BOOL)buffering
              forTrack:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    if (!buffering) {
        [self notifyDidFinishLoading];
    }
    [self notifyDidChangePlayState];
    [self publishNowPlaying];
}

// A stream opened on an estimated length counted it: the card's total and
// the lock screen's take the player's duration, which the tick, stopped while
// paused or backgrounded, would not otherwise republish.
- (void)audioPlayer:(AudioPlayer *)audioPlayer didSettleDurationOfTrack:(AudioTrack *)track {
    if ([_playlist isCurrentTrack:track]) {
        [self notifyDidTick];
    }
}

#pragma mark - CloudTransferRegistryObserver: the loading open's transfer

- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
    if (!_loadingURL || ![_playlist.currentTrack.url isEqual:_loadingURL]) {
        return;
    }
    float fraction = [registry progressForURL:_loadingURL];
    if (fraction > _loadingProgress) {
        _loadingProgress = fraction;
        [self notifyDidUpdateLoadingProgress:fraction];
    }
}

// By open identifier, so an older open's transfer cannot extend this one.
- (void)cloudTransferRegistry:(CloudTransferRegistry *)registry didMoveTransferForPath:(NSString *)path {
    if ([path isEqualToString:_loadingPath]) {
        [_player noteOpenProgressForOpenRequestIdentifier:_loadingOpenRequestIdentifier];
    }
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
    [self endLoadingProgress];
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
    _folderSession.persistedTrackKey = track.standardizedSourceKey;
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
    if (VibePlaybackShouldAdvanceAtTrackEnd(_playlist.trackEndSuccessor != nil,
                                            AppSettings.sharedInstance.pauseAtTrackEnd)
            && [_playlist advanceAtTrackEnd]) {
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
    // A replace or a mode change raced the boundary: the playlist owns what
    // follows, so treat it as a plain track end and play the real successor.
    if (![_playlist advanceFromTrack:finishedTrack toTrack:startedTrack]) {
        [self audioPlayer:audioPlayer didFinishPlaying:finishedTrack];
        // Parked, the player still sounds the refused successor: reload the
        // finished track paused over it, as the mac does.
        if (_parked) {
            [self openParkedTrack:finishedTrack atPosition:0];
            [self notifyDidChangePlayState];
            [self notifyDidTick];
        }
        return;
    }
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
    [self endLoadingProgress];
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
