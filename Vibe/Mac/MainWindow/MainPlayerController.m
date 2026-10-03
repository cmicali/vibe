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
#import "DrawnControls.h"
#import "AudioFileHandle.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Devices.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformView.h"
#import "AudioFileConverter.h"
#import "CloudTransferRegistry.h"
#import "FolderArtResolver.h"
#import "FolderAccessManager.h"
#import "PlaylistController.h"
#import "PlaylistFile.h"
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
#import "UIUpdateTimer.h"
#import "UIUpdateMath.h"
#import "TrackCommands.h"
#import "OpenRequestCoordinator.h"
#import "WaveformRendererRegistry.h"
#import "VibeStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation MainPlayerController {
    // The error mask: the track whose play failed and its short status. Weak:
    // the track stays for a retry, and replacing the playlist dissolves the
    // mark. Only setErrorMaskForTrack:status: and clearErrorMask write it.
    __weak AudioTrack*          _erroredTrack;
    NSString*                   _errorStatus;
    // The playlist the empty header names (revealEmptyStateNamingPlaylist:);
    // cleared by every load and by Close.
    NSString*                   _unplayablePlaylistName;
    // The launch grace (revealEmptyStateNamingPlaylist:). Once cleared, never
    // set again.
    BOOL                        _emptyStateSuppressed;
    // The generation pairs each deferred-load fallback timer with its own
    // playlist, so a timer armed for playlist A cannot start B's load while
    // B's first track is still opening.
    BOOL                        _metadataLoadPending;
    NSUInteger                  _metadataLoadGeneration;
    TransportKeyMonitor*        _keyMonitor;
    BOOL                        _folderArtRefreshScheduled;
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
    _waveformBandsWanted = self.waveformCache.analysisProvider().bands;

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
            return nil;
    }
}

- (void)renderTrackPresentationForState:(TrackDisplayState)state
                                  track:(AudioTrack *)track
                           displayTrack:(AudioTrack *)displayTrack {
    // renderState rewrites the codec line, so tempo/key and FX follow it.
    [self.trackDisplay renderState:state
                             track:(state == TrackDisplayStateError ? track : displayTrack)
                          duration:self.audioPlayer.duration
                              rate:self.playbackRate
                       errorStatus:(track && track == _erroredTrack ? _errorStatus : nil)
            unplayablePlaylistName:_unplayablePlaylistName];
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
                                state:[self displayState]];
    [self.audioPlayer noteDisplayedPosition:position forTrack:self.playlistController.currentTrack];
}

// Feeds both the delay's BPM-synced taps and the BPM/key line. The fx write is
// unconditional: neither the label's 0.1 BPM granularity nor a hidden readout
// may gate the audio.
- (void)effectiveTempoDidChange {
    AudioTrack *track = [self displayedTrack];
    float baseBPM = track.bpm;
    float scaledBPM = baseBPM > 0 ? baseBPM * self.playbackRate : 0;
    self.audioPlayer.fx.delayTapBPM = scaledBPM;
    // The key is not shifted with the fader: varispeed reaches a semitone only
    // at the 16% extreme, and a flickering key would misread as a data change.
    // The notation applies to tagged keys too.
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    VibeMusicalKey key = track && theme.showKey ? track.key : VibeMusicalKeyNone;
    NSString *keyText = @"";
    if (VibeMusicalKeyIsValid(key)) {
        keyText = [theme.keyNotation isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]
                ? VibeMusicalKeyMusicalName(key)
                : VibeMusicalKeyCamelotName(key);
    }
    float labelBPM = track && theme.showBPM ? scaledBPM : 0;
    [self.trackDisplay renderBPM:labelBPM
                         keyText:keyText
                        colorKey:(theme.keyColorsEnabled ? key : VibeMusicalKeyNone)];
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

// stop sends no callback, so nothing auto-advances; didFinishPlaying:'s stale
// guard drops one already in flight.
- (IBAction)closeFile:(nullable id)sender {
    [OpenRequestCoordinator.sharedCoordinator invalidate];
    [self endLoadingProgress];
    [self.audioPlayer stop];
    [self.waveformCache cancelLoad];
    [self.playlistController clear];
    // A cancelled scan loader still holds every queued track; drop it.
    [self cancelDeferredMetadataLoad];
    [self.metadataCache cancelScan];
    [self clearErrorMask];
    _unplayablePlaylistName = nil;
    _emptyStateSuppressed = NO; // Close explicitly asks for the empty state
    _currentTrackDuration = 0;
    [self pauseUIUpdateTimer];
    [self updateUI];
}

// Seeded from the tracks' common folder, so a folder's playlist lands beside
// its music.
- (IBAction)savePlaylist:(nullable id)sender {
    NSURL *common = [PlaylistFile commonDirectoryForTracks:self.playlistController.playlist];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeM3UPlaylist];
    panel.directoryURL = common;   // nil: the panel's own default
    panel.nameFieldStringValue = [(common.lastPathComponent ?: STR_PLAYLIST_SAVE_DEFAULT_NAME)
                                  stringByAppendingString:@".m3u"];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSError *error = nil;
        if (![self writePlaylistToURL:panel.URL error:&error]) {
            // A panel that just closes is indistinguishable from a saved file.
            [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
}

- (BOOL)writePlaylistToURL:(NSURL *)url error:(NSError **)error {
    // Relative to the chosen file's folder, which the reader resolves against.
    if (![PlaylistFile writeM3UForTracks:self.playlistController.playlist
                     relativeToDirectory:url.URLByDeletingLastPathComponent
                                   toURL:url error:error]) {
        return NO;
    }
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
    return YES;
}

#pragma mark - The last playlist

// The container mirror: absolute paths, never in Open Recent. The cursor is a
// defaults key written with the mirror; it is state, not a preference, so
// resetToDefaults leaves it.
static NSURL *VibeLastPlaylistURL(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES).firstObject;
    NSString *dir = [support stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"LastPlaylist.m3u"] isDirectory:NO];
}

