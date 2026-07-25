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
#import "ArtworkImageView.h"
#import "AudioDeviceManager.h"
#import "MainPlayerContentView.h"
#import "AudioPlayer.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformView.h"
#import "PlaylistManager.h"
#import "MainWindow.h"
#import "GlyphButton.h"
#import "PitchControlPanel.h"
#import "TransportKeyMonitor.h"
#import "NowPlayingController.h"
#import "MainPlayerController+NowPlaying.h"
#import "UIUpdateTimer.h"

#define UPDATE_HZ 3

// View outlets (adopted from MainPlayerContentView in buildContentInWindow:)
// and protocol conformances are internal: nothing outside this file needs
// them except the debug command channel and the split-out categories, which
// re-declare what they read (MainPlayerController+Debug.h /
// MainPlayerController+Menus.m / MainPlayerController+NowPlaying.h) against
// these synthesized accessors. NSMenuItemValidation lives on the Menus
// category and NowPlayingControllerDelegate on the NowPlaying category, where
// they are implemented; the skip/FX transport actions are implemented in
// MainPlayerController+Transport.
@interface MainPlayerController () <NSWindowDelegate,
                                    NSWindowRestoration,
                                    FileDropDelegate,
                                    AudioPlayerDelegate,
                                    AudioWaveformViewDelegate,
                                    AudioWaveformCacheDelegate,
                                    AudioTrackMetadataCacheDelegate,
                                    PitchControlPanelDelegate>

// The system Now Playing bridge; the publish/command-routing code lives in
// MainPlayerController+NowPlaying, which re-declares this accessor readonly.
@property (strong) NowPlayingController *nowPlayingController;

// The header/waveform rendering surface (labels, times, codec/BPM corner,
// waveform states). This controller resolves the TrackDisplayState and hands
// it what to draw; +Debug.h re-declares the accessor for the state dump.
@property (strong) TrackDisplayController *trackDisplay;

@property (weak) GlyphButton *nextButton;
@property (weak) GlyphButton *playButton;
@property (weak) GlyphButton *closeButton;

@property (weak) NSTableView *playlistTableView;
@property (weak) ArtworkImageView *albumArtImageView;
@property (weak) NSView *headerTintView;
@property (weak) MainPlayerContentView *playerContentView;
// Kept alongside trackDisplay's rendering role: the controller wires the
// view's delegate/style and appearance (Menus category included); the
// per-track rendering states go through trackDisplay.
@property (weak) AudioWaveformView *waveformView;

@end

@implementation MainPlayerController {
    // The occlusion-gated 3 Hz position-update timer; drives updatePlaybackUI
    // only while playback wants updates AND the window is unoccluded.
    UIUpdateTimer*              _uiTimer;
    // Duration snapshot from didStartPlaying: the live player duration reads
    // 0 while a track is Loading, and updatePlaybackUI runs in that gap.
    // Cleared when playback goes idle (error, end of playlist).
    NSTimeInterval              _currentTrackDuration;
    __weak AudioTrack*          _lastReloadedTrack;
    // The error mask: the track whose play attempt failed, plus the short
    // status for the error rendering's artist line (full error text goes to
    // the log). While that track is still current and the player is stopped,
    // the header renders the error state and ignores the track — including
    // late metadata/art deliveries. Weak: the track stays in the playlist
    // for retry, and replacing the playlist dissolves the mark. Written only
    // by setErrorMaskForTrack:status: / clearErrorMask.
    __weak AudioTrack*          _erroredTrack;
    NSString*                   _errorStatus;
    // Launch grace (see revealEmptyState in the header): while YES the empty
    // state renders as a blank header. Never set again once cleared.
    BOOL                        _emptyStateSuppressed;
    // The deferred playlist-wide metadata load (see play:). The generation
    // pairs each play:'s 2s fallback timer with its own playlist: a timer
    // armed by playlist A firing after a re-drop must not start playlist B's
    // load while B's first track is still opening. Written only by
    // scheduleDeferredMetadataLoad / cancelDeferredMetadataLoad /
    // startPendingMetadataLoad.
    BOOL                        _metadataLoadPending;
    NSUInteger                  _metadataLoadGeneration;
    TransportKeyMonitor*        _keyMonitor;
    PitchControlPanel*          _pitchPanel;
    ArtworkDisplayController*   _artworkController;
}

