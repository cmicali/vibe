//
//  MainPlayerController.m
//  Vibe
//

#import "MainPlayerControllerInternal.h"
#import "MenuValidationRules.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Settings.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "SettingsRules.h"
#import "ArtworkDisplayController.h"
#import "TrackDisplayController.h"
#import "OutputDevicesMenuController.h"
#import "AppDelegate.h"
#import "AudioDeviceManager.h"
#import "MainPlayerContentView.h"
#import "AudioFileHandle.h"
#import "AudioPlayer.h"
#import "AudioPlayer+BitPerfect.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "WaveformView.h"
#import "AudioFileConverter.h"
#import "CloudTransferRegistry.h"
#import "FolderArtResolver.h"
#import "FolderAccessManager.h"
#import "PlaylistController.h"
#import "PlaybackDeliveryRules.h"
#import "PlaylistTableView.h"
#import "PlaylistDropZoneView.h"
#import "MainWindow.h"
#import "SymbolButton.h"
#import "PitchControlPanel.h"
#import "TransportKeyMonitor.h"
#import "NowPlayingController.h"
#import "MainMenuBuilder.h" // vends the context-menu items shared with the main menu
#import "MusicalKey.h"
#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerController+Transport.h" // updateFXIndicators, from the updateUI funnel
#import "MainPlayerController+PlayerEvents.h"
#import "MainPlayerController+Delivery.h"
#import "MainPlayerController+Window.h"
#import "MainPlayerController+Playlist.h"
#import "UIUpdateTimer.h"
#import "UIUpdateMath.h"
#import "TrackCommands.h"
#import "WaveformRendererRegistry.h"
#import "VibeStrings.h"

@implementation MainPlayerController {
    // The error mask: the track whose play failed and its short status. Weak:
    // the track stays for a retry, and replacing the playlist dissolves the
    // mark. Only setErrorMaskForTrack:status: and clearErrorMask write it.
    __weak AudioTrack*          _erroredTrack;
    NSString*                   _errorStatus;
    // The generation pairs each deferred-load fallback timer with its own
    // playlist, so a timer armed for playlist A cannot start B's load while
    // B's first track is still opening.
    BOOL                        _metadataLoadPending;
    NSUInteger                  _metadataLoadGeneration;
    // The header's notice title (showNotice:naming:), and the generation that
    // pairs the notice with its own timer. noticeStatus is the notice.
    NSString*                   _noticeTitle;
    NSUInteger                  _noticeGeneration;
    TransportKeyMonitor*        _keyMonitor;
    uint64_t                    _nextSecondUpdateGeneration; // a newer start or seek drops an older aimed update
    // Playing-row indicators reading band levels; the tap is off at zero.
    NSInteger                   _levelConsumers;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (id) init {
    // No nib: initWithWindow: marks the controller loaded, so AppKit never
    // runs loadWindow or windowDidLoad and both happen here.
    MainWindow *window = [[MainWindow alloc] init];
    if((self = [super initWithWindow:window])) {
        _emptyStateSuppressed = YES; // before the first updateUI
        // windowDidLoad hands it the audio player.
        self.devicesMenuController = [[OutputDevicesMenuController alloc] init];
        [self buildContentInWindow:window];
        [self windowDidLoad];
    }
    return self;
}

- (void)windowDidLoad {
    // Capped: a dead removal registration pins its tracks for the window's
    // lifetime.
    self.window.undoManager.levelsOfUndo = 32;
    [self buildCollaborators];
    [self wireCollaboratorHandlers];
    [self registerGrantAndArtworkObservers];
    [self wireWindowAndViews];
    [self buildPitchPanel];

    [self.playlistTableView reloadData];
    [self updateUI];
    [self syncEqualizerActivity];

    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        // macOS 13 has no -activate; calling it crashes at launch.
        [NSApp activateIgnoringOtherApps:NO];
    }
}

