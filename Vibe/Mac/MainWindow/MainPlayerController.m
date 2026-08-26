//
//  MainPlayerController.m
//  Vibe
//

#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Settings.h"
#import "AppSettings.h"
#import "ArtworkDisplayController.h"
#import "TrackDisplayController.h"
#import "OutputDevicesMenuController.h"
#import "AppDelegate.h"
#import "AudioDeviceManager.h"
#import "MainPlayerContentView.h"
#import "AudioPlayer.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformView.h"
#import "AudioFileConverter.h"
#import "FolderArtResolver.h"
#import "FolderAccessManager.h"
#import "PlaylistController.h"
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
// The conformances windowDidLoad wires self up as: the player's delegate, the
// two caches' and the waveform view's, and the window's own.
#import "MainPlayerController+PlayerEvents.h"
#import "MainPlayerController+Delivery.h"
#import "MainPlayerController+Window.h"
#import "DownloadProgressMonitor.h"
#import "UIUpdateTimer.h"
#import "UIUpdateMath.h"
#import "AppStats.h"
#import "TrackCommands.h"
#import "VibeStrings.h"

// The state the categories share is in MainPlayerControllerInternal.h; what
// follows is private to this file.
@implementation MainPlayerController {
    // The error mask: the track whose play attempt failed, plus the short
    // status for the error rendering's artist line. The full error text goes
    // to the log. While that track is still current and the player is stopped,
    // the header renders the error state and ignores the track, late metadata,
    // art, and waveform deliveries included. The reference is weak, because the track
    // stays in the playlist for a retry and replacing the playlist dissolves
    // the mark. Only setErrorMaskForTrack:status: and clearErrorMask write it.
    __weak AudioTrack*          _erroredTrack;
    NSString*                   _errorStatus;
    // The launch grace; see revealEmptyState in the header. While YES the
    // empty state renders as a blank header. Once cleared it is never set
    // again.
    BOOL                        _emptyStateSuppressed;
    // The deferred playlist-wide metadata load; see play:. The generation
    // pairs each play:'s two-second fallback timer with its own playlist, so
    // that a timer armed by playlist A and firing after a re-drop cannot start
    // playlist B's load while B's first track is still opening. Only
    // scheduleDeferredMetadataLoad, cancelDeferredMetadataLoad and
    // startPendingMetadataLoad write it.
    BOOL                        _metadataLoadPending;
    NSUInteger                  _metadataLoadGeneration;
    TransportKeyMonitor*        _keyMonitor;
    // Coalesces the redraws behind FolderArtDidResolveNotification; see
    // folderArtDidResolve:. Main thread only.
    BOOL                        _folderArtRefreshScheduled;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (id) init {
    // The window is programmatic, with no nib. initWithWindow: marks the
    // controller as already loaded, so even an overridden loadWindow would
    // never run. The window is therefore built here, and windowDidLoad, which
    // AppKit fires only on the nib path, is invoked directly.
    MainWindow *window = [[MainWindow alloc] init];
    if((self = [super initWithWindow:window])) {
        // Set before the first updateUI, so that the launch grace covers the
        // very first render.
        _emptyStateSuppressed = YES;
        // windowDidLoad hands this the audio player, so it must exist first.
        self.devicesMenuController = [[OutputDevicesMenuController alloc] init];
        [self buildContentInWindow:window];
        [self windowDidLoad];
    }
    return self;
}

- (void)windowDidLoad {
    // Unlimited (the default) lets dead removal registrations accumulate for
    // the window's lifetime, each pinning its removed AudioTrack and metadata
    // after a playlist replacement has made it unrestorable. The cap bounds
    // that; nobody unwinds 32 conversions or removals deep.
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
        // macOS 13: -activate does not exist and crashes at launch —
        // Ventura's first real run found it. Same cooperative intent.
        [NSApp activateIgnoringOtherApps:NO];
    }
}

