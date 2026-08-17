//
//  MainPlayerController.m
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "MainPlayerControllerInternal.h"
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
    // the header renders the error state and ignores the track, late metadata
    // and art deliveries included. The reference is weak, because the track
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

    // Closing the player means quitting. Without this, closing the main window
    // while the About window is open leaves the app running with no way to get
    // the player back, because About still counts as a window and so
    // applicationShouldTerminateAfterLastWindowClosed never fires.
    self.window.delegate = self;

    // AudioPlayer's async init resolves the saved device on its own queue, by
    // UID first and name as a fallback. Resolution enumerates CoreAudio
    // devices through per-device HAL property reads, which take tens of ms
    // when Bluetooth devices are present, and this method runs before first
    // paint.
    self.audioPlayer = [[AudioPlayer alloc] initWithDeviceUID:Settings.audioOutputDeviceUID
                                                         name:Settings.audioOutputDeviceName
                                                     enableFX:Settings.audioFXEnabled
                                                     delegate:self];
    self.metadataCache = [[AudioTrackMetadataCache alloc] init];
    self.metadataCache.delegate = self;

    // Owned here, like the metadata cache, because the waveform view is a pure
    // rendering surface. The controller requests loads and forwards the
    // deliveries: waveform snapshots to the view, BPM to the label.
    self.waveformCache = [[AudioWaveformCache alloc] init];
    self.waveformCache.delegate = self;
    // Asked once per decode, so Settings > Playback and the debug channel's
    // set_analysis both land on the next load with nothing to republish. iOS
    // installs no provider: it never analyzes.
    self.waveformCache.analysisProvider = ^VibeWaveformAnalysis{
        return (VibeWaveformAnalysis){Settings.analyzeBPM, Settings.analyzeKey};
    };

    self.fileConverter = [[AudioFileConverter alloc] init];

    self.playlistController = [[PlaylistController alloc] initWithAudioPlayer:self.audioPlayer];
    self.playlistController.tableView = self.playlistTableView;
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

    // A folder granted after a scan may hold the cover for tracks already
    // loaded, whose lookup FolderArtResolver declined for want of a grant. Every
    // grant path posts this — a drop, an open, the Files pane's Add Folder
    // panel — and that pane may never have been opened, so the observation
    // belongs here rather than in it.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(grantedFoldersDidChange:)
                                               name:FolderAccessManagerDidChangeNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(folderArtDidResolve:)
                                               name:FolderArtDidResolveNotification
                                             object:nil];

    _artworkController = [[ArtworkDisplayController alloc] initWithContentView:self.playerContentView];
    __weak MainPlayerController *weakControllerForArt = self;
    _artworkController.currentTrackProvider = ^AudioTrack *{
        return weakControllerForArt.playlistController.currentTrack;
    };
    _artworkController.artDidResolveHandler = ^{
        [weakControllerForArt updateUI];
    };
    // The playing row's equalizer bars take the artwork-derived accent, and
    // the playlist controller reloads the row when it changes.
    _artworkController.accentColorDidChangeHandler = ^(NSColor *accentColor) {
        weakControllerForArt.playlistController.accentColor = accentColor;
    };
    // The header art tint depends on the appearance — a dark wash against a
    // light pastel — so re-derive it whenever the window's appearance flips.
    self.playerContentView.appearanceChangedHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (strongSelf) {
            [strongSelf->_artworkController refreshHeaderTint];
        }
    };

    self.devicesMenuController.audioPlayer = self.audioPlayer;

    // Wire the collaborators to the views. MainPlayerContentView applies all
    // the appearance and layout at construction.

    self.window.appearance = Settings.windowAppearance;
    [self applyAlwaysOnTop];

    self.waveformView.delegate = self;
    self.waveformView.waveformStyle = Settings.waveformStyle;

    // The bare transport keys, through a local event monitor. See
    // TransportKeyMonitor for the key list, and for why the menu
    // key-equivalent path cannot be trusted with unmodified keys.
    _keyMonitor = [[TransportKeyMonitor alloc] initWithController:self];

    // The system media keys, Control Center and Bluetooth transport controls.
    // updateNowPlaying publishes its now-playing info, called from the
    // updateUI funnel. Registering the command handlers now lets the media
    // keys route to us as soon as the first track starts playing.
    self.nowPlayingController = [[NowPlayingController alloc] initWithDelegate:self];

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;

    // Built here rather than in MainPlayerContentView, because the panel must
    // be a sibling of the player body rather than a child: it is revealed by
    // widening the window past the body, and its size comes from the window's
    // restored frame, not the design size. It is right-anchored, with a fixed
    // width and a flexible left margin, so a drag-resize keeps it on the right
    // edge, or, while hidden, keeps it parked the same distance past it.
    // heightSizable tracks the small-large layout toggle.
    NSView *contentView = self.window.contentView;
    _pitchPanel = [[PitchControlPanel alloc] initWithFrame:[self pitchPanelFrame]];
    _pitchPanel.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    _pitchPanel.delegate = self;
    [contentView addSubview:_pitchPanel];
    [self applyPitchRange];
    self.audioPlayer.crossfadeMilliseconds = Settings.crossfadeMilliseconds;

    __weak MainPlayerController *weakSelf = self;
    _uiTimer = [[UIUpdateTimer alloc] initWithHz:kVibeUIUpdateHzMin handler:^{
        [weakSelf updatePlaybackUI];
    }];

    [self.playlistTableView reloadData];
    [self updateUI];

    [NSApp activate];
}