- (void)buildCollaborators {
    // Before the player exists, so no file opens with the default decoder.
    AudioFileHandle.appleMPEGDecoder = AppSettings.sharedInstance.appleMPEGDecoder;
    // The saved device resolves asynchronously (UID, then name): the HAL
    // sweep can stall on Bluetooth or an unavailable coreaudiod, and must
    // block neither the player queue nor first paint.
    self.audioPlayer = [[AudioPlayer alloc] initWithDeviceUID:AppSettings.sharedInstance.audioOutputDeviceUID
                                                     modelUID:AppSettings.sharedInstance.audioOutputDeviceModelUID
                                                         name:AppSettings.sharedInstance.audioOutputDeviceName
                                                     enableFX:AppSettings.sharedInstance.audioFXAllowed
                                                     delegate:self];
    self.audioPlayer.crossfadeMilliseconds = AppSettings.sharedInstance.effectiveCrossfadeMilliseconds;
    self.audioPlayer.declick = AppSettings.sharedInstance.declick;
    self.audioPlayer.volume = (float)AppSettings.sharedInstance.effectiveVolume;
    [self.audioPlayer setBitPerfectOutput:AppSettings.sharedInstance.bitPerfectOutput
                         exclusiveOutput:AppSettings.sharedInstance.exclusiveOutput
                              enableFX:AppSettings.sharedInstance.audioFXEnabled allowAnyDevice:AppSettings.sharedInstance.allowBitPerfectOnAnyDevice];
    self.devicesMenuController.audioPlayer = self.audioPlayer;

    self.metadataCache = [[AudioTrackMetadataCache alloc] init];
    self.metadataCache.delegate = self;

    self.waveformCache = [[AudioWaveformCache alloc] init];
    self.waveformCache.delegate = self;

    self.fileConverter = [[AudioFileConverter alloc] init];

    [CloudTransferRegistry.sharedRegistry addObserver:self];
    self.playlistController = [[PlaylistController alloc] initWithAudioPlayer:self.audioPlayer];
    self.playlistController.levelSource = self;
    self.playlistController.tableView = self.playlistTableView;

    _artworkController = [[ArtworkDisplayController alloc] initWithContentView:self.playerContentView];

    _keyMonitor = [[TransportKeyMonitor alloc] initWithController:self];

    self.nowPlayingController = [[NowPlayingController alloc] initWithDelegate:self];
    // Before the launch restore, so a shuffled restore starts its order on the
    // saved row.
    [self pushTransportModesToPlaylist];

    __weak MainPlayerController *weakSelf = self;
    _uiTimer = [[UIUpdateTimer alloc] initWithHz:kVibeUIUpdateHzMin handler:^{
        [weakSelf updatePlaybackUI];
        // Reconciliation, not an edge: a play settlement dropped as stale
        // (submittedPlayIsCurrent:) reaches no updateUI, which would leave the
        // system card's playbackState wrong for the whole track. The
        // publisher's unchanged check makes this a per-tick comparison;
        // position advance alone is not dirty.
        [weakSelf updateNowPlaying];
    }];
}