- (void)saveLastPlaylist {
    NSError *error = nil;
    if (![PlaylistFile saveSessionTracks:self.playlistController.playlist
            currentIndex:self.playlistController.currentIndex enabled:AppSettings.sharedInstance.reopenLastPlaylist
            toURL:VibeLastPlaylistURL() defaults:NSUserDefaults.standardUserDefaults write:nil error:&error]) {
        LogError(@"Last playlist not saved: %@", error.localizedDescription);
    }
}

- (void)removeLastPlaylist {
    [PlaylistFile removeSessionAtURL:VibeLastPlaylistURL() defaults:NSUserDefaults.standardUserDefaults];
}

- (BOOL)restoreLastPlaylist {
    return [PlaylistFile restoreSessionAtURL:VibeLastPlaylistURL()
            enabled:AppSettings.sharedInstance.reopenLastPlaylist defaults:NSUserDefaults.standardUserDefaults
            load:^(NSArray<AudioTrack *> *rows, NSUInteger index, BOOL paused) {
        [self loadTracks:rows selectingIndex:index startPaused:paused];
    }];
}

- (void)applyReopenLastPlaylist {
    if (!AppSettings.sharedInstance.reopenLastPlaylist) {
        [self removeLastPlaylist];   // off means forget, not merely stop writing
    }
}

- (IBAction)next:(nullable id)sender {
    // The refresh rides playWillStartHandler. Past the end next starts
    // nothing; the park's refresh is advanceOrParkAtTrackEnd's.
    [self.playlistController next];
}

- (IBAction)previous:(nullable id)sender {
    [self.playlistController previous];   // refresh rides the funnel; see next:
}

- (IBAction)playSelectedTrack:(nullable id)sender {
    [self.playlistController playSelectedTrack];   // refresh rides the funnel; see next:
}

#pragma mark - Playlist editing

// Called from the index funnel and from structural edits, which that funnel
// does not fire for.
- (void)updateMetadataNeighborhood {
    [self.metadataCache setNeighborhoodTracks:self.playlistController.neighborhoodTracks];
}

- (IBAction)removeSelectedPlaylistTracks:(nullable id)sender {
    NSArray<AudioTrack *> *tracks = self.playlistController.selectedTracks;
    if (tracks.count == 0) {
        return;
    }
    [self removePlaylistTracks:tracks];
}

