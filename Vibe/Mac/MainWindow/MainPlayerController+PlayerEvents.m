//
//  MainPlayerController+PlayerEvents.m
//  Vibe
//

#import "MainPlayerController+PlayerEvents.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+NowPlaying.h"

#import "AppStats.h"
#import "ArtworkDisplayController.h"
#import "AudioDevice.h"
#import "AudioErrorRules.h"
#import "AudioDeviceManager.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "DownloadProgressMonitor.h"
#import "AudioFileConverter.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"
#import "VibeStrings.h"

@implementation MainPlayerController (PlayerEvents)

// The pre-submit edge: synchronous on play:'s calling thread (main at every
// call site), before the open is submitted to the player queue. The scan's
// cloud lane stands down here, so the foreground open never contends with a
// background download it could have suspended — armed from the 0.5s slow-open
// timer, the hold used to hand every play a half-second of contention, and a
// raced track change skipped it entirely. Deliberately NOT stale-guarded:
// this fires before the playlist reflects the play, and the hold is
// idempotent. Cleared exactly once by the matching settlement —
// didStartPlaying:'s prefetch acknowledgement, the error path, or Close.
- (void)audioPlayer:(AudioPlayer *)audioPlayer willSubmitPlayForTrack:(AudioTrack *)track {
    _foregroundHoldGeneration++;
    [self.metadataCache setCloudParsesHeld:YES];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track {
    // Guarded like didStartPlaying:'s check: a stale delivery from a
    // superseded open must not load metadata, paint loading UI, or clear an
    // error mask for a track the playlist no longer points at.
    if (track != [self.playlistController currentTrack]) {
        return;
    }
    [self clearErrorMask];
    // A slow cloud open is in flight, and the header can still show cached
    // tags and art for the pending track while it materializes.
    [self.metadataCache loadMetadataNow:track];
    // Show the pending track's title and artist while it loads. The waveform's
    // loading line rides the Loading display state this renders, which resolved
    // back when the play was initiated; nothing shows it from here.
    [self updateUI];
    // The cloud-lane hold is willSubmitPlayForTrack:'s now, not this timer's:
    // this callback owns only the slow-open UI, and the monitor below — which
    // deliberately stays here, so a fast local or prefetched play never
    // constructs a metadata query and provider subscriber it would cancel
    // moments later.
    // Best-effort determinate fill while the provider materializes the file.
    // The monitor drops a sample whose track has since changed; see
    // monitorReplacing:forURL:currentURL:handler:.
    __weak MainPlayerController *weakSelf = self;
    _downloadMonitor = [DownloadProgressMonitor
            monitorReplacing:_downloadMonitor
                      forURL:track.url
                  currentURL:^NSURL *{ return [weakSelf.playlistController currentTrack].url; }
                    movement:^{
        // The uncoalesced feed: any raw byte progress extends the open's
        // abandon deadline. Deliberately not the fraction handler below,
        // whose whole-percent gate can stay silent for tens of seconds on a
        // huge slow file that is moving fine.
        [weakSelf.audioPlayer noteOpenProgressForURL:track.url];
    }                handler:^(float fraction) {
        [weakSelf.trackDisplay setWaveformLoadingProgress:fraction];
    }];
    // This runs after updateUI, which shows the pending track's art if it is
    // already resolved: the previous track's art must not outlive the shimmer.
    [_artworkController showPlaceholderForSlowLoad];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeLoadingPaused:(BOOL)paused
                  forTrack:(AudioTrack *)track {
    if (track != self.playlistController.currentTrack) {
        return;
    }
    [self updateUI]; // ends with the Now Playing publish
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track  {
    // A stale start from a just-replaced playlist, after a re-drop while the
    // old play's open was in flight. Do nothing: acting would reset the new
    // track's shimmer and waveform view, kick off a wasted decode and prefetch
    // for the old one, and cache the wrong duration. The new play's own events
    // drive the UI from here.
    if (track != [self.playlistController currentTrack]) {
        return;
    }
    // The convert swap's Now Playing resume hint is spent: the live position
    // republishes from here.
    self.convertSwapResumeTrack = nil;
    [_artworkController trackDidStartPlaying:track];
    [self clearErrorMask];
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    // The cloud-lane hold is NOT released here: it rides until the successor
    // prefetch below acknowledges its claim, or the lane's next transfer and
    // the prefetch would race to download the same file.
    [self.trackDisplay hideWaveformLoadingIndicator];
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:track.url];
    // The now-playing track jumps the scan queue: its header tags and art must
    // not wait behind the playlist sweep, because a cloud-heavy folder keeps
    // every scan worker blocked for minutes. This runs even when
    // didBeginLoading: already asked, since that call skips the parse while
    // the file is a dataless placeholder, and by now the open has materialized
    // it.
    [self.metadataCache loadMetadataNow:track];
    [self startPendingMetadataLoad];
    _currentTrackDuration = self.audioPlayer.duration;
    [self.trackDisplay prepareForWaveformLoad];
    [self.waveformCache loadWaveformForTrack:track];
    // Pre-open the likely-next file, so that auto-advance and Next skip the
    // file open, which dominates transition latency. It is recomputed on every
    // track start, since next, previous, a double-click and a re-drop all land
    // here. Past the last track, nil drops the parked handle.
    //
    // The cloud-lane hold releases in the acknowledgement, after the
    // successor's open claim is registered — prefetchTrack: alone is async
    // onto the player queue, so releasing inline would let the resumed lane
    // race the claim's registration and start a second transfer of the same
    // file. The stale guard is the hold GENERATION, not track identity: an
    // acknowledgement outrun by any newer submission — a rapid next, or a
    // replay of this same row, which reuses this same AudioTrack — must not
    // strip the hold that submission re-asserted; the newer play's own
    // settlement releases it.
    NSUInteger holdGeneration = _foregroundHoldGeneration;
    __weak MainPlayerController *weakSelf = self;
    [self.audioPlayer prefetchTrack:[self.playlistController trackAtIndex:self.playlistController.currentIndex + 1]
                        whenClaimed:^{
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf || holdGeneration != strongSelf->_foregroundHoldGeneration) {
            return;
        }
        [strongSelf.metadataCache setCloudParsesHeld:NO];
    }];
    // Whoever initiated this play has already fully rendered the row: play:'s
    // reloadData, next and previous's two-row window, or doubleClick's pair.
    // The mark makes resumeUIUpdateTimer, and so updateUI, refresh only the
    // play-state cell, where the equalizer indicator must flip to animating,
    // rather than rebuilding the whole row again.
    _lastReloadedTrack = track;
    // next and previous scroll at the click; this covers the other play paths.
    [self.playlistController scrollCurrentTrackToVisible];
    // The Convert items name this track from here on; their validation reads
    // a cache rather than statting on the main thread.
    [self.fileConverter refreshDestinationStateForTrack:track];
    [self resumeUIUpdateTimer];
    // A track can start already parked — the convert swap of a paused track —
    // and then no didPausePlaying: comes to stop the tick. The resume above
    // still runs, for its updateUI and visibility-gate refresh.
    if (!self.audioPlayer.isPlaying) {
        [self pauseUIUpdateTimer];
    }
    else {
        [[AppStats sharedInstance] playbackStarted];
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    if (track != self.playlistController.currentTrack) {
        return;
    }
    [[AppStats sharedInstance] playbackStopped];
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    if (track != self.playlistController.currentTrack) {
        return;
    }
    // A device-loss error can mask a track the player merely parked as Paused;
    // see audioPlayer:error:. Resuming proves the mask wrong.
    [self clearErrorMask];
    [[AppStats sharedInstance] playbackStarted];
    [self resumeUIUpdateTimer];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    // A natural-end callback can be delivered just as the user replaces the
    // playlist or double-clicks a new row. Auto-advance only if the finished
    // track is still the playlist's current one; otherwise we would skip past
    // the track the user has just chosen.
    if (track && track != [self.playlistController currentTrack]) {
        // The replacement may still be opening. In that gap the player has no
        // current track, so the finished track's stats run must stop here;
        // didStartPlaying: starts a fresh run when the replacement produces
        // audio. If the replacement is already playing, its identity matches
        // the playlist and its restarted clock must stay active — which is why
        // a playlist emptied since (both sides nil, and so equal) must not read
        // as that case and leave the clock running.
        AudioTrack *playlistTrack = self.playlistController.currentTrack;
        if (!playlistTrack || audioPlayer.currentTrack != playlistTrack) {
            [[AppStats sharedInstance] playbackStopped];
        }
        return;
    }
    // Folds the finished run.
    [[AppStats sharedInstance] playbackStopped];
    [self pauseUIUpdateTimer];
    // The end of the playlist must be read from the playlist before next:,
    // because the play it starts is async on the player queue, so the player
    // still reads Stopped right after an ordinary mid-playlist advance.
    BOOL hasNextTrack = self.playlistController.hasNextTrack;
    [self next:self];
    // At the end of the playlist, where next: started nothing, the cached
    // duration would go stale against the idle player. Mid-playlist the cache
    // must survive the Loading gap, because the live duration reads 0 there
    // and updatePlaybackUI uses the cache to keep the waveform progress pinned
    // rather than frozen.
    if (!hasNextTrack) {
        _currentTrackDuration = 0;
        // The park is the one place a zeroed duration is not followed by an
        // updateUI, so the tick rate would rest at the finished track's.
        [self syncUITimerRate];
        // Pin the resting header deterministically. The updateUI inside next:
        // read the player mid-teardown, where its position and duration race
        // the async stop, which could leave the waveform pinned at 100% while
        // the elapsed label read 0:00. Park the finished track at its start,
        // and let its metadata duration feed the resting right label, since
        // the player's own duration is torn down by now.
        [self.trackDisplay resetPlayheadToStartWithDuration:self.playlistController.currentTrack.duration
                                                       rate:self.playbackRate];
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didAutoAdvanceFromTrack:(AudioTrack *)finishedTrack
                    toTrack:(AudioTrack *)startedTrack {
    // The player spliced into the pre-scheduled next track; audio never
    // stopped. This handler's job is the bookkeeping half of an auto-advance:
    // move the playlist index and run the per-track refresh, without play:.
    // Same stale guard as didFinishPlaying:: a boundary that raced a re-drop
    // or a double-click belongs to the operation that superseded it.
    if (finishedTrack != [self.playlistController currentTrack]) {
        return;
    }
    // The playlist owns what "next" means. If its next row is no longer the
    // track the player spliced into — a swap or re-target raced the boundary —
    // correctness beats gaplessness: treat it as an ordinary track end, whose
    // next: plays the real successor and replaces the spliced audio.
    NSUInteger nextIndex = self.playlistController.currentIndex + 1;
    if (startedTrack != [self.playlistController trackAtIndex:nextIndex]) {
        [self audioPlayer:audioPlayer didFinishPlaying:finishedTrack];
        return;
    }
    [[AppStats sharedInstance] playbackStopped]; // fold the finished track's run
    [self.playlistController advanceToNextTrackWithoutPlaying];
    // The whole per-track refresh — metadata, waveform, duration cache,
    // recents, prefetch of the new next (which re-arms the splice), stats and
    // the UI timer — is exactly didStartPlaying:'s body, and its identity
    // guard now passes.
    [self audioPlayer:audioPlayer didStartPlaying:startedTrack];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain] && error.code == VibeAudioErrorNotPlaying) {
        // A play-pause toggle raced a track ending, or nothing is loaded. It
        // is harmless, so ignore it silently rather than popping a modal alert.
        return;
    }
    LogError(@"%@", error.localizedDescription);
    // Play-path errors carry the failing track's URL. A delivery can race a
    // re-drop's track change, so an error for a departed track is dropped
    // outright — the new track's own callbacks own the UI from here.
    NSURL *failedURL = error.userInfo[kVibeAudioErrorTrackURLKey];
    if (failedURL && ![failedURL isEqual:self.playlistController.currentTrack.url]) {
        return;
    }
    // Only a Stopped player takes the play-failure path below. That serves two
    // purposes. It guards against staleness, because play-path errors are
    // published as Stopped before delivery, so a stale error after a re-drop
    // reads Loading or Playing. And it excludes device-loss errors for a track
    // merely parked as Paused: masking a resumable track would render a false
    // error screen later, and zeroing the duration cache would freeze the
    // waveform progress after recovery. The park's didPausePlaying handles the
    // UI, and a resume lifts any mask.
    if (!self.audioPlayer.isStopped) {
        [self updateUI];
        return;
    }
    // Keep fetching the pick after a timed-out open, but ONLY one that was
    // still moving when the deadline ran out: ranked first, the serial lane's
    // next download is the file the user asked for, so a retry lands fast —
    // while the error UI stands and nothing auto-resumes playback. The entry
    // drops on the next track change, and the lane's own attempt budget bounds
    // a file that keeps failing.
    //
    // A transfer that showed no progress at all is the case this deliberately
    // does NOT chase. Spending the provider's slot re-fetching a file that
    // never arrived, unasked and behind a terminal error the user is looking
    // at, buys nothing: the retry it would speed up is one that would fail the
    // same way. It stays an ordinary sweep candidate.
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]
            && error.code == VibeAudioErrorFileOpenTimedOut && failedURL
            && [error.userInfo[kVibeAudioErrorOpenMadeProgressKey] boolValue]) {
        [self.metadataCache prependNeighborhoodURL:failedURL];
    }
    [self startPendingMetadataLoad];
    [[AppStats sharedInstance] playbackStopped];
    [self pauseUIUpdateTimer];
    // Playback failed, so the duration cached at the last didStartPlaying no
    // longer describes anything the player holds.
    _currentTrackDuration = 0;
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    [self.metadataCache setCloudParsesHeld:NO];
    [self.trackDisplay hideWaveformLoadingIndicator];
    // Errors present inline, with no modal and no auto-skip. A sheet on this
    // borderless window breaks key status and the bare transport keys. The
    // header shows the error state, the track stays in the playlist for a
    // retry, and the errored mark stops late metadata and art deliveries from
    // repopulating the header.
    [self setErrorMaskForTrack:self.playlistController.currentTrack
                        status:VibeStatusForPlayError(error)];
    [self updateUI];
}

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {

}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceIndex {
    LogDebug(@"MainPlayerController: didChangeOutputDevice: %zd", newDeviceIndex);
    if (newDeviceIndex == -1) {
        Settings.audioOutputDeviceName = @"";
        Settings.audioOutputDeviceUID = @"";
    }
    else {
        AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForId:newDeviceIndex];
        // The device has gone by the time this fires, or the enumeration
        // failed transiently. Keep the previous persisted choice rather than
        // erasing it.
        if (device) {
            Settings.audioOutputDeviceName = device.name;
            Settings.audioOutputDeviceUID = device.uid;
        }
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    // A real track carries the usual identity guard. Nil is the promised settle
    // after a seek with nothing playable loaded; accept it only while the player
    // is still stopped, not after a new load or play has superseded it.
    if ((track && track != self.playlistController.currentTrack)
            || (!track && !audioPlayer.isStopped)) {
        return;
    }
    [self updatePlaybackUI];
    // The playhead jumped, so resync Control Center's elapsed time.
    [self updateNowPlaying];
}

@end