- (void)wireCollaboratorHandlers {
    // Asked once per request, so a settings change lands on the next load.
    // The iOS card installs its own, tempo only.
    self.waveformCache.analysisProvider = ^VibeWaveformAnalysis{
        AppSettings *settings = AppSettings.sharedInstance;
        return (VibeWaveformAnalysis){
            .bpm = settings.analyzeBPM,
            .key = settings.analyzeKey,
            .bands = [WaveformRendererRegistry readsBandsForIdentifier:settings.currentTheme.waveformStyle],
        };
    };
    _waveformAnalysisWanted = self.waveformCache.analysisProvider();

    // A track change mid-conversion stops the sweep at the next report.
    __weak MainPlayerController *weakControllerForConvert = self;
    self.fileConverter.progressHandler = ^(AudioTrack *track, double fraction) {
        MainPlayerController *strongSelf = weakControllerForConvert;
        if (strongSelf && track == [strongSelf displayedTrack]) {
            [strongSelf.trackDisplay setConvertSweepFraction:fraction];
        }
    };

    // The player's async events lag a slow open, so the header refreshes at
    // submission, off the playlist's one play funnel.
    __weak MainPlayerController *weakControllerForPlaylist = self;
    self.playlistController.playWillStartHandler = ^{
        MainPlayerController *strongSelf = weakControllerForPlaylist;
        if (!strongSelf) {
            return;
        }
        // The start already rendered both affected rows; the mark keeps
        // updateUI from rebuilding them.
        strongSelf->_lastReloadedTrack = strongSelf.playlistController.currentTrack;
        [strongSelf updateUI];
    };

    // The scan's ranking follows the cursor: on a file-provider folder each
    // parse is a download, and unranked the sweep works in filename order.
    // The index funnel is the one place every play, skip and gapless advance
    // passes through.
    self.playlistController.currentIndexDidChangeHandler = ^{
        [weakControllerForPlaylist updateMetadataNeighborhood];
    };

    self.playlistController.removeTracksRequestHandler = ^(NSArray<AudioTrack *> *tracks) {
        [weakControllerForPlaylist removePlaylistTracks:tracks];
    };

    // A move keeps the current track's identity and audio, so it never enters
    // a play funnel. This handler is the ONE undo registration point: it fires
    // for every completed move — drag, undo or redo — and registers the sets
    // swapped, so NSUndoManager chains undo and redo. A refused restore fires
    // nothing and registers nothing.
    self.playlistController.playlistOrderDidChangeHandler =
            ^(NSIndexSet *sourceIndexes, NSIndexSet *destinationIndexes) {
        MainPlayerController *controller = weakControllerForPlaylist;
        if (!controller) {
            return;
        }
        NSUndoManager *undoManager = controller.window.undoManager;
        [[undoManager prepareWithInvocationTarget:controller]
                movePlaylistTracksFromIndexes:destinationIndexes
                                    toIndexes:sourceIndexes
                                   generation:controller.playlistController.structureGeneration];
        [undoManager setActionName:STR_MENU_EDIT_REORDER];
        [controller reconcileAfterPlaylistStructureEdit];
    };

    __weak MainPlayerController *weakControllerForArt = self;
    _artworkController.currentTrackProvider = ^AudioTrack *{
        return weakControllerForArt.playlistController.currentTrack;
    };
    _artworkController.artDidResolveHandler = ^{
        [weakControllerForArt updateUI];
    };
    // Fired only for a target-matched install, so the delivery race is closed.
    _artworkController.dominantColorDidChangeHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (!strongSelf) {
            return;
        }
        strongSelf.waveformView.artworkThemeColor = strongSelf->_artworkController.dominantArtColor;
        [strongSelf refreshWaveformTheme];
    };
    _artworkController.transportBackdropDidChangeHandler = ^(BOOL dark, BOOL hasArtwork) {
        [weakControllerForArt.playerContentView setTransportBackdropDark:dark hasArtwork:hasArtwork];
    };
    self.playerContentView.appearanceChangedHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (strongSelf) {
            [strongSelf->_artworkController refreshTintWashes];
            [strongSelf applyWindowBackground]; // its layer color is not dynamic
            // The Now Playing placeholder follows the appearance.
            [strongSelf updateNowPlaying];
        }
    };
}

// Grants are observed here, not in the Files pane, which may never open: a
// new grant can reveal covers the resolver declined for want of one.
- (void)registerGrantAndArtworkObservers {
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(grantedFoldersDidChange:)
                                               name:FolderAccessManagerDidChangeNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(folderArtDidResolve:)
                                               name:FolderArtDidResolveNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
}

- (void)wireWindowAndViews {
    // Closing the player quits (windowWillClose:): with About open,
    // applicationShouldTerminateAfterLastWindowClosed never fires.
    self.window.delegate = self;

    [self applyStoredAppearance];
    [self applyAlwaysOnTop];
    [self applyWindowLock];
    [self applyAppIcon];

    self.waveformView.delegate = self;
    // The theme's style, never the loose waveformStyle key, which theme
    // migration consumed on macOS. This creates the renderer, so
    // prepareForWaveformLoad's fallback never runs.
    self.waveformView.waveformStyle = AppSettings.sharedInstance.currentTheme.waveformStyle;

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;
}


