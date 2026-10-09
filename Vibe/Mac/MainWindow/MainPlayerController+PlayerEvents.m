//
//  MainPlayerController+PlayerEvents.m
//  Vibe
//

#import "MainPlayerController+PlayerEvents.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+NowPlaying.h"

#import "AppDelegate.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer+Devices.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Transport.h"
#import "AppStats.h"
#import "ArtworkDisplayController.h"
#import "AudioDevice.h"
#import "AudioErrorRules.h"
#import "AudioFileOpenRules.h"
#import "AudioDeviceManager.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioFileConverter.h"
#import "PlaylistController.h"
#import "PlaybackDeliveryRules.h"
#import "SettingsGeneralViewController.h"
#import "SettingsWindowController.h"
#import "TrackDisplayController.h"
#import "VibeStrings.h"

@implementation MainPlayerController (PlayerEvents)

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didChangeOutputAudioActive:(BOOL)outputAudioActive {
    [self syncEqualizerActivity];
    // Rendered audio, outgoing fades included, not play intent (true through
    // a silent cloud open). The current snapshot: this delivery can queue
    // behind a newer transport action.
    if (audioPlayer.outputAudioActive) {
        [AppStats.sharedInstance playbackStarted];
    }
    else {
        [AppStats.sharedInstance playbackStopped];
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
     didBeginLoading:(AudioTrack *)track
openRequestIdentifier:(uint64_t)openRequestIdentifier {
    if (track != [self.playlistController currentTrack]) {
        return;
    }
    [self clearErrorMask];
    [self.metadataCache loadMetadataNow:track];
    // This callback is the slow-open threshold, so a fast play never flashes
    // the indicator, nor builds a monitor it would cancel moments later.
    [self updateUI];
    [self.trackDisplay showWaveformLoadingIndicator];
    if (_loadingOpenRequestIdentifier != openRequestIdentifier) {
        _loadingURL = track.url;
        _loadingPath = VibeStandardizedAudioOpenPath(track.url);
        _loadingOpenRequestIdentifier = openRequestIdentifier;
        _loadingProgress = -1;
    }
    // The transfer may be well under way by the slow-open threshold.
    [self cloudTransferRegistryDidChange:CloudTransferRegistry.sharedRegistry];
    // After updateUI: the previous track's art must not outlive the shimmer.
    [_artworkController showPlaceholderForSlowLoad];
}

#pragma mark - CloudTransferRegistryObserver: the loading open's transfer

- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
    if (!_loadingURL || ![[self.playlistController currentTrack].url isEqual:_loadingURL]) {
        return;
    }
    float fraction = [registry progressForURL:_loadingURL];
    if (fraction > _loadingProgress) {
        _loadingProgress = fraction;
        [self.trackDisplay setWaveformLoadingProgress:fraction];
    }
}

// By open identifier, so an older open's transfer cannot extend this one.
- (void)cloudTransferRegistry:(CloudTransferRegistry *)registry didMoveTransferForPath:(NSString *)path {
    if ([path isEqualToString:_loadingPath]) {
        [self.audioPlayer noteOpenProgressForOpenRequestIdentifier:_loadingOpenRequestIdentifier];
    }
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
    // Acting on a stale start would reset the new track's shimmer and
    // waveform, start a wasted decode and prefetch, and cache the wrong
    // duration.
    if (track != [self.playlistController currentTrack]) {
        return;
    }
    [self performPerTrackRefreshForStartedTrack:track];
}

- (void)replayTrack:(AudioTrack *)track intent:(VibePendingPlaybackIntent)intent {
    // Or Now Playing rewinds to 0 through the replay's Loading gap.
    self.replayResumeTrack = track;
    self.replayResumePosition = intent.position;
    [self.audioPlayer play:track atPosition:intent.position startPaused:intent.paused];
}

// TRAP: noting a recent document reads the file's attributes on main.
// NSDocumentController is main-thread only. On an SMB share one note held main
// for up to 500 ms. A dead server would hold it for the SMB timeout. Locality
// is read here, off main, and only a file on a local volume is noted. A file on
// a network volume, or on a volume that does not answer, never reaches Open
// Recent. The serial queue keeps the notes in play order.
static void VibeNoteRecentDocumentOnLocalVolume(NSURL *url) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.vibe.recentdocuments",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    dispatch_async(queue, ^{
        NSNumber *local = nil;
        [url getResourceValue:&local forKey:NSURLVolumeIsLocalKey error:NULL];
        if (local.boolValue) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
            });
        }
    });
}