// Construction only: every collaborator exists after this, so the handler
// wiring in the next phase can capture any of them. No block contracts here.
- (void)buildCollaborators {
    // AudioPlayer starts on System Output and asks AudioDeviceManager to
    // resolve the saved device asynchronously, UID first and name as a
    // fallback. The HAL sweep can take tens of ms with Bluetooth devices, or
    // stall entirely when coreaudiod is unavailable; neither case occupies
    // the player's serial queue or this pre-first-paint path.
    self.audioPlayer = [[AudioPlayer alloc] initWithDeviceUID:AppSettings.sharedInstance.audioOutputDeviceUID
                                                         name:AppSettings.sharedInstance.audioOutputDeviceName
                                                     enableFX:AppSettings.sharedInstance.audioFXEnabled
                                                     delegate:self];
    self.audioPlayer.crossfadeMilliseconds = AppSettings.sharedInstance.crossfadeMilliseconds;
    self.devicesMenuController.audioPlayer = self.audioPlayer;

    self.metadataCache = [[AudioTrackMetadataCache alloc] init];
    self.metadataCache.delegate = self;

    // Owned here, like the metadata cache, because the waveform view is a pure
    // rendering surface. The controller requests loads and forwards the
    // deliveries: waveform snapshots to the view, BPM to the label.
    self.waveformCache = [[AudioWaveformCache alloc] init];
    self.waveformCache.delegate = self;

    self.fileConverter = [[AudioFileConverter alloc] init];

    self.playlistController = [[PlaylistController alloc] initWithAudioPlayer:self.audioPlayer];
    self.playlistController.levelSource = self;
    self.playlistController.tableView = self.playlistTableView;

    _artworkController = [[ArtworkDisplayController alloc] initWithContentView:self.playerContentView];

    // The bare transport keys, through a local event monitor. See
    // TransportKeyMonitor for the key list, and for why the menu
    // key-equivalent path cannot be trusted with unmodified keys.
    _keyMonitor = [[TransportKeyMonitor alloc] initWithController:self];

    // The system media keys, Control Center and Bluetooth transport controls.
    // updateNowPlaying publishes its now-playing info, called from the
    // updateUI funnel. Registering the command handlers now lets the media
    // keys route to us as soon as the first track starts playing.
    self.nowPlayingController = [[NowPlayingController alloc] initWithDelegate:self];

    __weak MainPlayerController *weakSelf = self;
    _uiTimer = [[UIUpdateTimer alloc] initWithHz:kVibeUIUpdateHzMin handler:^{
        [weakSelf updatePlaybackUI];
        // Reconciliation, not an edge: a play settlement dropped as stale
        // (AudioPlayer.submittedPlayIsCurrent:) reaches no updateUI, and the
        // system card then holds the wrong playbackState for as long as the
        // track plays — Control Center and the media keys read that card. The
        // publisher's unchanged check makes this a comparison per tick, not a
        // republish; natural position advance is deliberately not dirty.
        [weakSelf updateNowPlaying];
    }];
}

// The inline block wirings, one contract per block, each stated beside it.
- (void)wireCollaboratorHandlers {
    // Asked once per decode, so Settings > Playback and the debug channel's
    // set_analysis both land on the next load with nothing to republish. iOS
    // installs no provider: it never analyzes.
    self.waveformCache.analysisProvider = ^VibeWaveformAnalysis{
        return (VibeWaveformAnalysis){AppSettings.sharedInstance.analyzeBPM, AppSettings.sharedInstance.analyzeKey};
    };

    // The brush-through-the-waveform progress, gated on the converting track
    // still being on screen, so a track change mid-conversion stops the sweep
    // at the next report.
    __weak MainPlayerController *weakControllerForConvert = self;
    self.fileConverter.progressHandler = ^(AudioTrack *track, double fraction) {
        MainPlayerController *strongSelf = weakControllerForConvert;
        if (strongSelf && track == [strongSelf displayedTrack]) {
            [strongSelf.trackDisplay setConvertSweepFraction:fraction];
        }
    };

    // Every play starts one the controller does not see until the player's
    // async events land, which is up to half a second on a slow open — so the
    // header is refreshed at initiation instead. It hangs off the playlist's
    // one play funnel rather than off each entry point; see playWillStartHandler.
    __weak MainPlayerController *weakControllerForPlaylist = self;
    self.playlistController.playWillStartHandler = ^{
        MainPlayerController *strongSelf = weakControllerForPlaylist;
        if (!strongSelf) {
            return;
        }
        // The start has already rendered both affected rows — a double-click
        // and next/previous through the index-change observer, an open through
        // its reloadData — so the mark keeps this updateUI to the play-state
        // cell rather than rebuilding a row that was just built.
        strongSelf->_lastReloadedTrack = strongSelf.playlistController.currentTrack;
        [strongSelf updateUI];
    };

    // The scan's ranking follows the cursor, not the playback state: on a
    // file-provider folder each background parse is a whole file coming down a
    // wire, one at a time, and left unranked the sweep works through the folder
    // in filename order however far that is from the track the listener has
    // just reached. The playlist's index funnel is the one place every play,
    // skip and gapless auto-advance passes through.
    self.playlistController.currentIndexDidChangeHandler = ^{
        [weakControllerForPlaylist updateMetadataNeighborhood];
    };

    // A row context menu asked for a removal. This side resolves the captured
    // objects and owns every playback consequence.
    self.playlistController.removeTracksRequestHandler = ^(NSArray<AudioTrack *> *tracks) {
        [weakControllerForPlaylist removePlaylistTracks:tracks];
    };

    // Rows were reordered. The current track kept its identity and its audio,
    // so beyond the shared structural-edit tail there is nothing to do — no
    // play funnel, ever: a Loading current row keeps its exact pending play
    // object, and a paused one stays paused where it was.
    //
    // A move is undoable as the list edit it is, and this handler is the ONE
    // registration point: it fires for every completed move — drag, undo or
    // redo alike — with the sets swapped, the move's own inverse, and
    // NSUndoManager routes a registration made while it unwinds onto the
    // opposite stack, so undo and redo chain with no second bookkeeping path.
    // Stamped like removal's restore; a refused restore performs no move,
    // fires no handler and so registers nothing, and its empty group pops
    // harmlessly.
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
    // The album_art waveform theme follows the settled art color. The
    // controller only fires this for a target-matched install, so the
    // async-delivery race is already closed on its side.
    _artworkController.dominantColorDidChangeHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (!strongSelf) {
            return;
        }
        strongSelf.waveformView.artworkThemeColor = strongSelf->_artworkController.dominantArtColor;
        [strongSelf refreshWaveformTheme];
    };
    // The header art tint depends on the appearance — a dark wash against a
    // light pastel — so re-derive it whenever the window's appearance flips.
    self.playerContentView.appearanceChangedHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (strongSelf) {
            [strongSelf->_artworkController refreshHeaderTint];
        }
    };
}