// The one removal funnel, and the only place a removal's playback consequences
// are decided: Playlist.removeTracksAtIndexes: touches no audio, so removing
// the current row there alone would leave the player sounding a track the
// playlist no longer holds, and every identity guard would read its events as
// stale. The files are never touched.
- (void)removePlaylistTracks:(NSArray<AudioTrack *> *)tracks {
    PlaylistController *playlist = self.playlistController;
    // Each exact object once; departed ones drop out.
    NSIndexSet *rows = [playlist rowsForTracks:tracks];
    if (rows.count == 0) {
        return;
    }
    // Removing every row is an unload, which closeFile: owns whole.
    if (rows.count == playlist.count) {
        [self closeFile:nil];
        return;
    }

    NSUInteger currentIndex = playlist.currentIndex;
    BOOL removingCurrent = [rows containsIndex:currentIndex];
    // Only a removed current row with a surviving forward successor keeps
    // sounding; otherwise the cursor moves back, and removal never replays
    // backward. The intent resolves behind every transport command already
    // queued, and the model's query keeps other edits off that round trip.
    VibePendingPlaybackIntent intent;
    BOOL continuesPlaying = [playlist forwardTrackAfterRemovingTracksAtIndexes:rows] != nil
            && [self.audioPlayer getPlaybackIntent:&intent forTrack:nil]
            && !intent.paused;

    // Undo restores the exact objects to their rows and never touches
    // transport. The generation keeps a restore off a replaced playlist.
    // Registering after the mutation is fine: both share this turn's group.
    NSArray<AudioTrack *> *removed = [playlist removeTracksAtIndexes:rows];
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self]
            reinsertPlaylistTracks:removed
                         atIndexes:rows
                        generation:playlist.structureGeneration];
    [undoManager setActionName:STR_MENU_EDIT_REMOVE_FROM_PLAYLIST];

    // Departed rows must not spend a provider transfer; undo re-requests them.
    for (AudioTrack *track in removed) {
        [self.metadataCache abandonQueuedTrack:track];
    }
    // The cursor callback is not raised for a structural edit, so this is the
    // removal's one reconciliation.
    if (!removingCurrent) {
        // The current track survived; only the successor can have moved.
        [self reconcileAfterPlaylistStructureEdit];
        return;
    }
    [self updateMetadataNeighborhood];

    // The current row is gone. The play funnel repaints at submission, brings
    // didStartPlaying:'s per-track refresh, and mints a newer play identity so
    // the removed open's settlement dies on submittedPlayIsCurrent:.
    [self clearErrorMask];
    // A fast local replacement never reaches didBeginLoading: to replace it.
    [self endLoadingProgress];
    BOOL startPaused = !continuesPlaying;
    if (startPaused) {
        // A slow parked open must not keep the UI tick running.
        [self pauseUIUpdateTimer];
    }
    [playlist playStartPaused:startPaused];
}

// The tail of every structural edit once the model is final. Not while
// Stopped: an errored player must not open or download a successor over a
// list edit, and a new play re-prefetches at its start.
- (void)reconcileAfterPlaylistStructureEdit {
    if (!self.audioPlayer.isStopped) {
        [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
    }
    [self updateMetadataNeighborhood];
    [self updateUI];
}

// The removal's undo. The redo registration precedes the generation bail, so
// a refused restore is not also a lost one; a dead pair's redo no-ops in
// removePlaylistTracks:'s departed-object guard. Transport is untouched: a
// removed current row does not replay.
- (void)reinsertPlaylistTracks:(NSArray<AudioTrack *> *)tracks
                     atIndexes:(NSIndexSet *)indexes
                    generation:(NSUInteger)generation {
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self] removePlaylistTracks:tracks];
    [undoManager setActionName:STR_MENU_EDIT_REMOVE_FROM_PLAYLIST];
    if (generation != self.playlistController.structureGeneration) {
        return;
    }
    [self.playlistController insertTracks:tracks atIndexes:indexes];
    // Re-requests the scan work abandoned at removal.
    for (AudioTrack *track in tracks) {
        [self.metadataCache loadMetadataNow:track];
    }
    [self reconcileAfterPlaylistStructureEdit];
}

// A reorder's undo and redo. A replaced playlist, or indexes the model
// refuses, move nothing and register nothing.
- (void)movePlaylistTracksFromIndexes:(NSIndexSet *)sourceIndexes
                            toIndexes:(NSIndexSet *)destinationIndexes
                           generation:(NSUInteger)generation {
    if (generation != self.playlistController.structureGeneration) {
        return;
    }
    [self.playlistController moveTracksAtIndexes:sourceIndexes
                                       toIndexes:destinationIndexes];
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

- (IBAction) toggleFileInfo:(id)sender {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    theme.showFileInfo = !theme.showFileInfo;
    [AppSettings.sharedInstance currentThemeDidChange];
    [self applySettingsLiveEffects:VibeSettingsLiveEffectTrackDisplay];
}

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

// Forgets no-grant answers only; a known cover rechecks access on every read.
// A full wipe would discard the covers an open's walk just harvested, since the
// open's own grant lands a moment later.
- (void)grantedFoldersDidChange:(NSNotification *)notification {
    [FolderArtResolver.sharedInstance invalidateDirectoriesSettledWithoutGrant];
    [self.playlistController reloadAllTracks];
    [self updateUI];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    AudioTrack *displayed = [self displayedTrack];
    if (displayed.metadata == notification.object) {
        [self updateUI];
    }
}

// Fired for "none" as well as a cover: the header holds the previous art until
// it hears. The resolver is serial, so consecutive folders land in different
// turns; a short delay coalesces where a per-turn gate would not.
static const NSTimeInterval kFolderArtRedrawDelay = 0.15;

- (void)folderArtDidResolve:(NSNotification *)notification {
    if (_folderArtRefreshScheduled) {
        return;
    }
    _folderArtRefreshScheduled = YES;
    __weak MainPlayerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFolderArtRedrawDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_folderArtRefreshScheduled = NO;
        [strongSelf.playlistController reloadVisibleTracks];
        [strongSelf updateUI];
    });
}