- (void)pauseUIUpdateTimer {
    _uiTimer.wanted = NO;
    [self syncEqualizerActivity];
}

- (void)resumeUIUpdateTimer {
    [self updateUI];
    [self scheduleUpdateAtNextDisplayedSecond];
    // Playback can start before the first occlusion notification.
    _uiTimer.windowVisible = [self isWindowVisible];
    _uiTimer.wanted = YES;
    [self syncEqualizerActivity];
}

#pragma mark - Equalizer levels

// PlaylistController starts its poller only for a materially visible playing
// row, and a running poller declares one consumer, so the tap follows that
// decision rather than a second approximation of visibility.
- (void)syncEqualizerActivity {
    BOOL surfaceVisible = [self isWindowVisible];
    BOOL audioOutputActive = self.audioPlayer.outputAudioActive;
    self.playlistController.equalizerSurfaceVisible = surfaceVisible;
    self.playlistController.equalizerAudioOutputActive = audioOutputActive;
    self.audioPlayer.levelsEnabled = _levelConsumers > 0
            && surfaceVisible && audioOutputActive;
}

// Counted rather than a flag: NSTableView reuses row views, so a new indicator
// can take the source before the outgoing one lets go and the count is briefly
// two. EqualizerIndicatorView guarantees one NO per YES, dealloc included.
- (void)equalizerLevelsWanted:(BOOL)wanted {
    if (wanted) {
        _levelConsumers++;
    }
    else {
        NSAssert(_levelConsumers > 0, @"unbalanced equalizer level demand");
        if (_levelConsumers == 0) {
            return;
        }
        _levelConsumers--;
    }
    [self syncEqualizerActivity];
}

- (BOOL)copyEqualizerLevels:(float *)out
                      count:(NSUInteger)count
                   sequence:(uint64_t *)sequence {
    return [self.audioPlayer copyBandLevels:out count:count sequence:sequence];
}

// After a start, resume or seek the label's next change is under a second
// away, and a 3 Hz tick can land a third of a second late — over a quiet
// intro, a stuck 0:00 reads as playback not starting. The position holds until
// the first frame renders, so an early shot re-aims at the same second.
- (void)scheduleUpdateAtNextDisplayedSecond {
    uint64_t generation = ++_nextSecondUpdateGeneration;
    NSTimeInterval target = floor(self.audioPlayer.position / self.playbackRate) + 1;
    [self aimUpdateAtDisplayedSecond:target generation:generation attempts:4];
}

- (void)aimUpdateAtDisplayedSecond:(NSTimeInterval)target generation:(uint64_t)generation
                          attempts:(NSUInteger)attempts {
    NSTimeInterval remaining = MAX(0, target - self.audioPlayer.position / self.playbackRate);
    __weak MainPlayerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((remaining + 0.01) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_nextSecondUpdateGeneration
                || !strongSelf.audioPlayer.isPlaying) {
            return;
        }
        if (attempts > 1 && strongSelf.audioPlayer.position / strongSelf.playbackRate < target) {
            [strongSelf aimUpdateAtDisplayedSecond:target generation:generation attempts:attempts - 1];
            return;
        }
        [strongSelf updatePlaybackUI];
    });
}

// Every mover of an input must call syncUITimerRate: the duration (updateUI),
// the rate (a fader tick) and the width (a resize). The duration is the cache:
// the live one reads 0 while Loading.
- (NSUInteger)wantedUIUpdateHz {
    return VibeUIUpdateHzForPlayhead(self.waveformView.devicePixelWidth, _currentTrackDuration, self.playbackRate,
                                     AppSettings.sharedInstance.uiUpdateHzCap);
}

- (void)syncUITimerRate {
    NSUInteger hz = [self wantedUIUpdateHz];
    if (hz != _uiTimer.hz) {
        LogDebug(@"UI update rate %lu Hz (waveform %.0f px, duration %.2fs, rate %.3f)",
                 (unsigned long)hz, self.waveformView.devicePixelWidth, _currentTrackDuration, self.playbackRate);
        _uiTimer.hz = hz;
    }
}