// A folder granted after a scan may hold the cover for tracks already
// loaded, whose lookup FolderArtResolver declined for want of a grant. Every
// grant path posts this — a drop, an open, the Files pane's Add Folder
// panel — and that pane may never have been opened, so the observation
// belongs here rather than in it.
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

// Wire the collaborators to the views. MainPlayerContentView applies all
// the appearance and layout at construction.
- (void)wireWindowAndViews {
    // Closing the player means quitting. Without this, closing the main window
    // while the About window is open leaves the app running with no way to get
    // the player back, because About still counts as a window and so
    // applicationShouldTerminateAfterLastWindowClosed never fires.
    self.window.delegate = self;

    self.window.appearance = AppSettings.sharedInstance.windowAppearance;
    [self applyAlwaysOnTop];

    self.waveformView.delegate = self;
    self.waveformView.waveformStyle = AppSettings.sharedInstance.waveformStyle;

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;
}


- (void)pauseUIUpdateTimer {
    _uiTimer.wanted = NO;
    [self syncEqualizerActivity];
}

- (void)resumeUIUpdateTimer {
    [self updateUI];
    // Refresh the visibility gate from the live occlusion state on every
    // resume. The timer hears about changes only through the occlusion
    // notification, and playback can start before the first one fires.
    _uiTimer.windowVisible = [self isWindowVisible];
    _uiTimer.wanted = YES;
    [self syncEqualizerActivity];
}

#pragma mark - Equalizer levels

// One reconciliation point for the producer and renderer. PlaylistController
// combines the window gate with the playing row's real scroll/window
// intersection before starting its snapshot poller. A running poller declares one
// consumer, so the tap follows the exact same decision rather than maintaining
// a second approximation of visibility.
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

// Scale the tick rate to how fast the playhead crosses the waveform, so that a
// five-second sample sweeps smoothly while an ordinary song stays at the 3 Hz
// floor it has always cost. The rule is VibeUIUpdateHzForPlayhead; this
// gathers its inputs and must run wherever one of them moves: the duration
// through the updateUI funnel, which every track start and transport event
// passes through, the rate at a fader tick, and the width at a resize.
//
// The duration is the cache, not the player's: the live one reads 0 in the
// Loading gap, the same reason updatePlaybackUI uses the cache.
- (void)syncUITimerRate {
    CGFloat widthPx = self.waveformView.devicePixelWidth;
    NSUInteger hz = VibeUIUpdateHzForPlayhead(widthPx, _currentTrackDuration, self.playbackRate,
                                              AppSettings.sharedInstance.uiUpdateHzCap);
    if (hz != _uiTimer.hz) {
        LogDebug(@"UI update rate %lu Hz (waveform %.0f px, duration %.2fs, rate %.3f)",
                 (unsigned long)hz, widthPx, _currentTrackDuration, self.playbackRate);
        _uiTimer.hz = hz;
    }
}

// The header's display state, resolved in one place: updateUI,
// updatePlaybackUI and the Now Playing publish all read this rather than
// re-deriving it from the underlying flags. The decision is
// VibeResolveTrackDisplayState, beside the enum it returns; this gathers its
// inputs, sampling the player once so the whole state resolves against one
// consistent view of it.
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