- (id) init {
    // Programmatic window (no nib). initWithWindow: marks the controller as
    // already loaded (even an overridden loadWindow would never run), so the
    // window is built here and windowDidLoad — which AppKit only fires on the
    // nib path — is invoked directly.
    MainWindow *window = [[MainWindow alloc] init];
    if((self = [super initWithWindow:window])) {
        // Set before the first updateUI so the launch grace covers the very
        // first render.
        _emptyStateSuppressed = YES;
        // windowDidLoad hands this the audio player, so it must exist first.
        self.devicesMenuController = [[OutputDevicesMenuController alloc] init];
        [self buildContentInWindow:window];
        [self windowDidLoad];
    }
    return self;
}

#pragma mark - Window construction

// The UI hierarchy lives in MainPlayerContentView; this wires it to the
// window and adopts its subviews as the controller's outlets.
- (void)buildContentInWindow:(MainWindow *)window {
    NSView *contentView = window.contentView;
    // Liquid Glass backdrop (Control Center-style) spanning the whole window,
    // pitch panel included — everything else composites over it. Its corner
    // radius matches the contentView layer mask so the glass rim lighting
    // follows the window shape.
    NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:contentView.bounds];
    glass.cornerRadius = kMainWindowCornerRadius;
    // Clear (vs Regular) keeps the backdrop legible as glass rather than a
    // frosted wall — more of what's behind the window shows through.
    glass.style = NSGlassEffectViewStyleClear;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [contentView addSubview:glass];
    MainPlayerContentView *content = [[MainPlayerContentView alloc] initWithTarget:self];
    self.playerContentView = content;
    [contentView addSubview:content];
    // The window already carries the restored (autosaved) frame; setting the
    // content frame here runs the subview autoresizing pass at the real size.
    // Width stays pinned at the content width — when the pitch panel state
    // restored as shown, the window is already kPitchPanelWidth wider than
    // the content.
    NSRect contentFrame = contentView.bounds;
    contentFrame.size.width = kMainWindowContentWidth;
    content.frame = contentFrame;

    self.closeButton = content.closeButton;
    self.playButton = content.playButton;
    self.nextButton = content.nextButton;
    self.headerTintView = content.headerTintView;
    self.albumArtImageView = content.albumArtImageView;
    self.waveformView = content.waveformView;
    self.playlistTableView = content.playlistTableView;

    // The header labels and the waveform's rendering states live behind the
    // track display; this controller keeps only the outlets it drives itself.
    self.trackDisplay = [[TrackDisplayController alloc] initWithContentView:content];

    // Right-click menu on the whole window body (content view, so it also
    // covers the pitch panel via the responder chain).
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Popup Menu"];
    NSMenuItem *showInFinder = [[NSMenuItem alloc] initWithTitle:@"Show in Finder"
                                                          action:@selector(showInFinder:)
                                                   keyEquivalent:@""];
    showInFinder.identifier = @"show_in_finder";
    showInFinder.target = self;
    [contextMenu addItem:showInFinder];
    contentView.menu = contextMenu;

    // The playlist table gets its own menu (shadowing the window-wide one
    // above) so a right-click on a row reveals THAT row's track, not the
    // current track.
    NSMenu *playlistMenu = [[NSMenu alloc] initWithTitle:@"Playlist Menu"];
    NSMenuItem *showRowInFinder = [[NSMenuItem alloc] initWithTitle:@"Show in Finder"
                                                             action:@selector(showClickedTrackInFinder:)
                                                      keyEquivalent:@""];
    showRowInFinder.identifier = @"show_clicked_track_in_finder";
    showRowInFinder.target = self;
    [playlistMenu addItem:showRowInFinder];
    self.playlistTableView.menu = playlistMenu;
}

