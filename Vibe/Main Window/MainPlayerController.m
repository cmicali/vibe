//
//  MainPlayerController.m
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "MainPlayerController.h"
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
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "PlaylistDropZoneView.h"
#import "MainWindow.h"
#import "SymbolButton.h"
#import "PitchControlPanel.h"
#import "TransportKeyMonitor.h"
#import "NowPlayingController.h"
#import "MainPlayerController+Convert.h" // convertCurrentTrackToFLAC:, for the context menu
#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerController+Transport.h" // updateFXIndicators, from the updateUI funnel
#import "UIUpdateTimer.h"
#import "AppStats.h"
#import "VibeStrings.h"

#define UPDATE_HZ 3

// The view outlets, adopted from MainPlayerContentView in
// buildContentInWindow:, and the protocol conformances are internal. Nothing
// outside this file needs them except the debug command channel and the
// split-out categories, which re-declare what they read — in
// MainPlayerController+Debug.h, MainPlayerController+Menus.m,
// MainPlayerController+NowPlaying.h and MainPlayerController+Convert.m —
// against these synthesized accessors. NSMenuItemValidation lives on the
// Menus category and NowPlayingControllerDelegate on the NowPlaying category,
// where each is implemented; MainPlayerController+Transport implements the
// skip and FX transport actions, and MainPlayerController+Convert the
// conversion funnel, swap and undo round trip.
@interface MainPlayerController () <NSWindowDelegate,
                                    NSWindowRestoration,
                                    FileDropDelegate,
                                    AudioPlayerDelegate,
                                    AudioWaveformViewDelegate,
                                    AudioWaveformCacheDelegate,
                                    AudioTrackMetadataCacheDelegate,
                                    PitchControlPanelDelegate>

// The system Now Playing bridge. The publish and command-routing code lives in
// MainPlayerController+NowPlaying, which re-declares this accessor readonly.
@property (strong) NowPlayingController *nowPlayingController;

// The header and waveform rendering surface: the labels, times, codec and BPM
// corner, and waveform states. This controller resolves the TrackDisplayState
// and hands it what to draw. +Debug.h re-declares the accessor for the state
// dump.
@property (strong) TrackDisplayController *trackDisplay;

@property (weak) SymbolButton *nextButton;
@property (weak) SymbolButton *playButton;

@property (weak) PlaylistTableView *playlistTableView;
@property (weak) MainPlayerContentView *playerContentView;
// Kept alongside trackDisplay's rendering role. The controller wires the
// view's delegate, style and appearance, the Menus category included, while
// the per-track rendering states go through trackDisplay.
@property (weak) AudioWaveformView *waveformView;

// The undo/redo settled hook MainPlayerController+Convert re-declares and
// fires; synthesized here because a category cannot synthesize storage.
@property (copy) void (^conversionUndoRedoSettledHandler)(void);

@end