// The track the header should describe: the playlist's current track, or nil
// while the empty or error state is up.
//
// TRAP: a state and a track that will be rendered TOGETHER must derive from
// ONE currentTrack read — the ForTrack: pair, off one snapshot. Deriving them
// separately let a state that renders the track pair with a track read that
// answered nil, and renderState then messaged nil into a raising
// NSTextField setStringValue:. updateUI is the pattern to copy.
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
    // Full header refreshes have one order. renderState rewrites the codec and
    // waveform presentation, so tempo/key and FX are reapplied afterwards;
    // artwork then resolves against the same display-track decision.
    [self.trackDisplay renderState:state
                             track:(state == TrackDisplayStateError ? track : displayTrack)
                          duration:self.audioPlayer.duration
                              rate:self.playbackRate
                       errorStatus:_errorStatus];
    [self effectiveTempoDidChange];
    [self updateFXIndicators];
    [_artworkController updateForTrack:displayTrack];
}

- (void)updateUI {

    // One currentTrack read for the whole pass: state, track and displayTrack
    // are rendered together, so they must describe the same instant — the
    // trap is spelled out on displayedTrack.
    AudioTrack *track = self.playlistController.currentTrack;
    TrackDisplayState state = [self displayStateForTrack:track];
    // The masking rule lives in displayedTrackForState:track:; do not
    // re-derive it here. track is still used deliberately below, because the
    // error rendering titles the masked track and the play-button icon follows
    // the playlist.
    AudioTrack *displayTrack = [self displayedTrackForState:state track:track];

    // The track check covers Close. The player's stop is async on its queue,
    // so it can still read isPlaying for an instant after closeFile:, and no
    // later updateUI would fix the icon, since the update timer is paused.
    BOOL showPause = track && self.audioPlayer.isPlaying;
    self.playButton.symbolName = showPause ? @"pause.fill" : @"play.fill";
    self.playButton.accessibilityLabel = showPause ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;

    self.playButton.enabled = self.playlistController.count > 0;
    self.nextButton.enabled = self.playlistController.hasNextTrack;

    // The playlist pane's drop zone. It is hidden only under the launch grace,
    // like the header's empty state, so that a launch-time open never flashes
    // the rest hint. Its empty-against-populated presentation follows the
    // playlist count.
    self.playerContentView.playlistDropZoneView.hidden = _emptyStateSuppressed;
    self.playerContentView.playlistDropZoneView.playlistEmpty =
            self.playlistController.count == 0;

    [self renderTrackPresentationForState:state
                                    track:track
                             displayTrack:displayTrack];

    if (displayTrack && displayTrack == _lastReloadedTrack) {
        // The same track as last time, so only the play-pause indicator can
        // have changed in the playlist row.
        [self.playlistController reloadCurrentTrackPlayState];
    }
    else {
        [self.playlistController reloadCurrentTrack];
        _lastReloadedTrack = displayTrack;
    }
    [self syncUITimerRate];
    [self updatePlaybackUI];
    [self updateNowPlaying];
}

// The varispeed rate: the track plays this much faster or slower than file
// time, so the time labels show file time divided by it, which is the
// wall-clock time a DJ counting bars actually experiences. The waveform
// progress is a ratio and needs no scaling.
- (double)playbackRate {
    return 1.0 + self.audioPlayer.pitch / 100.0;
}

// The position tick, and the refresh after a seek or a rate change. It uses the
// cached duration rather than the live one, because the live duration reads 0
// in the Loading gap, and the cache keeps the waveform progress pinned rather
// than frozen.
- (void)updatePlaybackUI {
    // A gapless promote publishes the next track's position a beat before
    // didAutoAdvanceFromTrack: lands and runs the full refresh; a tick inside
    // that gap would draw the old track's header against the new track's
    // near-zero position. Skip it — the imminent refresh redraws everything.
    // (Loading keeps ticking: the player's track is nil then, not different.)
    AudioTrack *playerTrack = self.audioPlayer.currentTrack;
    if (playerTrack && playerTrack != self.playlistController.currentTrack) {
        return;
    }
    [self.trackDisplay renderPosition:self.audioPlayer.position
                             duration:_currentTrackDuration
                                 rate:self.playbackRate
                                state:[self displayState]];
}