- (void)windowDidLoad {

    // Closing the player means quitting: without this, closing the main
    // window while the About window is open leaves the app running with no
    // way to get the player back (applicationShouldTerminateAfterLastWindowClosed
    // never fires because About still counts as a window).
    self.window.delegate = self;

    // The saved device (UID first, name fallback) is resolved inside
    // AudioPlayer's async init on its own queue: resolution enumerates
    // CoreAudio devices — per-device HAL property reads, tens of ms with
    // Bluetooth devices present — and this method runs before first paint.
    self.audioPlayer = [[AudioPlayer alloc] initWithDeviceUID:Settings.audioOutputDeviceUID
                                                         name:Settings.audioOutputDeviceName
                                                     delegate:self];
    self.metadataCache = [[AudioTrackMetadataCache alloc] init];
    self.metadataCache.delegate = self;

    // Owned here, like the metadata cache — the waveform view is a pure
    // rendering surface; the controller requests loads and forwards the
    // deliveries (waveform snapshots to the view, BPM to the label).
    self.waveformCache = [[AudioWaveformCache alloc] init];
    self.waveformCache.delegate = self;

    self.playlistManager = [[PlaylistManager alloc] initWithAudioPlayer:self.audioPlayer];
    self.playlistManager.tableView = self.playlistTableView;
    // A double-click starts a play the controller never sees until the
    // player's async events land (up to 0.5 s for a slow open) — refresh the
    // header at initiation so it doesn't keep describing the previous track
    // after the row indicator has already moved.
    __weak MainPlayerController *weakControllerForPlaylist = self;
    self.playlistManager.userDidChangeTrackHandler = ^{
        MainPlayerController *strongSelf = weakControllerForPlaylist;
        if (!strongSelf) {
            return;
        }
        // doubleClick just fully rendered both affected rows; the mark keeps
        // the updateUI below to the play-state cell (see next:).
        strongSelf->_lastReloadedTrack = strongSelf.playlistManager.currentTrack;
        [strongSelf updateUI];
    };

    _artworkController = [[ArtworkDisplayController alloc] initWithArtworkView:self.albumArtImageView
                                                               headerTintView:self.headerTintView];
    __weak MainPlayerController *weakControllerForArt = self;
    _artworkController.currentTrackProvider = ^AudioTrack *{
        return weakControllerForArt.playlistManager.currentTrack;
    };
    _artworkController.artDidResolveHandler = ^{
        [weakControllerForArt updateUI];
    };
    // The header art tint is appearance-dependent (dark wash vs light
    // pastel); re-derive it whenever the window's appearance flips.
    self.playerContentView.appearanceChangedHandler = ^{
        MainPlayerController *strongSelf = weakControllerForArt;
        if (strongSelf) {
            [strongSelf->_artworkController refreshHeaderTint];
        }
    };

    self.devicesMenuController.audioPlayer = self.audioPlayer;

    // Wire the collaborators to the views (all appearance/layout is applied
    // by MainPlayerContentView at construction).

    self.window.appearance = Settings.windowAppearance;

    self.waveformView.delegate = self;
    self.waveformView.waveformStyle = Settings.waveformStyle;

    self.playlistTableView.delegate = self.playlistManager;
    self.playlistTableView.dataSource = self.playlistManager;

    // Bare transport keys via a local event monitor — see TransportKeyMonitor
    // for the key list and why the menu key-equivalent path can't be trusted
    // for unmodified keys.
    _keyMonitor = [[TransportKeyMonitor alloc] initWithController:self];

    // System media keys / Control Center / Bluetooth transport controls. Its
    // now-playing info is published from updateNowPlaying (called out of the
    // updateUI funnel); registering the command handlers now lets the media
    // keys route to us as soon as the first track starts playing.
    self.nowPlayingController = [[NowPlayingController alloc] initWithDelegate:self];

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;

    // Built here rather than in MainPlayerContentView: the panel must be a
    // SIBLING of the content view (which is pinned at the design width), not
    // a child — it's revealed by widening the window past the content, and
    // its height comes from the window's restored frame, not the design size.
    // Parked just past the content's right edge (togglePitchPanel:). Fixed
    // left offset + flexible right margin keeps it there through width
    // changes; heightSizable tracks the small/large layout toggle.
    // Anchored at the content width, NOT the current bounds edge: when the
    // panel-open state was restored from the autosave the window is already
    // kPitchPanelWidth wider than the content.
    NSView *contentView = self.window.contentView;
    _pitchPanel = [[PitchControlPanel alloc] initWithFrame:
            NSMakeRect(kMainWindowContentWidth, 0, kPitchPanelWidth, contentView.bounds.size.height)];
    _pitchPanel.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
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
    // Refresh the visibility gate from the live occlusion state at each
    // resume — the timer only hears about changes via the occlusion
    // notification, and playback can start before the first one fires.
    _uiTimer.windowVisible = [self isWindowVisible];
    _uiTimer.wanted = YES;
}