- (TrackDisplayState)displayState {
    return [self displayStateForTrack:self.playlistController.currentTrack];
}

- (TrackDisplayState)displayStateForTrack:(AudioTrack *)track {
    return VibeResolveTrackDisplayState(track,
                                        self.audioPlayer.currentTrack,
                                        _erroredTrack,
                                        _emptyStateSuppressed,
                                        self.audioPlayer.isStopped,
                                        self.audioPlayer.isLoading);
}

// TRAP: a state and a track rendered TOGETHER must come from ONE currentTrack
// read, through the ForTrack:/ForState: pair. Two reads can straddle a track
// change and pair a Track state with another track, or nil. updateUI is the
// pattern.
- (AudioTrack *)displayedTrack {
    AudioTrack *track = self.playlistController.currentTrack;
    return [self displayedTrackForState:[self displayStateForTrack:track] track:track];
}

- (AudioTrack *)displayedTrackForState:(TrackDisplayState)state track:(AudioTrack *)track {
    switch (state) {
        case TrackDisplayStateTrack:
        case TrackDisplayStateLoading:
            return track;
        case TrackDisplayStateEmpty:
        case TrackDisplayStateLaunchGrace:
        case TrackDisplayStateError:
        case TrackDisplayStateNotice:
            return nil;
    }
}

- (TrackDisplayState)headerState {
    return [self headerStateForState:[self displayState]];
}

// The one home of the rule: a notice outranks the display state, on the
// header only.
- (TrackDisplayState)headerStateForState:(TrackDisplayState)state {
    return _noticeStatus ? TrackDisplayStateNotice : state;
}

- (void)renderTrackPresentationForState:(TrackDisplayState)state
                                  track:(AudioTrack *)track
                           displayTrack:(AudioTrack *)displayTrack {
    TrackDisplayState header = [self headerStateForState:state];
    NSString *errorStatus = track && track == _erroredTrack ? _errorStatus : nil;
    // renderState rewrites the codec line, so tempo/key and FX follow it.
    [self.trackDisplay renderState:header
                             track:(header == TrackDisplayStateError ? track : displayTrack)
                          duration:self.audioPlayer.duration
                              rate:self.playbackRate
                            status:(_noticeStatus ?: errorStatus)
                             title:(_noticeStatus ? _noticeTitle : _unplayablePlaylistName)];
    [self effectiveTempoDidChange];
    [self updateFXIndicators];
    [_artworkController updateForTrack:displayTrack];
}

- (void)updateUI {
    // One currentTrack read for the pass (displayedTrack's trap). track, not
    // displayTrack, is used below where the error state titles the masked
    // track and the play icon follows the playlist.
    AudioTrack *track = self.playlistController.currentTrack;
    TrackDisplayState state = [self displayStateForTrack:track];
    AudioTrack *displayTrack = [self displayedTrackForState:state track:track];

    // The track check covers Close: the player's stop is async and can still
    // read isPlaying, and the paused timer brings no later updateUI.
    BOOL showPause = track && self.audioPlayer.isPlaying;
    [self.playerContentView setPlayButtonShowsPause:showPause];
    self.playButton.accessibilityLabel = showPause ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;

    self.playButton.enabled = self.playlistController.count > 0;
    self.nextButton.enabled = self.playlistController.hasNextTrack;

    // Hidden only under the launch grace, like the header's empty state.
    self.playerContentView.playlistDropZoneView.hidden = _emptyStateSuppressed;
    self.playerContentView.playlistDropZoneView.playlistEmpty =
            self.playlistController.count == 0;

    [self renderTrackPresentationForState:state
                                    track:track
                             displayTrack:displayTrack];

    // Only on a track change: the gutter's three states reconcile on their own
    // edges (the transfer registry, the cursor observer, syncEqualizerActivity).
    if (displayTrack != _lastReloadedTrack) {
        [self.playlistController reloadCurrentTrack];
        _lastReloadedTrack = displayTrack;
    }
    [self syncUITimerRate];
    [self updatePlaybackUI];
    [self updateNowPlaying];
}