// Callers own didStartPlaying:'s identity guard: the playlist must already
// point at the started track.
- (void)performPerTrackRefreshForStartedTrack:(AudioTrack *)track {
    self.replayResumeTrack = nil; // the live position publishes from here
    // First, so a quick second Next finds the park. nil past the end drops
    // it. The prefetch's registration preempts any background transfer.
    [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
    [_artworkController trackDidStartPlaying:track];
    [self clearErrorMask];
    [self endLoadingProgress];
    [self.trackDisplay hideWaveformLoadingIndicator];
    // A cue row reopens as its sheet, which names it.
    VibeNoteRecentDocumentOnLocalVolume(track.cueSheetURL ?: track.url);
    // The playing track jumps the scan queue. Again after didBeginLoading:'s
    // request, which skipped the parse while the file was dataless.
    [self.metadataCache loadMetadataNow:track];
    [self startPendingMetadataLoad];
    _currentTrackDuration = self.audioPlayer.duration;
    [self.trackDisplay prepareForWaveformLoad];
    [self.waveformCache loadWaveformForTrack:track];
    // The initiator already rendered the row; the mark keeps
    // resumeUIUpdateTimer's updateUI from rebuilding it.
    _lastReloadedTrack = track;
    // next and previous scroll at the click; this covers the other play paths.
    [self.playlistController scrollCurrentTrackToVisible];
    // Convert validation reads this cache rather than statting on main.
    [self.fileConverter refreshDestinationStateForTrack:track];
    [self resumeUIUpdateTimer];
    // A track can start parked (the convert swap of a paused track), and no
    // didPausePlaying: follows to stop the tick.
    if (!self.audioPlayer.isPlaying) {
        [self pauseUIUpdateTimer];
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    if (track != self.playlistController.currentTrack) {
        return;
    }
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    if (track != self.playlistController.currentTrack) {
        return;
    }
    // A device-loss error can mask a merely parked track; resuming proves the
    // mask wrong.
    [self clearErrorMask];
    [self resumeUIUpdateTimer];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    // A stale end would advance past the track the user just chose.
    if (track && track != [self.playlistController currentTrack]) {
        return;
    }
    [self advanceOrParkAtTrackEnd];
}

// The end of the still-current track: advance when the playlist and Settings >
// Playback allow, park on it otherwise, and return whether it advanced. Callers
// own didFinishPlaying:'s staleness guard.
- (BOOL)advanceOrParkAtTrackEnd {
    [self pauseUIUpdateTimer];
    // Read from the playlist before advanceAtTrackEnd, whose play is async:
    // the player still reads Stopped after an ordinary advance. Under Pause nothing has
    // spliced, since successorPrefetchTrack parked nothing; this second read
    // of the setting is load-bearing because it decides from the playlist.
    BOOL advances = VibePlaybackShouldAdvanceAtTrackEnd(
            self.playlistController.trackEndSuccessor != nil, AppSettings.sharedInstance.pauseAtTrackEnd)
            && [self.playlistController advanceAtTrackEnd];
    // Advancing, the cached duration must survive the Loading gap.
    if (!advances) {
        _currentTrackDuration = 0;
        // Not a tick: only updateUI writes the transport icon and Now
        // Playing, and it rests the tick rate.
        [self updateUI];
        // Then pin the resting header: updateUI read the player mid-teardown,
        // which can leave the waveform at 100% beside 0:00. The metadata
        // duration feeds the right label; the player's is torn down.
        [self.trackDisplay resetPlayheadToStartWithDuration:self.playlistController.currentTrack.duration
                                                       rate:self.playbackRate];
    }
    return advances;
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    didAutoAdvanceFromTrack:(AudioTrack *)finishedTrack
                    toTrack:(AudioTrack *)startedTrack {
    // The player spliced into the parked successor and audio never stopped:
    // move the index and run the per-track refresh, without play:.
    if (finishedTrack != [self.playlistController currentTrack]) {
        return;
    }
    // If the spliced track is no longer the playlist's trackEndSuccessor,
    // correctness beats gaplessness: an ordinary track end replaces its audio.
    if (![self.playlistController advanceFromTrack:finishedTrack toTrack:startedTrack]) {
        BOOL advanced = [self advanceOrParkAtTrackEnd];
        // With no advance, reload the finished row parked so the sounding
        // segment is replaced.
        if (!advanced) {
            [self.playlistController playStartPaused:YES];
        }
        return;
    }
    [self performPerTrackRefreshForStartedTrack:startedTrack];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    if (VibePlayErrorIsBenign(error)) {
        return; // a play-pause toggle raced a track end, or nothing is loaded
    }
    LogError(@"%@", error.localizedDescription);
    if (!VibePlayErrorMatchesCurrentURL(error, self.playlistController.currentTrack.url)) {
        return;
    }
    // Only Stopped takes the failure path. Play-path errors publish Stopped
    // before delivery, so a stale one reads Loading or Playing; and a
    // device-loss error for a parked track must not mask a resumable track or
    // zero the duration cache. The parked track still says why, on its info
    // line: the display state masks only a Stopped track, and a resume or a
    // new play clears the mark.
    if (!self.audioPlayer.isStopped) {
        if (self.audioPlayer.isPaused) {
            [self setErrorMaskForTrack:self.playlistController.currentTrack status:VibeStatusForPlayError(error)];
        }
        [self updateUI];
        return;
    }
    [self startPendingMetadataLoad];
    [self pauseUIUpdateTimer];
    _currentTrackDuration = 0;
    [self endLoadingProgress];
    [self.trackDisplay hideWaveformLoadingIndicator];
    // Inline, no auto-skip: a sheet on this borderless window breaks key
    // status and the bare keys. The mask stops late deliveries repopulating
    // the header.
    [self setErrorMaskForTrack:self.playlistController.currentTrack
                        status:VibeStatusForPlayError(error)];
    [self updateUI];
}

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {

}

- (void)audioPlayer:(AudioPlayer *)audioPlayer
    outputModesForDeviceUID:(NSString *)deviceUID
          bitPerfectOutput:(BOOL *)bitPerfectOutput
           exclusiveOutput:(BOOL *)exclusiveOutput {
    AppSettings *settings = AppSettings.sharedInstance;
    *bitPerfectOutput = [settings bitPerfectOutputForDeviceUID:deviceUID];
    *exclusiveOutput = [settings exclusiveOutputForDeviceUID:deviceUID];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOutputDevice:(NSInteger)newDeviceIndex
involuntaryFallbackUID:(NSString *)fallbackUID involuntaryFallbackName:(NSString *)fallbackName
carriedModesFromUID:(NSString *)carriedModesUID {
    LogDebug(@"MainPlayerController: didChangeOutputDevice: %zd", newDeviceIndex);
    AppSettings *settings = AppSettings.sharedInstance;
    BOOL bitPerfectBefore = settings.bitPerfectOutput;
    if (newDeviceIndex == -1) {
        // Only a chosen System Output forgets the device; a vanished one stays
        // the saved preference, so it is re-adopted when it returns.
        if (fallbackUID.length == 0 && fallbackName.length == 0) {
            settings.audioOutputDeviceName = @"";
            settings.audioOutputDeviceUID = @"";
            settings.audioOutputDeviceModelUID = @"";
        }
    }
    else {
        AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForId:newDeviceIndex];
        // nil: gone already, or a transient enumeration failure. Keep the
        // persisted choice.
        if (device) {
            // Only the carry the player applied.
            if (carriedModesUID.length) {
                [settings carryOutputModesFromDeviceUID:carriedModesUID toDeviceUID:device.uid];
            }
            settings.audioOutputDeviceName = device.name;
            settings.audioOutputDeviceUID = device.uid;
            settings.audioOutputDeviceModelUID = device.modelUID;
        }
    }
    // TRAP: a later switch may already be queued or bound, so this refreshes
    // dependent controls but never sends this device's modes back
    // (updatingOutputModes:NO).
    SettingsWindowController *settingsWindow = [(AppDelegate *)NSApp.delegate settingsWindowController];
    if (settings.bitPerfectOutput != bitPerfectBefore) {
        [self applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply updatingOutputModes:NO];
        [settingsWindow refreshSelectedPane];
    }
    [settingsWindow.audioPane refreshOutputDevice];
}

// The one edge both report readouts (the header lock, the Audio pane caption)
// redraw from. The player publishes on its own queue, so a read right after a
// setter sees the previous report.
- (void)audioPlayerDidChangeBitPerfectReport:(AudioPlayer *)audioPlayer {
    [self updateFXIndicators];
    [[(AppDelegate *)NSApp.delegate settingsWindowController].audioPane refreshBitPerfectRows];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    // nil is the settle of a seek with nothing loaded, current only while the
    // player is still Stopped.
    if (!VibePlaybackSeekSettlementIsCurrent(track, self.playlistController.currentTrack,
                                             audioPlayer.isStopped)) {
        return;
    }
    [self updatePlaybackUI];
    [self scheduleUpdateAtNextDisplayedSecond];
    [self updateNowPlaying];
}

@end