- (void)pauseUIUpdateTimer {
    _uiTimer.wanted = NO;
}

- (void)resumeUIUpdateTimer {
    [self updateUI];
    // Refresh the visibility gate from the live occlusion state on every
    // resume. The timer hears about changes only through the occlusion
    // notification, and playback can start before the first one fires.
    _uiTimer.windowVisible = [self isWindowVisible];
    _uiTimer.wanted = YES;
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
                                              Settings.uiUpdateHzCap);
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
    return VibeResolveTrackDisplayState(self.playlistController.currentTrack,
                                        self.audioPlayer.currentTrack,
                                        _erroredTrack,
                                        _emptyStateSuppressed,
                                        self.audioPlayer.isStopped,
                                        self.audioPlayer.isLoading);
}

// The track the header should describe: the playlist's current track, or nil
// while the empty or error state is up.
- (AudioTrack *)displayedTrack {
    switch ([self displayState]) {
        case TrackDisplayStateTrack:
        case TrackDisplayStateLoading:
            return self.playlistController.currentTrack;
        case TrackDisplayStateEmpty:
        case TrackDisplayStateLaunchGrace:
        case TrackDisplayStateError:
            return nil;
    }
}

- (void)updateUI {

    TrackDisplayState state = [self displayState];
    AudioTrack *track = self.playlistController.currentTrack;
    // The masking rule lives in displayedTrack; do not re-derive it here.
    // track is still used deliberately below, because the error rendering
    // titles the masked track and the play-button icon follows the playlist.
    AudioTrack *displayTrack = [self displayedTrack];

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

    // The error state passes the masked, errored track, whose title renders
    // under the error status. The other states describe displayTrack, which is
    // nil when empty.
    [self.trackDisplay renderState:state
                             track:(state == TrackDisplayStateError ? track : displayTrack)
                          duration:self.audioPlayer.duration
                              rate:self.playbackRate
                       errorStatus:_errorStatus];

    [self effectiveTempoDidChange];

    // The codec line shares its run with the FX symbols, and renderState: has
    // just rewritten its text, so re-assert the symbols alongside it.
    [self updateFXIndicators];

    [_artworkController updateForTrack:displayTrack];

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
    NSInteger key = track ? track.key : -1;
    NSString *keyText = @"";
    if (key >= 0) {
        keyText = [Settings.keyNotation isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]
                ? VibeMusicalKeyMusicalName(key)
                : VibeMusicalKeyCamelotName(key);
    }
    [self.trackDisplay renderBPM:(track ? scaledBPM : 0)
                         keyText:keyText
                        colorKey:(Settings.keyColorsEnabled ? key : -1)];
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
    // A still-pending deferred sweep reads the playlist when it fires. Once it
    // has started, re-queue the whole list; already-parsed tracks are skipped.
    if (!_metadataLoadPending) {
        [self.metadataCache loadMetadata:self.playlistController.playlist];
    }
    // The current track may have gained a successor, so refresh the parked
    // handle and the state of the Next button and menu item.
    [self.audioPlayer prefetchTrack:[self.playlistController trackAtIndex:self.playlistController.currentIndex + 1]];
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

// File > Close (⌘W): unload everything and return to the empty state. The
// player's stop sends no delegate callback, so nothing auto-advances, and
// didFinishPlaying:'s stale-track guard drops any end-of-track callback
// already in flight.
- (IBAction)closeFile:(nullable id)sender {
    [[AppStats sharedInstance] playbackStopped]; // stop fires no delegate callback
    [_downloadMonitor cancel];
    _downloadMonitor = nil;
    // The hold rides the monitor's lifetime, and its clearing edge is
    // didStartPlaying: or the error path — neither of which a Close reaches,
    // because stop fires no callback and the caller owns the reset. Left set,
    // it suspends the NEXT folder's cloud lane too, since the flag outlives
    // the loader.
    // The hold rides the monitor's lifetime, and its clearing edge is
    // didStartPlaying: or the error path — neither of which a Close reaches,
    // because stop fires no callback and the caller owns the reset. Left set,
    // it suspends the NEXT folder's cloud lane too, since the flag outlives
    // the loader.
    [self.metadataCache setCloudParsesHeld:NO];
    [self.audioPlayer stop];
    [self.audioPlayer prefetchTrack:nil]; // drop the parked next-track handle
    [self.waveformCache cancelLoad];
    [self.playlistController clear];
    // Cancel the deferred playlist-wide metadata load, since nothing will play
    // to start it later, and release the scan loader; see cancelAll.
    [self cancelDeferredMetadataLoad];
    [self.metadataCache cancelAll];
    [self clearErrorMask];
    _emptyStateSuppressed = NO; // Close explicitly asks for the empty state
    _currentTrackDuration = 0;
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (IBAction)next:(nullable id)sender {
    // The mark and the refresh ride playWillStartHandler now, off the playlist's
    // play funnel; at the end of the playlist next starts nothing and there is
    // nothing to refresh.
    [self.playlistController next];
}

- (IBAction)previous:(nullable id)sender {
    [self.playlistController previous];   // refresh rides the funnel; see next:
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
    Settings.showFileInfo = !Settings.showFileInfo;
    [self refreshFileInfoDisplay];
}

- (void)refreshFileInfoDisplay {
    // updateUI re-runs renderState: (the codec line) and
    // effectiveTempoDidChange (the BPM/key line); both read the setting.
    [self updateUI];
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

// A grant arrived or went. It can only unlock a folder the resolver left alone
// for want of one, so only those answers are forgotten — NOT everything. A full
// invalidate here is self-defeating: opening a folder auto-adds its grant a
// moment later, and wiping every answer discards the covers that same open's
// walk just harvested for free.
- (void)grantedFoldersDidChange:(NSNotification *)notification {
    [FolderArtResolver.sharedInstance invalidateDirectoriesSettledWithoutGrant];
    [self.playlistController reloadAllTracks];
    [self updateUI];
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
        Settings.pitchRange = [item.identifier isEqualToString:@"pitch_range_16"] ? 16 : 8;
        [self applyPitchRange];
    }
}

- (void)applyPitchRange {
    float range = (float)Settings.pitchRange;
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
    Settings.showRemainingTime = !Settings.showRemainingTime;
    [self updateUI];
}

- (void)refreshTimeDisplay {
    [self updateUI];
}

- (void)refreshKeyDisplay {
    [self effectiveTempoDidChange];
}

// The Edit and window-body menus act on the current track; the playlist's row
// menu runs the same three commands against the clicked one.

- (IBAction) showInFinder:(id)sender {
    [TrackCommands revealInFinder:self.playlistController.currentTrack];
}

- (IBAction) copyFile:(id)sender {
    [TrackCommands copyFile:self.playlistController.currentTrack];
}

- (IBAction) copyName:(id)sender {
    [TrackCommands copyName:self.playlistController.currentTrack];
}

#if DEBUG
- (PitchControlPanel *)pitchPanel {
    return _pitchPanel;
}

- (void)debugRefreshUI {
    [self updateUI];
}

- (NSUInteger)debugUIUpdateHz {
    return _uiTimer.hz;
}

// The rule against the live inputs, for the invariant that pairs it with the
// rate actually armed: the two diverge exactly when some path moved the width,
// duration or rate without calling syncUITimerRate.
- (NSUInteger)debugExpectedUIUpdateHz {
    return VibeUIUpdateHzForPlayhead(self.waveformView.devicePixelWidth,
                                     _currentTrackDuration,
                                     self.playbackRate,
                                     Settings.uiUpdateHzCap);
}
#endif

@end