- (double)playbackRate {
    return 1.0 + self.audioPlayer.pitch / 100.0;
}

// The cached duration: the live one reads 0 while Loading.
- (void)updatePlaybackUI {
    // A gapless promote publishes the new track's position before
    // didAutoAdvanceFromTrack: lands; a tick in that gap would draw the old
    // header at the new position. Loading still ticks: its player track is nil.
    AudioTrack *playerTrack = self.audioPlayer.currentTrack;
    if (playerTrack && playerTrack != self.playlistController.currentTrack) {
        return;
    }
    NSTimeInterval position = self.audioPlayer.position;
    [self.trackDisplay renderPosition:position
                             duration:_currentTrackDuration
                                 rate:self.playbackRate
                                state:[self headerState]];
    [self.audioPlayer noteDisplayedPosition:position forTrack:self.playlistController.currentTrack];
}

// Feeds both the delay's BPM-synced taps and the BPM/key line. The fx write is
// unconditional: neither the label's 0.1 BPM granularity nor a hidden readout
// may gate the audio.
- (void)effectiveTempoDidChange {
    // One currentTrack read (displayedTrack's trap). The audio follows the
    // playing track. The label follows the header, which names none under a
    // notice.
    AudioTrack *current = self.playlistController.currentTrack;
    TrackDisplayState state = [self displayStateForTrack:current];
    AudioTrack *track = [self displayedTrackForState:state track:current];
    AudioTrack *shown = [self displayedTrackForState:[self headerStateForState:state] track:current];
    float baseBPM = track.bpm;
    float scaledBPM = baseBPM > 0 ? baseBPM * self.playbackRate : 0;
    self.audioPlayer.fx.delayTapBPM = scaledBPM;
    // The key is not shifted with the fader: varispeed reaches a semitone only
    // at the 16% extreme, and a flickering key would misread as a data change.
    // The notation applies to tagged keys too.
    AppSettings *settings = AppSettings.sharedInstance;
    VibeMusicalKey key = shown && settings.showKey ? shown.key : VibeMusicalKeyNone;
    NSString *keyText = @"";
    if (VibeMusicalKeyIsValid(key)) {
        keyText = [settings.keyNotation isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]
                ? VibeMusicalKeyMusicalName(key)
                : VibeMusicalKeyCamelotName(key);
    }
    float labelBPM = shown && settings.showBPM ? scaledBPM : 0;
    [self.trackDisplay renderBPM:labelBPM
                         keyText:keyText
                        colorKey:(settings.keyColorsEnabled ? key : VibeMusicalKeyNone)];
}

- (IBAction)playPause:(nullable id)sender {
    if (self.audioPlayer.isStopped) {
        [self.playlistController play];
    }
    else {
        [self.audioPlayer playPause];
    }
}

- (void)revealEmptyStateNamingPlaylist:(NSString *)name {
    _emptyStateSuppressed = NO;
    _unplayablePlaylistName = [name copy];
    [self updateUI];
}

- (void)beginLinkResolveFeedbackAppending:(BOOL)append {
    if (append && [self displayedTrack]) {
        return;
    }
    [self.trackDisplay showWaveformLoadingIndicator];
}

- (void)endLinkResolveFeedback {
    if (self.trackDisplay.waveformLoadingIndicatorShown) {
        [self restoreCoveredHeader];
    }
}

static const NSTimeInterval kNoticeSeconds = 4;

- (void)showNotice:(NSString *)status naming:(NSString *)name {
    _noticeStatus = [status copy];
    _noticeTitle = [name copy];
    NSUInteger generation = ++_noticeGeneration;
    [self updateUI];
    __weak MainPlayerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNoticeSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MainPlayerController *strongSelf = weakSelf;
        if (strongSelf && strongSelf->_noticeGeneration == generation) {
            [strongSelf endNotice];
        }
    });
}