- (BOOL)isWindowVisible {
    return (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    // Revealed mid-playback: refresh once now rather than waiting for a tick.
    if (_uiTimer.wanted && [self isWindowVisible]) {
        [self updateUI];
    }
    _uiTimer.windowVisible = [self isWindowVisible];
}

// The display state the header should render, resolved here in one place —
// updateUI, updatePlaybackUI, and the Now Playing publish all read this
// same resolution instead of re-deriving it from the underlying flags
// (rendering itself lives in TrackDisplayController).
- (TrackDisplayState)displayState {
    AudioTrack *track = self.playlistManager.currentTrack;
    if (!track) {
        // Launch grace: a launch-time open may still be resolving — render a
        // blank header instead of flashing the empty state.
        return _emptyStateSuppressed ? TrackDisplayStateLaunchGrace : TrackDisplayStateEmpty;
    }
    // The error mask is gated on isStopped so a retry's Loading/Playing state
    // instantly lifts it.
    if (track == _erroredTrack && self.audioPlayer.isStopped) {
        return TrackDisplayStateError;
    }
    // A just-initiated track change is still queued on the player's serial
    // queue: the player's currentTrack — and its position/duration — still
    // describe the PREVIOUS file (currentTrack flips to the new track only at
    // didStartPlaying). Render the gap as Loading so the new track's tags are
    // never composited over the old file's times; visible on slow (cloud)
    // opens, instant on prefetched ones. Stopped is excluded: an idle player
    // at end of playlist legitimately parks with the playlist's last track.
    if (!self.audioPlayer.isStopped && self.audioPlayer.currentTrack != track) {
        return TrackDisplayStateLoading;
    }
    return self.audioPlayer.isLoading ? TrackDisplayStateLoading : TrackDisplayStateTrack;
}

// The track the header should describe: the playlist's current track, or nil
// while the empty/error state is up.
- (AudioTrack *)displayedTrack {
    switch ([self displayState]) {
        case TrackDisplayStateTrack:
        case TrackDisplayStateLoading:
            return self.playlistManager.currentTrack;
        case TrackDisplayStateEmpty:
        case TrackDisplayStateLaunchGrace:
        case TrackDisplayStateError:
            return nil;
    }
}

- (void)updateUI {

    TrackDisplayState state = [self displayState];
    AudioTrack *track = self.playlistManager.currentTrack;
    // The masking rule lives in displayedTrack — don't re-derive it here.
    // track is still used deliberately below: the error rendering titles the
    // masked track, and the play-button glyph follows the playlist.
    AudioTrack *displayTrack = [self displayedTrack];

    // The track check covers Close: the player's stop is async on its queue,
    // so it can still read isPlaying for the instant after closeFile: — and no
    // later updateUI would fix the glyph (the update timer is paused).
    self.playButton.glyph = (track && self.audioPlayer.isPlaying) ? GlyphButtonGlyphPause : GlyphButtonGlyphPlay;

    self.playButton.enabled = self.playlistManager.count > 0;
    self.nextButton.enabled = self.playlistManager.hasNextTrack;

    // Error state passes the masked (errored) track — its title renders under
    // the error status; the other states describe displayTrack (nil when
    // empty).
    [self.trackDisplay renderState:state
                             track:(state == TrackDisplayStateError ? track : displayTrack)
                          duration:self.audioPlayer.duration
                              rate:self.playbackRate
                       errorStatus:_errorStatus];

    self.albumArtImageView.fileURL = displayTrack.url;

    [self effectiveTempoDidChange];

    [_artworkController updateForTrack:displayTrack];

    if (displayTrack && displayTrack == _lastReloadedTrack) {
        // Same track as last time: only the play/pause indicator can have
        // changed in the playlist row.
        [self.playlistManager reloadCurrentTrackPlayState];
    }
    else {
        [self.playlistManager reloadCurrentTrack];
        _lastReloadedTrack = displayTrack;
    }
    [self updatePlaybackUI];
    [self updateNowPlaying];
}

// Varispeed rate: the track plays this much faster/slower than file time, so
// the time labels show file time divided by it (the wall-clock time a DJ
// counting bars actually experiences). The waveform progress is a ratio and
// needs no scaling.
- (double)playbackRate {
    return 1.0 + self.audioPlayer.pitch / 100.0;
}

// The 3 Hz tick (and the post-seek / rate-change refresh). The cached
// duration, not the live one: the live duration reads 0 in the Loading gap,
// and the cache keeps the waveform progress pinned instead of frozen.
- (void)updatePlaybackUI {
    [self.trackDisplay renderPosition:self.audioPlayer.position
                             duration:_currentTrackDuration
                                 rate:self.playbackRate
                                state:[self displayState]];
}

- (IBAction)playPause:(nullable id)sender {
    if (self.audioPlayer.isStopped) {
        [self.playlistManager play];
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
    [self.playlistManager play:urls];
    // Defer the playlist-wide metadata load until playback has actually
    // started: four workers reading every file can starve the player's own
    // file open on slow disks, delaying first sound by seconds. The fallback
    // covers the case where playback never starts (bad file, device error).
    [self scheduleDeferredMetadataLoad];
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    if (self.playlistManager.count == 0) {
        [self play:urls]; // nothing to append to — this IS the play
        return;
    }
    [self.playlistManager append:urls];
    // A still-pending deferred sweep reads the playlist when it fires; once it
    // has started, re-queue the whole list (already-parsed tracks are skipped).
    if (!_metadataLoadPending) {
        [self.metadataCache loadMetadata:self.playlistManager.playlist];
    }
    // The current track may have gained a successor: refresh the parked handle
    // and the Next button/menu state.
    [self.audioPlayer prefetchTrack:[self.playlistManager trackAtIndex:self.playlistManager.currentIndex + 1]];
    [self updateUI];
}

#pragma mark - Deferred metadata load / error mask
// The only writers of their ivar pairs — see the ivar comments.

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
    [self.metadataCache loadMetadata:self.playlistManager.playlist];
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
// player's stop sends no delegate callback (so nothing auto-advances), and an
// end-of-track callback already in flight is dropped by didFinishPlaying:'s
// stale-track guard.
- (IBAction)closeFile:(nullable id)sender {
    [self.audioPlayer stop];
    [self.audioPlayer prefetchTrack:nil]; // drop the parked next-track handle
    [self.waveformCache cancelLoad];
    [self.playlistManager clear];
    // Cancel the deferred playlist-wide metadata load — nothing will play to
    // start it later — and release the scan loader (see cancelAll).
    [self cancelDeferredMetadataLoad];
    [self.metadataCache cancelAll];
    [self clearErrorMask];
    _emptyStateSuppressed = NO; // Close explicitly asks for the empty state
    _currentTrackDuration = 0;
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (IBAction)next:(nullable id)sender {
    [self.playlistManager next];
    // next just fully rendered the outgoing and incoming rows; without the
    // mark, the updateUI below would rebuild the incoming row a second time.
    _lastReloadedTrack = self.playlistManager.currentTrack;
    [self updateUI];
}

- (IBAction)previous:(nullable id)sender {
    [self.playlistManager previous];
    _lastReloadedTrack = self.playlistManager.currentTrack; // see next:
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

- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *> *)urls {
    [self play:urls];
}

#pragma mark - AudioPlayerDelegate Implementation

// Every effective-tempo change (track change, BPM delivery, fader tick)
// funnels through here so both consumers see it: the delay echo's BPM-synced
// taps and the BPM label. The fx write is unconditional — the label's 0.1 BPM
// granularity is coarser than the fader's, so it must not gate the audio
// parameter (the setter no-ops on same value).
- (void)effectiveTempoDidChange {
    AudioTrack *track = [self displayedTrack];
    // Tagged tempo wins over the analyzed one — same precedence as the skips.
    float baseBPM = track.metadata.bpm > 0 ? track.metadata.bpm : track.detectedBPM;
    float scaledBPM = baseBPM > 0 ? baseBPM * self.playbackRate : 0;
    self.audioPlayer.fx.delayTapBPM = scaledBPM;
    // The label shows the same pitch-scaled value; no track clears it.
    [self.trackDisplay renderBPM:(track ? scaledBPM : 0)];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track {
    [self clearErrorMask];
    // A slow (cloud) open is in flight — the header can still show cached
    // tags/art for the pending track while it materializes. Guarded like
    // didStartPlaying:'s check: a stale delivery from a superseded open must
    // not load for a track the playlist no longer points at.
    if (track == [self.playlistManager currentTrack]) {
        [self.metadataCache loadMetadataNow:track];
    }
    // Show the pending track's title/artist while it loads.
    [self updateUI];
    [self.trackDisplay showWaveformLoadingIndicator];
    // After updateUI (which shows the pending track's art if it's already
    // resolved): the previous track's art must not outlive the shimmer.
    [_artworkController showPlaceholderForSlowLoad];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track  {
    // Stale start from a just-replaced playlist (re-drop while the old play's
    // open was in flight): do nothing — acting would reset the NEW track's
    // shimmer/waveform view, kick a wasted decode+prefetch for the old one,
    // and cache the wrong duration. The new play's own events drive the UI
    // from here.
    if (track != [self.playlistManager currentTrack]) {
        return;
    }
    [_artworkController trackDidStartPlaying:track];
    [self clearErrorMask];
    [self.trackDisplay hideWaveformLoadingIndicator];
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:track.url];
    // The now-playing track jumps the scan queue: its header tags/art must
    // not wait behind the playlist sweep (a cloud-heavy folder keeps every
    // scan worker blocked for minutes). Runs even when didBeginLoading:
    // already asked — that call skips the parse while the file is a dataless
    // placeholder; by now the open has materialized it.
    [self.metadataCache loadMetadataNow:track];
    [self startPendingMetadataLoad];
    _currentTrackDuration = self.audioPlayer.duration;
    [self.trackDisplay prepareForWaveformLoad];
    [self.waveformCache loadWaveformForTrack:track];
    // Pre-open the likely-next file so auto-advance and Next skip the file
    // open — the dominant transition latency. Recomputed on every track start
    // (next/previous, double-click, re-drop all land here); nil past the last
    // track drops the parked handle.
    [self.audioPlayer prefetchTrack:[self.playlistManager trackAtIndex:self.playlistManager.currentIndex + 1]];
    // Whoever initiated this play already fully rendered the row (play:'s
    // reloadData, next/previous's two-row window, doubleClick's pair); the
    // mark makes resumeUIUpdateTimer -> updateUI refresh only the play-state
    // cell (the equalizer indicator must flip to animating) instead of
    // rebuilding the whole row again.
    _lastReloadedTrack = track;
    // next/previous scroll at the click; this covers the other play paths.
    [self.playlistManager scrollCurrentTrackToVisible];
    [self resumeUIUpdateTimer];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    // A device-loss error can mask a track the player merely parked as Paused
    // (see audioPlayer:error:); resuming proves the mask wrong.
    [self clearErrorMask];
    [self resumeUIUpdateTimer];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    // A natural-end callback can be delivered just as the user replaces the
    // playlist or double-clicks a new row. Only auto-advance if the finished
    // track is still the playlist's current one, otherwise we'd skip past the
    // track the user just chose.
    if (track && track != [self.playlistManager currentTrack]) {
        return;
    }
    [self pauseUIUpdateTimer];
    // End of playlist must be read from the playlist BEFORE next: — the play
    // it starts is async on the player queue, so the player still reads
    // Stopped right after an ordinary mid-playlist advance.
    BOOL hasNextTrack = self.playlistManager.hasNextTrack;
    [self next:self];
    // End of playlist (next: started nothing): the cached duration would go
    // stale against the idle player. Mid-playlist the cache must survive the
    // Loading gap — the live duration reads 0 there, and updatePlaybackUI
    // uses the cache to keep the waveform progress pinned instead of frozen.
    if (!hasNextTrack) {
        _currentTrackDuration = 0;
        // Pin the resting header deterministically: the updateUI inside next:
        // read the player mid-teardown (its position/duration race the async
        // stop), which could leave the waveform pinned at 100% while the
        // elapsed label read 0:00. Park the finished track at its start.
        [self.trackDisplay resetPlayheadToStart];
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain] && error.code == VibeAudioErrorNotPlaying) {
        // A play/pause toggle raced a track ending (or nothing is loaded).
        // Harmless — ignore silently rather than popping a modal alert.
        return;
    }
    LogError(@"%@", error.localizedDescription);
    // Only a Stopped player takes the play-failure path below. This is both
    // the staleness guard (play-path errors are published Stopped before
    // delivery, so a stale error after a re-drop reads Loading/Playing) and
    // the exclusion of device-loss errors for a track merely PARKED as Paused
    // — masking a resumable track would render a false error screen later,
    // and zeroing the duration cache would freeze the waveform progress after
    // recovery. The park's didPausePlaying handles the UI; resume lifts any
    // mask.
    if (!self.audioPlayer.isStopped) {
        [self updateUI];
        return;
    }
    [self startPendingMetadataLoad];
    [self pauseUIUpdateTimer];
    // Playback failed — the duration cached at the last didStartPlaying no
    // longer describes anything the player holds.
    _currentTrackDuration = 0;
    [self.trackDisplay hideWaveformLoadingIndicator];
    // Errors present inline: no modal (a sheet on this borderless window
    // breaks key status and the bare transport keys), no auto-skip. The
    // header shows the error state, the track stays in the playlist for
    // retry, and the errored mark keeps late metadata/art deliveries from
    // repopulating the header.
    [self setErrorMaskForTrack:self.playlistManager.currentTrack
                        status:[MainPlayerController statusForPlayError:error]];
    [self updateUI];
}

// Artist-line status for the inline error rendering. Deliberately short —
// the title line already names the track, and the full error text is in the
// log.
+ (NSString *)statusForPlayError:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain]) {
        switch ((VibeAudioErrorCode)error.code) {
            case VibeAudioErrorFileOpenTimedOut:
                return @"Load timed out";
            case VibeAudioErrorFileOpenFailed:
                return @"Could not open file";
            case VibeAudioErrorEngineStartFailed:
                return @"Could not start playback";
            case VibeAudioErrorDeviceUnavailable:
                return @"Audio device unavailable";
            case VibeAudioErrorNotPlaying:
                break; // never reaches here (filtered above)
        }
    }
    return @"Playback error";
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
        // Device gone by the time this fires (or transient enumeration
        // failure): keep the previous persisted choice rather than erasing it.
        if (device) {
            Settings.audioOutputDeviceName = device.name;
            Settings.audioOutputDeviceUID = device.uid;
        }
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    [self updatePlaybackUI];
    // The playhead jumped — resync Control Center's elapsed time.
    [self updateNowPlaying];
}