// Every effective-tempo change — a track change, a BPM delivery, a fader tick
// — funnels through here, so that both consumers see it: the delay echo's
// BPM-synced taps and the BPM label. The fx write is unconditional, because
// the label's 0.1 BPM granularity is coarser than the fader's and must not
// gate the audio parameter. The setter no-ops on the same value. The key
// shares the label line, so its changes — a key delivery, a notation change
// — funnel through here too.
- (void)effectiveTempoDidChange {
    AudioTrack *track = [self displayedTrack];
    float baseBPM = track.bpm;
    float scaledBPM = baseBPM > 0 ? baseBPM * self.playbackRate : 0;
    self.audioPlayer.fx.delayTapBPM = scaledBPM;
    // The label shows the same pitch-scaled value, and no track clears it.
    // The key is the track's own, deliberately not shifted with the fader:
    // the varispeed's shift only reaches a semitone at the extreme of the
    // 16% range, and a flickering key label would misread as a data change.
    // The notation governs every key the app shows, a tagged one included: the
    // tag was parsed to a VibeMusicalKey when it was read, so a file tagged
    // "Bbm" renders as "3A" under Camelot rather than as written.
    // Show key off blanks the readout entirely; detection and tags are
    // untouched, so flipping it back on redraws whatever the track carries.
    NSInteger key = track && AppSettings.sharedInstance.showKey ? track.key : -1;
    NSString *keyText = @"";
    if (key >= 0) {
        keyText = [AppSettings.sharedInstance.keyNotation isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]
                ? VibeMusicalKeyMusicalName(key)
                : VibeMusicalKeyCamelotName(key);
    }
    // Show BPM off blanks the label's tempo half; the fx write above is
    // unconditional, since a hidden readout must not change the audio.
    float labelBPM = track && AppSettings.sharedInstance.showBPM ? scaledBPM : 0;
    [self.trackDisplay renderBPM:labelBPM
                         keyText:keyText
                        colorKey:(AppSettings.sharedInstance.keyColorsEnabled ? key : -1)];
}

- (IBAction)playPause:(nullable id)sender {
    if (self.audioPlayer.isStopped) {
        [self.playlistController play];
    }
    else {
        [self.audioPlayer playPause];
    }
}

- (void)revealEmptyState {
    if (_emptyStateSuppressed) {
        _emptyStateSuppressed = NO;
        [self updateUI];
    }
}

- (void)play:(NSArray<NSURL *> *)urls {
    _emptyStateSuppressed = NO; // a real track supersedes the launch grace
    // The old playlist's scan dies before the new first track is submitted —
    // its in-flight cloud transfer would otherwise compete with the open the
    // user is waiting on, and its _queuedTracks would pin the departed
    // playlist. iOS has always done this (PlaybackController's folder-open
    // path); replacement only — next and previous must keep the sweep.
    [self.metadataCache cancelScan];
    [self.playlistController play:urls];
    // Defer the playlist-wide metadata load until playback has actually
    // started. Four workers reading every file can starve the player's own
    // file open on a slow disk, delaying the first sound by seconds. The
    // fallback covers the case where playback never starts at all, after a bad
    // file or a device error.
    [self scheduleDeferredMetadataLoad];
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    if (self.playlistController.count == 0) {
        [self play:urls]; // nothing to append to — this IS the play
        return;
    }
    [self.playlistController append:urls];
    // Re-queue the whole list through the same deferral every open uses — an
    // append mid-open must not restart stage-two metadata work while the
    // picked track is still materializing. The generation-guarded timer
    // coalesces repeated appends, and already-parsed tracks are skipped when
    // it fires.
    [self scheduleDeferredMetadataLoad];
    // The player queue owns the Loading decision. This call is FIFO behind a
    // play submitted in the same main turn, so it can suppress an unrelated
    // append prefetch after that play has published its pending request.
    [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
    [self updateUI];
}

#pragma mark - Deferred metadata load / error mask

- (void)scheduleDeferredMetadataLoad {
    _metadataLoadPending = YES;
    NSUInteger generation = ++_metadataLoadGeneration;
    __weak MainPlayerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MainPlayerController *strongSelf = weakSelf;
        if (strongSelf && generation == strongSelf->_metadataLoadGeneration) {
            [strongSelf startPendingMetadataLoad];
        }
    });
}

- (void)cancelDeferredMetadataLoad {
    _metadataLoadPending = NO;
    _metadataLoadGeneration++; // orphan any armed fallback timer
}