- (void)endNotice {
    _noticeGeneration++;
    if (!_noticeStatus) {
        return;
    }
    _noticeStatus = nil;
    _noticeTitle = nil;
    [self restoreCoveredHeader];
}

// The header after the drop shimmer or a notice. Either cleared the waveform,
// so a shown track loads it again. A slow open gets back the shimmer the
// notice kept off. A track's open still in flight keeps the strip. The render
// comes first: a notice's header takes no strip writes until it is gone.
- (void)restoreCoveredHeader {
    [self updateUI];
    AudioTrack *track = self.playlistController.currentTrack;
    switch ([self displayStateForTrack:track]) {
        case TrackDisplayStateLoading:
            if (_loadingURL) {
                [self.trackDisplay showWaveformLoadingIndicator];
                [self.trackDisplay setWaveformLoadingProgress:_loadingProgress];
            }
            break;
        case TrackDisplayStateTrack:
            [self.trackDisplay prepareForWaveformLoad];
            [self.waveformCache loadWaveformForTrack:track];
            break;
        case TrackDisplayStateEmpty:
        case TrackDisplayStateLaunchGrace:
        case TrackDisplayStateError:
        case TrackDisplayStateNotice:
            [self.trackDisplay hideWaveformLoadingIndicator];
            break;
    }
}

- (void)play:(NSArray<AudioTrack *> *)tracks {
    [self loadTracks:tracks selectingIndex:NSNotFound startPaused:NO];
}

// An open and the launch restore differ only in row and whether it sounds.
- (void)loadTracks:(NSArray<AudioTrack *> *)tracks selectingIndex:(NSUInteger)index startPaused:(BOOL)startPaused {
    _emptyStateSuppressed = NO; // a real track supersedes the launch grace
    _unplayablePlaylistName = nil;
    // The old scan dies before the new first track is submitted: its cloud
    // transfer would compete with this open, and its queue would pin the
    // departed playlist. Replacement only — next and previous keep the sweep.
    [self.metadataCache cancelScan];
    [self.playlistController loadTracks:tracks selectingIndex:index];
    [self.playlistController playStartPaused:startPaused];
    // Deferred until playback starts: four parse workers can starve the
    // player's own open on a slow disk. The fallback timer covers a play that
    // never starts.
    [self scheduleDeferredMetadataLoad];
}

- (void)addTracks:(NSArray<AudioTrack *> *)tracks {
    if (self.playlistController.count == 0) {
        [self play:tracks]; // nothing to append to — this IS the play
        return;
    }
    [self.playlistController append:tracks];
    // The open's deferral: an append mid-open must not start stage-two work
    // while the picked track materializes. The generation coalesces appends.
    [self scheduleDeferredMetadataLoad];
    // The re-park's prefetch queues FIFO behind a play submitted this turn, so
    // the player can suppress it once that play publishes its request.
    [self reconcileAfterPlaylistStructureEdit];
}

#pragma mark - Deferred metadata load / error mask

- (void)scheduleDeferredMetadataLoad {
    _metadataLoadPending = YES;
    NSUInteger generation = ++_metadataLoadGeneration;
    __weak MainPlayerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf startPendingMetadataLoadForGeneration:generation];
    });
}

- (void)cancelDeferredMetadataLoad {
    _metadataLoadPending = NO;
    _metadataLoadGeneration++; // orphan any armed fallback timer
}

- (void)startPendingMetadataLoad {
    [self startPendingMetadataLoadForGeneration:_metadataLoadGeneration];
}

- (void)startPendingMetadataLoadForGeneration:(NSUInteger)generation {
    if (!VibePlaybackConsumePendingMetadataLoad(&_metadataLoadPending, generation,
                                                 _metadataLoadGeneration)) {
        return;
    }
    [self.metadataCache loadMetadata:self.playlistController.playlist];
}

- (void)setErrorMaskForTrack:(AudioTrack *)track status:(NSString *)status {
    _erroredTrack = track;
    _errorStatus = status;
}

- (void)clearErrorMask {
    _erroredTrack = nil;
    _errorStatus = nil;
}