@implementation MainPlayerController {
    // The occlusion-gated 3 Hz position-update timer. It drives
    // updatePlaybackUI only while playback wants updates and the window is
    // unoccluded.
    UIUpdateTimer*              _uiTimer;
    // A duration snapshot from didStartPlaying:. The live player duration
    // reads 0 while a track is Loading, and updatePlaybackUI runs in that gap.
    // It is cleared when playback goes idle, on an error or at the end of the
    // playlist.
    NSTimeInterval              _currentTrackDuration;
    __weak AudioTrack*          _lastReloadedTrack;
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
    PitchControlPanel*          _pitchPanel;
    ArtworkDisplayController*   _artworkController;
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

#pragma mark - Window construction

// The UI hierarchy lives in MainPlayerContentView. This wires it to the window
// and adopts its subviews as the controller's outlets.
- (void)buildContentInWindow:(MainWindow *)window {
    NSView *contentView = window.contentView;
    // The Liquid Glass backdrop, in the Control Center style, spanning the
    // whole window with the pitch panel included. Everything else composites
    // over it. Its corner radius matches the contentView layer mask, so the
    // glass rim lighting follows the window shape.
    NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:contentView.bounds];
    glass.cornerRadius = kMainWindowCornerRadius;
    // Clear, rather than Regular, keeps the backdrop legible as glass rather
    // than a frosted wall: more of what is behind the window shows through.
    glass.style = NSGlassEffectViewStyleClear;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:glass];
    MainPlayerContentView *content = [[MainPlayerContentView alloc] initWithTarget:self];
    self.playerContentView = content;
    [contentView addSubview:content];
    // The window already carries the restored, autosaved frame. Setting the
    // body frame here runs the subview autoresizing pass at the real size,
    // which is where the design-time frames in MainPlayerContentView stretch
    // to the user's width.
    content.frame = [self playerBodyFrame];

    self.playButton = content.playButton;
    self.nextButton = content.nextButton;
    self.waveformView = content.waveformView;
    self.playlistTableView = content.playlistTableView;

    // The header labels and the waveform's rendering states live behind the
    // track display. This controller keeps only the outlets it drives itself.
    self.trackDisplay = [[TrackDisplayController alloc] initWithContentView:content];

    // The right time label toggles between remaining and total on a click,
    // persisted in AppSettings. It uses a gesture recognizer rather than a
    // button, so the label stays a plain text field, styled with its row.
    NSClickGestureRecognizer *timeModeClick =
            [[NSClickGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(toggleTimeDisplayMode:)];
    [content.totalTimeTextField addGestureRecognizer:timeModeClick];

    // A right-click menu on the whole window body. It is on the content view,
    // so the responder chain carries it to the pitch panel too. Every item
    // acts on the current track; the Copy and Convert items share the main
    // menu's identifiers and so their validation (and the Convert retitling).
    // Menu title never drawn — a context menu shows only its items.
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Popup Menu")];
    NSMenuItem *showInFinder = [[NSMenuItem alloc] initWithTitle:STR_MENU_SHOW_IN_FINDER
                                                          action:@selector(showInFinder:)
                                                   keyEquivalent:@""];
    showInFinder.identifier = @"show_in_finder";
    showInFinder.target = self;
    showInFinder.image = [NSImage imageWithSystemSymbolName:@"folder"
                                   accessibilityDescription:showInFinder.title];
    [contextMenu addItem:showInFinder];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *copyNameItem = [[NSMenuItem alloc] initWithTitle:STR_MENU_EDIT_COPY_NAME
                                                          action:@selector(copyName:)
                                                   keyEquivalent:@""];
    copyNameItem.identifier = @"menu_edit_copy_name";
    copyNameItem.target = self;
    copyNameItem.image = [NSImage imageWithSystemSymbolName:@"textformat"
                                   accessibilityDescription:copyNameItem.title];
    [contextMenu addItem:copyNameItem];
    NSMenuItem *copyFileItem = [[NSMenuItem alloc] initWithTitle:STR_MENU_EDIT_COPY_FILE
                                                          action:@selector(copyFile:)
                                                   keyEquivalent:@""];
    copyFileItem.identifier = @"menu_edit_copy_file";
    copyFileItem.target = self;
    copyFileItem.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                                   accessibilityDescription:copyFileItem.title];
    [contextMenu addItem:copyFileItem];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *convertCurrent = [[NSMenuItem alloc] initWithTitle:STR_MENU_CONVERT_TO_FLAC
                                                            action:@selector(convertCurrentTrackToFLAC:)
                                                     keyEquivalent:@""];
    convertCurrent.identifier = @"menu_convert_to_flac";
    convertCurrent.target = self;
    convertCurrent.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath"
                                     accessibilityDescription:convertCurrent.title];
    [contextMenu addItem:convertCurrent];
    contentView.menu = contextMenu;
    // PlaylistController installs the playlist table's own row context menu,
    // which shadows this window-wide one, when the table is attached.
}