- (void)startPendingMetadataLoad {
    if (!_metadataLoadPending) {
        return;
    }
    _metadataLoadPending = NO;
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

// One teardown for the pair: a monitor surviving its identifier — or the
// reverse — lets didBeginLoading:'s identifier-reuse check keep a monitor for
// an open it no longer observes, or rebuild one it already has.
- (void)teardownDownloadMonitor {
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    _downloadMonitorOpenRequestIdentifier = 0;
}

// File > Close (⌘W): unload everything and return to the empty state. The
// player's stop sends no delegate callback, so nothing auto-advances, and
// didFinishPlaying:'s stale-track guard drops any end-of-track callback
// already in flight.
- (IBAction)closeFile:(nullable id)sender {
    [[AppStats sharedInstance] playbackStopped]; // stop fires no delegate callback
    [self teardownDownloadMonitor];
    [self.audioPlayer stop];
    [self.audioPlayer prefetchTrack:nil]; // drop the parked next-track handle
    [self.waveformCache cancelLoad];
    [self.playlistController clear];
    // Cancel the deferred playlist-wide metadata load, since nothing will play
    // to start it later, and release the scan loader.
    [self cancelDeferredMetadataLoad];
    [self.metadataCache cancelScan];
    [self clearErrorMask];
    _emptyStateSuppressed = NO; // Close explicitly asks for the empty state
    _currentTrackDuration = 0;
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (IBAction)next:(nullable id)sender {
    // The mark and the refresh ride playWillStartHandler now, off the playlist's
    // play funnel; at the end of the playlist next starts nothing, and the
    // stopped transport icon and Now Playing publish are the park's updateUI in
    // advanceOrParkAtTrackEnd, not this action's.
    [self.playlistController next];
}

- (IBAction)previous:(nullable id)sender {
    [self.playlistController previous];   // refresh rides the funnel; see next:
}

- (IBAction)playSelectedTrack:(nullable id)sender {
    [self.playlistController playSelectedTrack];   // refresh rides the funnel; see next:
}

#pragma mark - Playlist editing

// The scan's cloud-lane ranking follows the cursor. Called from the playlist's
// index funnel and from the removal funnel, which the index funnel deliberately
// does not fire for: one structural edit, one reconciliation.
- (void)updateMetadataNeighborhood {
    [self.metadataCache setNeighborhoodAroundIndex:self.playlistController.currentIndex
                                          inTracks:self.playlistController];
}

// Edit > Remove from Playlist, and the same through Backspace and Forward
// Delete. Resolve the selection when the action is dispatched.
- (IBAction)removeSelectedPlaylistTracks:(nullable id)sender {
    NSArray<AudioTrack *> *tracks = self.playlistController.selectedTracks;
    if (tracks.count == 0) {
        return;
    }
    [self removePlaylistTracks:tracks];
}

// The one funnel for every removal — the Edit menu, the two delete keys and the
// row context menu — and the only place the playback consequences of one are
// decided. Playlist.removeTracksAtIndexes: deliberately touches no audio, so
// removing the CURRENT row through it alone would leave the player sounding a
// track the playlist no longer contains: the identity guards on every player
// callback would then read correct events as stale, and auto-advance would have
// no authoritative successor. The files themselves are never touched.
- (void)removePlaylistTracks:(NSArray<AudioTrack *> *)tracks {
    PlaylistController *playlist = self.playlistController;
    // Resolve each exact object once — departed objects drop out, and the
    // index set dedupes a track a gesture managed to name twice.
    NSIndexSet *rows = [playlist rowsForTracks:tracks];
    if (rows.count == 0) {
        return;
    }
    // Removing every row is an unload, not an edit. closeFile: owns the
    // complete teardown — stop, download monitor, parked successor, waveform
    // load, deferred metadata and the scan, error mask, UI timer, empty state
    // — and a model-only removal would do none of it. Nothing is mutated
    // first: it clears the playlist itself.
    if (rows.count == playlist.count) {
        [self closeFile:nil];
        return;
    }

    NSUInteger currentIndex = playlist.currentIndex;
    BOOL removingCurrent = [rows containsIndex:currentIndex];
    // Only a removed CURRENT row with a surviving forward successor can keep
    // sounding: the first row after it not also being removed is the one the
    // model will slide into its place. When everything after the current row
    // is going too, the cursor moves BACK onto a previous row, and removal
    // must not replay backward. The intent resolves after every transport
    // command already submitted to the player queue; the two short-circuits
    // are what keep every other edit off that round trip.
    NSUInteger successorRow = currentIndex + 1;
    while ([rows containsIndex:successorRow]) {
        successorRow += 1;
    }
    BOOL continuesPlaying = removingCurrent
            && successorRow < playlist.count
            && [self.audioPlayer playingIntentAfterPendingCommands];

    // A removal is a plain list edit, so it is undoable like one: undo
    // restores the exact objects to their rows — identity, metadata and
    // analysis intact — and deliberately does not touch transport, so undoing
    // a removed current row does not replay it. The whole-list path above
    // registers nothing: that removal is File > Close, never undoable. The
    // stamped structureGeneration follows the model's own replace-all
    // announcement, and is what keeps a restore from editing a replaced
    // playlist. Registered from the model's own return — the exact objects in
    // ascending row order — which grouping permits: registration and mutation
    // share this run-loop turn's undo group whichever comes first.
    NSArray<AudioTrack *> *removed = [playlist removeTracksAtIndexes:rows];
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self]
            reinsertPlaylistTracks:removed
                         atIndexes:rows
                        generation:playlist.structureGeneration];
    [undoManager setActionName:STR_MENU_EDIT_REMOVE_FROM_PLAYLIST];

    // The departed rows' queued scan work must not spend a provider transfer
    // on files nobody can see; reinsertPlaylistTracks: re-requests it through
    // loadMetadataNow: when the removal is undone.
    for (AudioTrack *track in removed) {
        [self.metadataCache abandonQueuedTrack:track];
    }
    // Once, from the final rows. The playlist's cursor callback is deliberately
    // not raised for a structural edit, so this is the removal's own
    // reconciliation rather than a second notification of the same event.
    if (!removingCurrent) {
        // The current track kept its identity, so its audio, playhead and
        // header are untouched. Only which row is next can have moved — the
        // removed row may have been the parked successor, or a row before it.
        [self reconcileAfterPlaylistStructureEdit];
        return;
    }
    [self updateMetadataNeighborhood];

    // The current row is gone. Submit through the playlist's one play funnel,
    // so playWillStartHandler repaints the header at submission and
    // didStartPlaying:'s per-track refresh — waveform, artwork, recents,
    // duration cache, prefetch, stats — comes free. The submission also mints a
    // newer play identity, so the removed open's settlement is dropped by
    // AudioPlayer.submittedPlayIsCurrent:.
    [self clearErrorMask];
    // The monitor belongs to the removed row's open, and a fast local
    // replacement never reaches didBeginLoading: to replace it.
    [self teardownDownloadMonitor];
    // A successor keeps the old intent; the preceding row chosen after removing
    // the last track always parks, because removal must not replay backward.
    BOOL startPaused = !continuesPlaying;
    if (startPaused) {
        // The new submission drops any pending stop or pause callback for the
        // removed track, so settle its app-side lifecycle before superseding it.
        [[AppStats sharedInstance] playbackStopped];
        [self pauseUIUpdateTimer];
    }
    [playlist playStartPaused:startPaused];
}