// One reset for the three: an identifier surviving its URL lets
// didBeginLoading:'s same-open check keep a fraction for an open it no longer
// shows.
- (void)endLoadingProgress {
    _loadingURL = nil;
    _loadingPath = nil;
    _loadingOpenRequestIdentifier = 0;
    _loadingProgress = -1;
}

- (IBAction)next:(nullable id)sender {
    // The refresh rides playWillStartHandler. Past the end next starts
    // nothing; the park's refresh is advanceOrParkAtTrackEnd's.
    [self.playlistController next];
}

- (IBAction)previous:(nullable id)sender {
    // Refresh rides the funnel; see next:. On the first row, Previous restarts
    // the loaded track (VibePlaybackPreviousIsAvailable).
    if (![self.playlistController previous] && !self.audioPlayer.isStopped) {
        [self.audioPlayer seekToPosition:0];
    }
}

- (IBAction)playSelectedTrack:(nullable id)sender {
    [self.playlistController playSelectedTrack];   // refresh rides the funnel; see next:
}

- (IBAction)closeApp:(id)sender {
    [self close];
}

- (IBAction)minimizeWindow:(id)sender {
    [self.window miniaturize:sender];
}

// Only the Add well appends; an append to an empty playlist becomes a
// replacing play in addTracks: anyway.
- (BOOL)mainWindow:(MainWindow *)mainWindow dropAppendsAtLocation:(NSPoint)location {
    return [self.playerContentView.playlistDropZoneView dropActionForWindowPoint:location]
            == PlaylistDropWellActionAdd;
}

// The drop zone no-ops while hidden or collapsed.
- (void)mainWindow:(MainWindow *)mainWindow fileDraggingUpdatedAtLocation:(NSPoint)location {
    [self.playerContentView.playlistDropZoneView fileDragUpdatedAtWindowPoint:location];
}

- (void)mainWindowFileDraggingEnded:(MainWindow *)mainWindow {
    [self.playerContentView.playlistDropZoneView fileDragEnded];
}

#pragma mark - Actions

- (void)refreshFolderArt {
    // The resolver caches the setting, so this is what makes a write
    // observable; its settled answers survive.
    [FolderArtResolver.sharedInstance folderArtSettingDidChange];
    [self.playlistController reloadAllTracks];
    [self updateUI];
}

- (void)refreshWindowTint {
    [_artworkController refreshTintWashes];
}

- (IBAction)toggleTimeDisplayMode:(id)sender {
    AppSettings.sharedInstance.showRemainingTime = !AppSettings.sharedInstance.showRemainingTime;
    [self applySettingsLiveEffects:VibeSettingsLiveEffectTrackDisplay];
}

// The Edit and window-body menus act on the current track; the row menu runs
// the same commands against the clicked row or its selection.
- (NSArray<AudioTrack *> *)currentTrackAsList {
    AudioTrack *track = self.playlistController.currentTrack;
    return track ? @[track] : @[];
}

- (IBAction) showInFinder:(id)sender {
    [TrackCommands revealInFinder:[self currentTrackAsList]];
}

- (IBAction) copyFile:(id)sender {
    // ⌘C is this item's, so a focused text field copies its own text.
    NSTextView *text = [self focusedTextView];
    if (text) {
        [NSApp sendAction:@selector(copy:) to:text from:sender];
        return;
    }
    [TrackCommands copyFiles:[self currentTrackAsList]];
}

- (IBAction) copyName:(id)sender {
    [TrackCommands copyNames:[self currentTrackAsList]];
}

#if DEBUG
- (PitchControlPanel *)pitchPanel {
    return _pitchPanel;
}

- (ArtworkDisplayController *)debugArtworkController {
    return _artworkController;
}

- (void)debugRefreshUI {
    [self updateUI];
}

- (NSUInteger)debugUIUpdateHz {
    return _uiTimer.hz;
}

// Diverges from debugUIUpdateHz exactly when a path moved an input without
// calling syncUITimerRate.
- (NSUInteger)debugExpectedUIUpdateHz {
    return [self wantedUIUpdateHz];
}
#endif

@end
