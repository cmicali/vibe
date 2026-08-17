//
//  PlaybackController+PlayerEvents.m
//  Vibe (iOS)
//
//  Two rules govern this whole file.
//
//  EVERY CALLBACK CAN BE STALE. A delivery can land after the playlist has
//  moved on — an external open replaces the playlist, a page commit starts a
//  new track — so each handler matches the delivered track against the
//  playlist's current one before acting.
//
//  STOP FIRES NO CALLBACK. AudioPlayer.stop is not a track-end event, so
//  nothing here drives auto-advance off it; track-end and skip-past-end both
//  funnel through didFinishPlaying:.
//

#import "PlaybackController+PlayerEvents.h"
#import "PlaybackControllerInternal.h"
#import "PlaybackController+NowPlaying.h"

#import "AudioErrorRules.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "DownloadProgressMonitor.h"
#import "UIUpdateTimer.h"

@implementation PlaybackController (PlayerEvents)

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    [self notifyDidBeginLoading];
    // A slow open is a materializing file often enough to treat it as one: the
    // scan's cloud lane stands down until this open settles, so a folder's
    // worth of background downloads cannot queue ahead of the one the user is
    // waiting on. Cleared everywhere the monitor below is.
    [_metadataCache setCloudParsesHeld:YES];
    // Best-effort determinate fill while the provider materializes the file.
    // The monitor drops a sample whose track has since changed; see
    // monitorReplacing:forURL:currentURL:handler:.
    __weak PlaybackController *weakSelf = self;
    _downloadMonitor = [DownloadProgressMonitor
            monitorReplacing:_downloadMonitor
                      forURL:track.url
                  currentURL:^NSURL *{
        PlaybackController *self = weakSelf;
        return self ? self->_playlist.currentTrack.url : nil;
    }                handler:^(float fraction) {
        [weakSelf notifyDidUpdateLoadingProgress:fraction];
    }];
    [self publishNowPlaying];
}

// A pause toggled while the open is still in flight — the user's tap, or an
// audio-session interruption — decides whether the load lands playing or
// parked. No audio has started, so this refreshes the transport glyph and the
// lock-screen card and nothing else.
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
    // A start settles any seek in flight — including the one that OPENED this
    // file, in seekToProgress:'s parked branch, which has no didFinishSeeking:
    // of its own to clear the flag.
    _seekInFlight = NO;
    // The open landed, so the file is materialized; the monitor's work is
    // done whatever it last reported.
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    [_metadataCache setCloudParsesHeld:NO];
    [self notifyDidRenderCurrentTrack];
    // Not a blanket "hide the loading indicator": the open landing says
    // nothing about the waveform decode, which may still be streaming over the
    // network. The download fill IS cleared — the open landing means the file
    // materialized — and a screen re-hydrates from the snapshot it holds.
    [self notifyDidFinishLoading];
    // The dataless-placeholder retry: a cache miss skipped while the player's
    // own open was materializing the file parses now.
    [_metadataCache loadMetadataNow:track];
    // The open settled, so the playlist-wide sweep it was deferred behind runs.
    [self startPendingMetadataLoad];
    NSUInteger nextIndex = _playlist.currentIndex + 1;
    [_player prefetchTrack:_playlist.hasNextTrack ? [_playlist trackAtIndex:nextIndex] : nil];
    _folderSession.persistedTrackFileName = track.url.lastPathComponent;
    // The landing can be parked — a pause verdict during the load, or the
    // media-reset re-park — in which case playback is idle, so the session is
    // released just as a pause releases it.
    BOOL playing = _player.isPlaying;
    _updateTimer.wanted = playing;
    if (!playing) {
        [_audioSession deactivateWhenIdle];
    }
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    // A resume from a media-reset (or interrupted-load) park goes through
    // playPause directly, never playCurrentTrack, so the flag clears here.
    _parked = NO;
    _updateTimer.wanted = YES;
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    if (![_playlist isCurrentTrack:track]) {
        return;
    }
    _seekInFlight = NO;
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    // A natural end can be delivered just as the playlist is replaced —
    // folderSession:didOpenTracks: replaces and plays without stopping the
    // player first — and advancing then skips past the track the user just
    // picked. Same guard as the mac's MainPlayerController+PlayerEvents.
    if (track && ![_playlist isCurrentTrack:track]) {
        return;
    }
    if ([_playlist next]) {
        [self playCurrentTrack];
        return;
    }
    // End of playlist: park on the last track, ready to replay.
    _parked = YES;
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    [self notifyDidChangePlayState];
    [self notifyDidTick];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didAutoAdvanceFromTrack:(AudioTrack *)finishedTrack
                    toTrack:(AudioTrack *)startedTrack {
    // The player spliced into the pre-scheduled next track; audio never
    // stopped. This handler's job is the bookkeeping half of an auto-advance:
    // move the playlist cursor and run the per-track refresh, without play:.
    // A boundary that raced a track change belongs to the operation that
    // superseded it.
    if (![_playlist isCurrentTrack:finishedTrack]) {
        return;
    }
    // The playlist owns what "next" means. If its next row is no longer the
    // track the player spliced into — a replace raced the boundary —
    // correctness beats gaplessness: treat it as an ordinary track end, whose
    // play replaces the spliced audio with the real successor.
    if (startedTrack != [_playlist trackAtIndex:_playlist.currentIndex + 1]) {
        [self audioPlayer:audioPlayer didFinishPlaying:finishedTrack];
        return;
    }
    [_playlist next];
    [self notifyDidMoveToCurrentTrackAnimated:YES];
    // The rest of the per-track refresh — render, metadata, prefetch of the
    // new next (which re-arms the splice), Now Playing — is exactly
    // didStartPlaying:'s body, and its identity guard now passes.
    [self audioPlayer:audioPlayer didStartPlaying:startedTrack];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceID {
    // macOS-only path; never sent on iOS.
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    NSURL *url = error.userInfo[kVibeAudioErrorTrackURLKey];
    AudioTrack *current = _playlist.currentTrack;
    if (url && current && ![url isEqual:current.url]) {
        return;  // a stale delivery racing a track change
    }
    _errorText = VibeStatusForPlayError(error);
    _seekInFlight = NO;
    _trackStartPending = NO;
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    [_metadataCache setCloudParsesHeld:NO];
    // Nothing is going to start now, so the deferred sweep stops waiting.
    [self startPendingMetadataLoad];
    [self notifyDidFailCurrentTrack];
    if (current) {
        [self notifyDidRenderCurrentTrack];
    }
    _updateTimer.wanted = NO;
    [_audioSession deactivateWhenIdle];
    [self notifyDidChangePlayState];
    [self publishNowPlaying];
}

@end