// The window's two content-view siblings, in the resizable steady state. The
// player body fills everything left of the pitch panel's fixed-width slice,
// and the panel hugs the right edge — parked just past it while hidden, which
// is exactly where widening the window will expose it. The autoresizing masks
// below reproduce both frames through a drag-resize; these compute them
// outright for the build, and after a pitch-panel toggle.
- (NSRect)playerBodyFrame {
    NSRect frame = self.window.contentView.bounds;
    if (((MainWindow *)self.window).isPitchPanelShown) {
        frame.size.width -= kPitchPanelWidth;
    }
    return frame;
}

- (NSRect)pitchPanelFrame {
    NSRect bounds = self.window.contentView.bounds;
    CGFloat x = NSMaxX(bounds) - (((MainWindow *)self.window).isPitchPanelShown ? kPitchPanelWidth : 0);
    return NSMakeRect(x, 0, kPitchPanelWidth, bounds.size.height);
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
                                                     delegate:self];
    self.metadataCache = [[AudioTrackMetadataCache alloc] init];
    self.metadataCache.delegate = self;

    // Owned here, like the metadata cache, because the waveform view is a pure
    // rendering surface. The controller requests loads and forwards the
    // deliveries: waveform snapshots to the view, BPM to the label.
    self.waveformCache = [[AudioWaveformCache alloc] init];
    self.waveformCache.delegate = self;

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
    // A double-click starts a play the controller does not see until the
    // player's async events land, which can take up to half a second on a slow
    // open. Refresh the header at initiation, so that it does not keep
    // describing the previous track after the row indicator has already moved.
    __weak MainPlayerController *weakControllerForPlaylist = self;
    self.playlistController.userDidChangeTrackHandler = ^{
        MainPlayerController *strongSelf = weakControllerForPlaylist;
        if (!strongSelf) {
            return;
        }
        // doubleClick has just fully rendered both affected rows, and the mark
        // keeps the updateUI below to the play-state cell; see next:.
        strongSelf->_lastReloadedTrack = strongSelf.playlistController.currentTrack;
        [strongSelf updateUI];
    };

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

    __weak MainPlayerController *weakSelf = self;
    _uiTimer = [[UIUpdateTimer alloc] initWithHz:UPDATE_HZ handler:^{
        [weakSelf updatePlaybackUI];
    }];

    [self.playlistTableView reloadData];
    [self updateUI];

    [NSApp activate];
}