#pragma mark - Metadata and Waveform

- (void)didLoadMetadata:(AudioTrack *)track {
    if (self.playlistManager.currentTrack == track) {
        // The metadata changed the row's content, so clear the same-track mark:
        // updateUI then takes its full-row reload branch (the play-state-only
        // branch would leave stale title/duration cells). One rebuild total —
        // calling reloadTrack: here as well would rebuild the row twice.
        _lastReloadedTrack = nil;
        [self updateUI];
    }
    else {
        [self.playlistManager reloadTrack:track];
    }
}

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage {
    [self.audioPlayer seekToPosition:self.audioPlayer.duration * percentage];
}

// Progressive snapshots and the final waveform, on the main thread. The view
// just renders what it's handed; cancellation filtering already happened in
// the cache.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    [self.trackDisplay showWaveform:waveform];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url {
    // A delivery usually belongs to the current track, but a late one can
    // land after next: advanced the playlist. The BPM is valid for whichever
    // track was analyzed, so stamp that track (deliveries are rare — once per
    // load — so a linear scan is fine) and only refresh the label when the
    // stamped track is the one it shows.
    AudioTrack *track = self.playlistManager.currentTrack;
    if (![track.url isEqual:url]) {
        track = nil;
        NSUInteger count = self.playlistManager.count;
        for (NSUInteger i = 0; i < count; i++) {
            AudioTrack *candidate = [self.playlistManager trackAtIndex:i];
            if ([candidate.url isEqual:url]) {
                track = candidate;
                break;
            }
        }
    }
    if (!track) {
        return;
    }
    track.detectedBPM = bpm;
    if (track == self.playlistManager.currentTrack) {
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

- (IBAction) togglePitchPanel:(id)sender {
    MainWindow *window = (MainWindow *)self.window;
    if (!window.isPitchPanelShown) {
        // Sync the fader with the player before the reveal (cheap either way).
        _pitchPanel.pitch = self.audioPlayer.pitch;
    }
    [window setPitchPanelShown:!window.isPitchPanelShown animate:YES];
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
    // A narrower range clamps the current pitch; resync the fader and the
    // rate-scaled time labels.
    _pitchPanel.pitch = self.audioPlayer.pitch;
    [self updateRateDependentUI];
    // The clamp can move the wall-clock duration Control Center shows — and
    // no fader gesture ends here to publish it.
    [self updateNowPlaying];
}

// Only the time labels depend on the playback rate. The full updateUI would
// also re-resolve artwork and reload the current playlist row (rebuilding the
// cell view) — far too heavy to run on every fader tick during a drag. The
// Now Playing publish (an XPC round-trip that a rate change always dirties)
// is deliberately NOT here either: fader gestures publish once at gesture
// end, and the non-gesture caller (applyPitchRange) publishes for itself.
- (void)updateRateDependentUI {
    if (self.playlistManager.currentTrack) {
        [self.trackDisplay renderTotalDuration:self.audioPlayer.duration rate:self.playbackRate];
    }
    [self effectiveTempoDidChange];
    [self updatePlaybackUI];
}

- (void)pitchControlPanel:(PitchControlPanel *)panel didChangePitch:(float)pitch {
    self.audioPlayer.pitch = pitch;
    // The time labels scale with the rate — refresh immediately (the 3 Hz
    // timer isn't running while paused).
    [self updateRateDependentUI];
}

- (void)pitchControlPanelDidEndAdjusting:(PitchControlPanel *)panel {
    // The pitch settled — resync Control Center's duration/position once for
    // the whole gesture.
    [self updateNowPlaying];
}

- (IBAction) showInFinder:(id)sender {
    NSURL *url = self.playlistManager.currentTrack.url;
    if (url) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
    }
}

// The playlist table's context menu (buildContentInWindow:). clickedRow is
// read at action time, not captured at menu-open — the playlist can be
// replaced while the menu is up, so the row is re-bounds-checked here (menu
// validation already disabled the item for a click outside the rows).
- (IBAction) showClickedTrackInFinder:(id)sender {
    NSInteger row = self.playlistTableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.playlistManager.count) {
        return;
    }
    NSURL *url = [self.playlistManager trackAtIndex:(NSUInteger)row].url;
    if (url) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
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
    [self.playlistManager reloadCurrentTrack];
    [self.waveformView updateAppearance];
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