// The tail every structural playlist edit shares once the model is final: the
// successor re-park, the one metadata-neighborhood recompute, and the
// transport/Now Playing refresh (rows themselves were reconciled by the
// model's structural event). Every prefetch goes through
// successorPrefetchTrack, so Settings > Playback > On track end still
// outranks it. A Stopped player is the exception: it advances nothing, holds
// no parked handle to retarget, and a new play re-prefetches at its start —
// so an errored player must not open (or download) a successor over a mere
// list edit.
- (void)reconcileAfterPlaylistStructureEdit {
    if (!self.audioPlayer.isStopped) {
        [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
    }
    [self updateMetadataNeighborhood];
    [self updateUI];
}

// The removal's undo. The redo registration comes first — while the manager
// isUndoing it lands on the redo stack — and precedes the generation bail so a
// refused restore is not also a lost one. A dead pair stays dead on its own:
// its redo hands removePlaylistTracks: tracks no playlist contains, which
// no-op in the departed-object guard. Restoring is a list edit only — the
// rows come back where they were, selected, but transport is untouched: a
// removed current row does not replay, exactly as removing it did not restart
// what survived.
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
    // The rows' queued scan work was abandoned at removal; this re-requests
    // it, and no-ops when the metadata had already landed. A restored row may
    // also be the new successor, which the shared tail re-parks.
    for (AudioTrack *track in tracks) {
        [self.metadataCache loadMetadataNow:track];
    }
    [self reconcileAfterPlaylistStructureEdit];
}

// A reorder's undo — and, because the handler above re-registers with the
// sets swapped while the manager unwinds, its redo too. The stamped
// generation dies quietly on a replaced playlist; indexes a later edit
// invalidated are refused by the model's own validation. Either way nothing
// moves, nothing registers, and the dead group pops harmlessly.
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

// Only the Add well appends. Replace and a drop outside the wells alike take
// the window-wide default, and an empty playlist appends to nothing, so the
// open funnel's addURLs: routes it back to a replacing play anyway.
- (BOOL)mainWindow:(MainWindow *)mainWindow dropAppendsAtLocation:(NSPoint)location {
    return [self.playerContentView.playlistDropZoneView dropActionForWindowPoint:location]
            == PlaylistDropWellActionAdd;
}

// The window's drag-over events, forwarded to the drop zone's wells. The view
// no-ops while hidden or collapsed.
- (void)mainWindow:(MainWindow *)mainWindow fileDraggingUpdatedAtLocation:(NSPoint)location {
    [self.playerContentView.playlistDropZoneView fileDragUpdatedAtWindowPoint:location];
}

- (void)mainWindowFileDraggingEnded:(MainWindow *)mainWindow {
    [self.playerContentView.playlistDropZoneView fileDragEnded];
}

#pragma mark - Actions

- (IBAction) toggleFileInfo:(id)sender {
    AppSettings.sharedInstance.showFileInfo = !AppSettings.sharedInstance.showFileInfo;
    [self applySettingsLiveEffects:VibeSettingsLiveEffectTrackDisplay];
}