- (void)windowWillClose:(NSNotification *)notification {
    [NSApp terminate:nil];
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

- (BOOL)isWindowVisible {
    return (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    // Revealed mid-playback, so refresh once now rather than waiting a tick.
    if (_uiTimer.wanted && [self isWindowVisible]) {
        [self updateUI];
    }
    _uiTimer.windowVisible = [self isWindowVisible];
}

// The window's own height rule, applied to drags only: the app's animated
// resizes, the playlist toggle above all, must pass through untouched, and this
// is the one place that can tell the two apart. Every height the app itself sets
// is a fixed point of the rule anyway; the gate keeps an animation's
// intermediate frames from being snapped mid-flight.
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
    if (sender.inLiveResize) {
        frameSize.height = [(MainWindow *)sender restingHeightForDraggedHeight:frameSize.height];
    }
    return frameSize;
}

// The title's shrink-to-fit depends on the width of its width-flexible label.
// Live-drag frames are skipped, so no text is measured per frame, and
// windowDidEndLiveResize: covers the drop. The inLiveResize-false path catches
// the app's own resizes, from the View > Size presets and the pitch-panel
// toggle.
- (void)windowDidResize:(NSNotification *)notification {
    if (!self.window.inLiveResize) {
        [self.trackDisplay refitTitleIfWidthChanged];
    }
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
    [self.trackDisplay refitTitleIfWidthChanged];
}

// The display state the header should render, resolved here in one place.
// updateUI, updatePlaybackUI and the Now Playing publish all read this same
// resolution rather than re-deriving it from the underlying flags. The
// rendering itself lives in TrackDisplayController.
// The decision itself is VibeResolveTrackDisplayState, in
// TrackDisplayController.h beside the enum it returns; this gathers its
// inputs. Sampling isStopped once rather than per-branch also resolves the
// whole state against one consistent view of the player.
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

// The 3 Hz tick, and the refresh after a seek or a rate change. It uses the
// cached duration rather than the live one, because the live duration reads 0
// in the Loading gap, and the cache keeps the waveform progress pinned rather
// than frozen.
- (void)updatePlaybackUI {
    [self.trackDisplay renderPosition:self.audioPlayer.position
                             duration:_currentTrackDuration
                                 rate:self.playbackRate
                                state:[self displayState]];
}

// Every effective-tempo change — a track change, a BPM delivery, a fader tick
// — funnels through here, so that both consumers see it: the delay echo's
// BPM-synced taps and the BPM label. The fx write is unconditional, because
// the label's 0.1 BPM granularity is coarser than the fader's and must not
// gate the audio parameter. The setter no-ops on the same value.
- (void)effectiveTempoDidChange {
    AudioTrack *track = [self displayedTrack];
    float baseBPM = track.bpm;
    float scaledBPM = baseBPM > 0 ? baseBPM * self.playbackRate : 0;
    self.audioPlayer.fx.delayTapBPM = scaledBPM;
    // The label shows the same pitch-scaled value, and no track clears it.
    [self.trackDisplay renderBPM:(track ? scaledBPM : 0)];
}

- (IBAction)playPause:(nullable id)sender {
    if (self.audioPlayer.isStopped) {
        [self.playlistController play];
    }
    else {
        [self.audioPlayer playPause];
    }
}

- (void)playURL:(NSURL *)url {
    [self play:@[url]];
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
// The only writers of their ivar pairs; see the ivar comments.

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
    [self.playlistController next];
    // next has just fully rendered the outgoing and incoming rows. Without the
    // mark, the updateUI below would rebuild the incoming row a second time.
    _lastReloadedTrack = self.playlistController.currentTrack;
    [self updateUI];
}

- (IBAction)previous:(nullable id)sender {
    [self.playlistController previous];
    _lastReloadedTrack = self.playlistController.currentTrack; // see next:
    [self updateUI];
}

// The relative-seek skips and the FX pass-throughs live in
// MainPlayerController+Transport.

- (IBAction)closeApp:(id)sender {
    [self close];
}

- (IBAction)minimizeWindow:(id)sender {
    [self.window miniaturize:sender];
}

- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *> *)urls
        atLocation:(NSPoint)location {
    switch ([self.playerContentView.playlistDropZoneView dropActionForWindowPoint:location]) {
        case PlaylistDropWellActionAdd:
            // Appends without touching playback. An empty playlist routes to
            // play: inside, since with nothing to append to, replace and add
            // coincide.
            [self addURLs:urls];
            break;
        case PlaylistDropWellActionReplace:
        case PlaylistDropWellActionNone: // outside the wells: the window-wide default
            [self play:urls];
            break;
    }
}

// The window's drag-over events, forwarded to the drop zone's wells. The view
// no-ops while hidden or collapsed.
- (void)mainWindow:(MainWindow *)mainWindow fileDraggingUpdatedAtLocation:(NSPoint)location {
    [self.playerContentView.playlistDropZoneView fileDragUpdatedAtWindowPoint:location];
}

- (void)mainWindowFileDraggingEnded:(MainWindow *)mainWindow {
    [self.playerContentView.playlistDropZoneView fileDragEnded];
}

#pragma mark - AudioPlayerDelegate Implementation

- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track {
    [self clearErrorMask];
    // A slow cloud open is in flight, and the header can still show cached
    // tags and art for the pending track while it materializes. It is guarded
    // like didStartPlaying:'s check: a stale delivery from a superseded open
    // must not load for a track the playlist no longer points at.
    if (track == [self.playlistController currentTrack]) {
        [self.metadataCache loadMetadataNow:track];
    }
    // Show the pending track's title and artist while it loads.
    [self updateUI];
    [self.trackDisplay showWaveformLoadingIndicator];
    // This runs after updateUI, which shows the pending track's art if it is
    // already resolved: the previous track's art must not outlive the shimmer.
    [_artworkController showPlaceholderForSlowLoad];
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
    [_artworkController trackDidStartPlaying:track];
    [self clearErrorMask];
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
    [self.audioPlayer prefetchTrack:[self.playlistController trackAtIndex:self.playlistController.currentIndex + 1]];
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
    [[AppStats sharedInstance] playbackStopped];
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
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
        return;
    }
    // Folds the finished run. Deliberately after the stale guard: in the stale
    // case the replacing track is already playing, and its own didStartPlaying:
    // restarts the clock, so stopping here would drop listening time.
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

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain] && error.code == VibeAudioErrorNotPlaying) {
        // A play-pause toggle raced a track ending, or nothing is loaded. It
        // is harmless, so ignore it silently rather than popping a modal alert.
        return;
    }
    LogError(@"%@", error.localizedDescription);
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
    [self startPendingMetadataLoad];
    [[AppStats sharedInstance] playbackStopped];
    [self pauseUIUpdateTimer];
    // Playback failed, so the duration cached at the last didStartPlaying no
    // longer describes anything the player holds.
    _currentTrackDuration = 0;
    [self.trackDisplay hideWaveformLoadingIndicator];
    // Errors present inline, with no modal and no auto-skip. A sheet on this
    // borderless window breaks key status and the bare transport keys. The
    // header shows the error state, the track stays in the playlist for a
    // retry, and the errored mark stops late metadata and art deliveries from
    // repopulating the header.
    [self setErrorMaskForTrack:self.playlistController.currentTrack
                        status:[MainPlayerController statusForPlayError:error]];
    [self updateUI];
}

// The artist-line status for the inline error rendering. It is deliberately
// short: the title line already names the track, and the full error text is in
// the log.
+ (NSString *)statusForPlayError:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]) {
        switch ((VibeAudioErrorCode)error.code) {
            case VibeAudioErrorFileOpenTimedOut:
                return STR_ERROR_LOAD_TIMEOUT;
            case VibeAudioErrorFileOpenFailed:
                return STR_ERROR_OPEN_FAILED;
            case VibeAudioErrorEngineStartFailed:
                return STR_ERROR_ENGINE_START_FAILED;
            case VibeAudioErrorDeviceUnavailable:
                return STR_ERROR_DEVICE_UNAVAILABLE;
            case VibeAudioErrorNotPlaying:
                break; // never reaches here (filtered above)
        }
    }
    return STR_ERROR_PLAYBACK_GENERIC;
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
    [self updatePlaybackUI];
    // The playhead jumped, so resync Control Center's elapsed time.
    [self updateNowPlaying];
}

#pragma mark - Metadata and Waveform

- (void)didLoadMetadata:(AudioTrack *)track {
    if ([self.playlistController isCurrentTrack:track]) {
        _lastReloadedTrack = nil;
        [self updateUI];
    }
    else {
        [self.playlistController reloadTrack:track];
    }
}

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage {
    [self.audioPlayer seekToPosition:self.audioPlayer.duration * percentage];
}

// The progressive snapshots and the final waveform, on the main thread. The
// view simply renders what it is handed, and the cache has already filtered
// out cancelled loads.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    [self.trackDisplay showWaveform:waveform];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url {
    // A delivery usually belongs to the current track, but a late one can land
    // after next: has advanced the playlist. The BPM is valid for whichever
    // track owns that URL, so stamp that track, and refresh the label only
    // when the stamped track is the one it shows.
    AudioTrack *track = [self.playlistController trackForURL:url];
    if (!track) {
        return;
    }
    track.detectedBPM = bpm;
    if ([self.playlistController isCurrentTrack:track]) {
        [self effectiveTempoDidChange];
    }
}

#pragma mark - Actions

- (IBAction) setSmallSize:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    [window setSmallSize:YES];
}

- (IBAction) setLargeSize:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    [window setLargeSize:YES];
}

- (IBAction) toggleSize:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    [window toggleSize:sender];
}