- (IBAction)setPitchRange:(id)sender {
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = sender;
        AppSettings.sharedInstance.pitchRange = [item.identifier isEqualToString:kVibeMenuPitchRange16] ? 16 : 8;
        [self applySettingsLiveEffects:VibeSettingsLiveEffectPitchRange];
    }
}

- (IBAction)toggleShuffle:(nullable id)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    settings.shuffleEnabled = !settings.shuffleEnabled;
    [self applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
}

- (IBAction)cycleRepeatMode:(nullable id)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    settings.repeatMode = VibeRepeatModeAfter(settings.repeatMode);
    [self applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
}

- (AudioTrack *)successorPrefetchTrack {
    AudioTrack *successor = self.playlistController.trackEndSuccessor;
    if (!VibePlaybackShouldAdvanceAtTrackEnd(successor != nil,
                                            AppSettings.sharedInstance.pauseAtTrackEnd)) {
        return nil;
    }
    return successor;
}

// The model and the system's controls, which show the same modes.
- (void)pushTransportModesToPlaylist {
    AppSettings *settings = AppSettings.sharedInstance;
    [self.playlistController setRepeatMode:settings.repeatMode shuffleEnabled:settings.shuffleEnabled];
    [self.nowPlayingController updateShuffleEnabled:settings.shuffleEnabled
                                         repeatMode:settings.repeatMode
                                          available:YES];
}

- (void)applyEndOfTrackAction {
    [self pushTransportModesToPlaylist];
    // nil unschedules an armed splice, so a mid-track switch to Pause does not
    // advance anyway; a new successor replaces one armed before a repeat or
    // shuffle change.
    [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
    // Next's availability and the codec line's glyphs follow the modes, on
    // screen and in Now Playing.
    self.nextButton.enabled = self.playlistController.hasNextTrack;
    [self updateFXIndicators];
    [self updateNowPlaying];
}

- (void)applyPitchRange {
    float range = (float)AppSettings.sharedInstance.pitchRange;
    self.audioPlayer.maxPitch = range;
    _pitchPanel.maxPitch = range;
    // A narrower range clamps the pitch.
    _pitchPanel.pitch = self.audioPlayer.pitch;
    [self updateRateDependentUI];
    // No gesture end publishes the clamped duration.
    [self updateNowPlaying];
}

// Cheap enough for every fader tick, unlike updateUI. No Now Playing publish,
// an XPC round trip a rate change always dirties: a gesture publishes once at
// its end, and the other callers publish for themselves.
- (void)updateRateDependentUI {
    [self.trackDisplay renderTotalDuration:self.audioPlayer.duration
                                      rate:self.playbackRate
                                     state:[self displayState]];
    [self effectiveTempoDidChange];
    [self syncUITimerRate];
    [self updatePlaybackUI];
}

- (void)pitchControlPanel:(PitchControlPanel *)panel didChangePitch:(float)pitch {
    self.audioPlayer.pitch = pitch;
    [self updateRateDependentUI]; // the update timer is off while paused
}

- (void)pitchControlPanelDidEndAdjusting:(PitchControlPanel *)panel {
    [self updateNowPlaying];
}

// A drag tick: the slider moved itself and the control is on, so the
// player and the percentage are all that follow.
- (IBAction)volumeChanged:(VibeSlider *)sender {
    AppSettings.sharedInstance.volume = sender.doubleValue;
    self.audioPlayer.volume = (float)AppSettings.sharedInstance.effectiveVolume;
    [self.playerContentView volumeSliderDidMove];
}

- (IBAction)toggleTimeDisplayMode:(id)sender {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    theme.showRemainingTime = !theme.showRemainingTime;
    [AppSettings.sharedInstance currentThemeDidChange];
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

- (NSDictionary *)debugLastPlaylistDictionary {
    return @{
        @"exists": @([NSFileManager.defaultManager fileExistsAtPath:VibeLastPlaylistURL().path]),
        @"rows": @([PlaylistFile rowsInM3UData:[NSData dataWithContentsOfURL:VibeLastPlaylistURL()]].count),
        @"currentIndex": @([NSUserDefaults.standardUserDefaults integerForKey:kVibeLastPlaylistCurrentIndexKey]),
    };
}
#endif

@end