- (void)refreshFolderArt {
    // No per-track work: folder covers live in FolderArtResolver, one per folder,
    // so telling it the setting moved is the whole of it. The rows and the
    // header re-ask, and the accessors decode only the folders still on screen.
    // What the resolver has *settled* deliberately survives; see
    // folderArtSettingDidChange.
    [FolderArtResolver.sharedInstance folderArtSettingDidChange];
    [self.playlistController reloadAllTracks];
    [self updateUI];
}

- (void)refreshWindowTint {
    // The artwork color has already settled; only re-resolve the wash from it.
    [_artworkController refreshHeaderTint];
}

// A grant arrived or went. No-grant discovery answers are forgotten; a known
// cover path stays recorded but every future read rechecks active access. A
// full invalidate is self-defeating: opening a folder auto-adds its grant a
// moment later, and wiping every answer discards the covers that same open's
// walk just harvested for free.
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

// A folder's artwork question has been answered — with a cover, or with "it has
// none", which matters just as much: the header holds the previous track's art
// until it hears. Redraw at most once per window, and only the rows on screen,
// since a playlist spanning many folders resolves them one after another. A
// short delay rather than one turn of the run loop, because the resolver is
// serial: consecutive folders land in *different* turns almost every time, so a
// per-turn gate would coalesce nothing.
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
        AppSettings.sharedInstance.pitchRange = [item.identifier isEqualToString:@"pitch_range_16"] ? 16 : 8;
        [self applySettingsLiveEffects:VibeSettingsLiveEffectPitchRange];
    }
}

- (AudioTrack *)successorPrefetchTrack {
    if (AppSettings.sharedInstance.pauseAtTrackEnd) {
        return nil;
    }
    return [self.playlistController trackAtIndex:self.playlistController.currentIndex + 1];
}

- (void)applyEndOfTrackAction {
    // Re-park the successor, or drop it: prefetchTrack: with nil unschedules
    // an armed splice, which is what keeps a mid-track switch to Pause from
    // advancing anyway. The claim acknowledgement is not wanted here — the
    // cloud-lane hold belongs to a play's settlement, not to a settings write.
    [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
}

- (void)applyPitchRange {
    float range = (float)AppSettings.sharedInstance.pitchRange;
    self.audioPlayer.maxPitch = range;
    _pitchPanel.maxPitch = range;
    // A narrower range clamps the current pitch, so resync the fader and the
    // rate-scaled time labels.
    _pitchPanel.pitch = self.audioPlayer.pitch;
    [self updateRateDependentUI];
    // The clamp can move the wall-clock duration Control Center shows, and no
    // fader gesture ends here to publish it.
    [self updateNowPlaying];
}

// Only the time labels depend on the playback rate. The full updateUI would
// also re-resolve the artwork and reload the current playlist row, rebuilding
// the cell view, which is far too heavy to run on every fader tick during a
// drag. The Now Playing publish is deliberately absent too, since it is an XPC
// round-trip that a rate change always dirties: fader gestures publish once at
// the end of the gesture, and the non-gesture caller, applyPitchRange,
// publishes for itself.
- (void)updateRateDependentUI {
    [self.trackDisplay renderTotalDuration:self.audioPlayer.duration
                                      rate:self.playbackRate
                                     state:[self displayState]];
    [self effectiveTempoDidChange];
    // A faster rate is a faster playhead. The fader is the one input that can
    // move without a track start or a resize.
    [self syncUITimerRate];
    [self updatePlaybackUI];
}

- (void)pitchControlPanel:(PitchControlPanel *)panel didChangePitch:(float)pitch {
    self.audioPlayer.pitch = pitch;
    // The time labels scale with the rate, so refresh immediately: the update
    // timer is not running while paused.
    [self updateRateDependentUI];
}

- (void)pitchControlPanelDidEndAdjusting:(PitchControlPanel *)panel {
    // The pitch has settled, so resync Control Center's duration and position
    // once for the whole gesture.
    [self updateNowPlaying];
}

// A click on the right time label flips between remaining and total and
// re-renders. The full updateUI funnel keeps the label's change guards
// coherent.
- (IBAction)toggleTimeDisplayMode:(id)sender {
    AppSettings.sharedInstance.showRemainingTime = !AppSettings.sharedInstance.showRemainingTime;
    [self applySettingsLiveEffects:VibeSettingsLiveEffectTrackDisplay];
}

// The Edit and window-body menus act on the current track; the playlist's row
// menu runs the same three commands against the clicked row or the selection
// containing it.

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

// The rule against the live inputs, for the check that pairs it with the
// rate actually armed: the two diverge exactly when some path moved the width,
// duration or rate without calling syncUITimerRate.
- (NSUInteger)debugExpectedUIUpdateHz {
    return VibeUIUpdateHzForPlayhead(self.waveformView.devicePixelWidth,
                                     _currentTrackDuration,
                                     self.playbackRate,
                                     AppSettings.sharedInstance.uiUpdateHzCap);
}
#endif

@end