// View > Size. The presets set body widths only: the height belongs to the
// playlist toggle and the user's drag, and the collapsed layout's header band
// is a fixed design height with nothing to scale. It dispatches on the menu
// identifier, as setAppearance: and setPitchRange: do.
+ (CGFloat)contentWidthForSizeIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:@"view_size_small"]) {
        return kMainWindowMinContentWidth;
    }
    if ([identifier isEqualToString:@"view_size_large"]) {
        return kMainWindowLargeContentWidth;
    }
    return kMainWindowContentWidth;
}

- (IBAction) setWindowSize:(id)sender {
    if (![sender isKindOfClass:[NSMenuItem class]]) {
        return;
    }
    MainWindow *window = (MainWindow *)self.window;
    [window setContentWidth:[MainPlayerController contentWidthForSizeIdentifier:((NSMenuItem *)sender).identifier]
                    animate:YES];
}

- (IBAction) togglePitchPanel:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    BOOL show = !window.isPitchPanelShown;
    if (show) {
        // Sync the fader with the player before the reveal; it is cheap either
        // way.
        _pitchPanel.pitch = self.audioPlayer.pitch;
    }
    // The reveal, and its reverse, is the window's right edge sweeping past a
    // stationary panel, so both siblings are pinned in window coordinates for
    // the duration of the animation. The resizable-width masks would drag them
    // along with the edge instead: the body would shrink and re-grow, and the
    // panel would slide in from over the body rather than being uncovered.
    MainPlayerContentView *body = self.playerContentView;
    NSAutoresizingMaskOptions bodyMask = body.autoresizingMask;
    NSAutoresizingMaskOptions panelMask = _pitchPanel.autoresizingMask;
    body.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    _pitchPanel.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
    [window setPitchPanelShown:show animate:YES];
    body.autoresizingMask = bodyMask;
    _pitchPanel.autoresizingMask = panelMask;
    // Re-assert the landing frames. A width clamped by the floor leaves the
    // frozen frames a few points off the finished window.
    body.frame = [self playerBodyFrame];
    _pitchPanel.frame = [self pitchPanelFrame];
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
    [self updatePlaybackUI];
}

- (void)pitchControlPanel:(PitchControlPanel *)panel didChangePitch:(float)pitch {
    self.audioPlayer.pitch = pitch;
    // The time labels scale with the rate, so refresh immediately: the 3 Hz
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

- (IBAction) showInFinder:(id)sender {
    NSURL *url = self.playlistController.currentTrack.url;
    if (url) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
    }
}

// The file URL itself goes on the pasteboard, so a Finder paste duplicates
// the file.
- (IBAction) copyFile:(id)sender {
    NSURL *url = self.playlistController.currentTrack.url;
    if (url) {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard writeObjects:@[url]];
    }
}

- (IBAction) copyName:(id)sender {
    NSString *name = self.playlistController.currentTrack.singleLineTitle;
    if (name.length) {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard writeObjects:@[name]];
    }
}

- (IBAction) setAppearance:(id)sender {
    if([sender isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = sender;
        if ([item.identifier isEqualToString:@"view_appearance_light"]) {
            Settings.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT;
        }
        else if ([item.identifier isEqualToString:@"view_appearance_dark"]) {
            Settings.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK;
        }
        else {
            Settings.windowAppearanceStyle = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT;
        }
    }
    self.window.appearance = Settings.windowAppearance;
    [self.playlistController reloadCurrentTrack];
}

#if DEBUG
- (PitchControlPanel *)pitchPanel {
    return _pitchPanel;
}

- (void)debugRefreshUI {
    [self updateUI];
}
#endif

+ (void)restoreWindowWithIdentifier:(NSString *)identifier
                              state:(NSCoder *)state
                  completionHandler:(void (^)(NSWindow *, NSError *))completionHandler {
    NSWindow *window = nil;
    if ([identifier isEqualToString:@"main_window"]) {
        AppDelegate *appDelegate = [NSApp delegate];
        window = appDelegate.mainPlayerController.window;
    }
    completionHandler(window, nil);
}

@end
