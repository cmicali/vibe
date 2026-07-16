//
//  MainPlayerController.m
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "MainPlayerController.h"
#import "ArtworkDisplayController.h"
#import "OutputDevicesMenuController.h"
#import "AppDelegate.h"
#import "Formatters.h"
#import "Fonts.h"
#import "ArtworkImageView.h"
#import "BackgroundArtworkImageView.h"
#import "AudioDeviceManager.h"
#import "MainPlayerContentView.h"
#import "AudioPlayer.h"
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

#define UPDATE_HZ 3

// View outlets (adopted from MainPlayerContentView in buildContentInWindow:)
// and protocol conformances are internal: nothing outside this file needs
// them except the debug command channel and the menu-validation category,
// which re-declare what they read (MainPlayerController+Debug.h /
// MainPlayerController+Menus.m) against these synthesized accessors.
// NSMenuItemValidation lives on the Menus category, where it is implemented.
@interface MainPlayerController () <NSWindowDelegate,
                                    NSWindowRestoration,
                                    FileDropDelegate,
                                    AudioPlayerDelegate,
                                    AudioWaveformViewDelegate,
                                    AudioWaveformCacheDelegate,
                                    AudioTrackMetadataCacheDelegate,
                                    PitchFaderViewDelegate,
                                    NowPlayingControllerDelegate>

@property (weak) GlyphButton *nextButton;
@property (weak) GlyphButton *playButton;
@property (weak) GlyphButton *closeButton;

@property (weak) NSTableView *playlistTableView;
@property (weak) NSTextField *artistTextField;
@property (weak) NSTextField *titleTextField;
@property (weak) ArtworkImageView *albumArtImageView;
@property (weak) BackgroundArtworkImageView *backgroundAlbumArtImageView;
@property (weak) AudioWaveformView *waveformView;
@property (weak) NSTextField *totalTimeTextField;
@property (weak) NSTextField *currentTimeTextField;
@property (weak) NSTextField *fileMetadataTextField;
@property (weak) NSTextField *bpmTextField;

@end

@implementation MainPlayerController {
    dispatch_source_t           _timer;
    NSTimeInterval              _lastPosition;
    // Duration snapshot from didStartPlaying: the live player duration reads
    // 0 while a track is Loading, and updatePlaybackUI runs in that gap.
    // Cleared when playback goes idle (error, end of playlist).
    NSTimeInterval              _currentTrackDuration;
    BOOL                        _timerRunning;
    __weak AudioTrack*          _lastReloadedTrack;
    NSString*                   _lastFileMetadataString;
    NSString*                   _lastBPMString;
    NSString*                   _statusMessage;
    BOOL                        _metadataLoadPending;
    // Pairs each play:'s 2s fallback timer with its own playlist: a timer
    // armed by playlist A firing after a re-drop must not start playlist B's
    // load early (while B's first track is still opening — exactly the I/O
    // contention the deferral exists to avoid).
    NSUInteger                  _metadataLoadGeneration;
    BOOL                        _errorAlertVisible;
    TransportKeyMonitor*        _keyMonitor;
    PitchControlPanel*          _pitchPanel;
    ArtworkDisplayController*   _artworkController;
    NowPlayingController*       _nowPlayingController;
}

- (id) init {
    // Programmatic window (no nib). initWithWindow: marks the controller as
    // already loaded (even the overridden loadWindow would never run), so the
    // window is built here and windowDidLoad — which AppKit only fires on the
    // nib path — is invoked directly.
    MainWindow *window = [[MainWindow alloc] init];
    if((self = [super initWithWindow:window])) {
        // Owned here now (the main nib used to instantiate it); windowDidLoad
        // hands it the audio player, so it must exist first.
        self.devicesMenuController = [[OutputDevicesMenuController alloc] init];
        [self buildContentInWindow:window];
        [self windowDidLoad];
    }
    return self;
}

#pragma mark - Window construction (previously MainPlayerWindow.xib)

// The UI hierarchy lives in MainPlayerContentView; this wires it to the
// window and adopts its subviews as the controller's outlets.
- (void)buildContentInWindow:(MainWindow *)window {
    NSView *contentView = window.contentView;
    MainPlayerContentView *content = [[MainPlayerContentView alloc] initWithTarget:self];
    [contentView addSubview:content];
    // The window already carries the restored (autosaved) frame, so the nib's
    // load-then-resize pass never happens; setting the frame here runs the
    // same subview autoresizing that pass would have. Width stays pinned at
    // the content width — when the pitch panel state restored as shown, the
    // window is already kPitchPanelWidth wider than the content.
    NSRect contentFrame = contentView.bounds;
    contentFrame.size.width = kMainWindowContentWidth;
    content.frame = contentFrame;

    self.closeButton = content.closeButton;
    self.playButton = content.playButton;
    self.nextButton = content.nextButton;
    self.backgroundAlbumArtImageView = content.backgroundAlbumArtImageView;
    self.albumArtImageView = content.albumArtImageView;
    self.waveformView = content.waveformView;
    self.artistTextField = content.artistTextField;
    self.titleTextField = content.titleTextField;
    self.totalTimeTextField = content.totalTimeTextField;
    self.currentTimeTextField = content.currentTimeTextField;
    self.fileMetadataTextField = content.fileMetadataTextField;
    self.bpmTextField = content.bpmTextField;
    self.playlistTableView = content.playlistTableView;

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

- (void)dealloc {
    if (_timer) {
        // Releasing a suspended dispatch source traps; the timer is created
        // suspended and stays suspended whenever _timerRunning is NO.
        if (!_timerRunning) {
            dispatch_resume(_timer);
        }
        dispatch_source_cancel(_timer);
    }
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

    _artworkController = [[ArtworkDisplayController alloc] initWithArtworkView:self.albumArtImageView
                                                                backgroundView:self.backgroundAlbumArtImageView];
    __weak MainPlayerController *weakControllerForArt = self;
    _artworkController.currentTrackProvider = ^AudioTrack *{
        return weakControllerForArt.playlistManager.currentTrack;
    };
    _artworkController.artDidResolveHandler = ^{
        [weakControllerForArt updateUI];
    };

    self.devicesMenuController.audioPlayer = self.audioPlayer;

    // Wire the collaborators to the views (all appearance/layout is applied
    // by MainPlayerContentView at construction).

    self.window.appearance = Settings.windowAppearance;

    self.waveformView.delegate = self;
    self.waveformView.waveformStyle = Settings.waveformStyle;

    self.playlistTableView.delegate = self.playlistManager;
    self.playlistTableView.dataSource = self.playlistManager;

    // Bare transport keys (Space/B/N/P/Tab) via a local event monitor — see
    // TransportKeyMonitor for why the menu key-equivalent path can't be
    // trusted for unmodified keys.
    _keyMonitor = [[TransportKeyMonitor alloc] initWithController:self];

    // System media keys / Control Center / Bluetooth transport controls. Its
    // now-playing info is published from updateNowPlaying (called out of the
    // updateUI funnel); registering the command handlers now lets the media
    // keys route to us as soon as the first track starts playing.
    _nowPlayingController = [[NowPlayingController alloc] initWithDelegate:self];

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

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // Leeway must be well under the interval, or the OS coalesces ticks and the
    // time label visibly skips seconds (worst on battery). ~1/10th interval.
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / UPDATE_HZ, NSEC_PER_SEC / UPDATE_HZ / 10);
    __weak MainPlayerController *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf updatePlaybackUI];
    });
    _timerRunning = NO;

    [self.playlistTableView reloadData];
    [self updateUI];

    [NSApp activate];
}

- (void)windowWillClose:(NSNotification *)notification {
    [NSApp terminate:nil];
}

- (void)pauseUIUpdateTimer {
    if (_timerRunning) {
        dispatch_suspend(_timer);
        _timerRunning = NO;
    }
}

- (void)resumeUIUpdateTimer {
    [self updateUI];
    if (!_timerRunning) {
        dispatch_resume(_timer);
        _timerRunning = YES;
    }
}

static void setStringValueIfChanged(NSTextField *field, NSString *value) {
    if (![field.stringValue isEqualToString:value]) {
        field.stringValue = value;
    }
}

- (void)updateUI {

    AudioTrack *track = self.playlistManager.currentTrack;

    self.playButton.glyph = self.audioPlayer.isPlaying ? GlyphButtonGlyphPause : GlyphButtonGlyphPlay;

    self.playButton.enabled = self.playlistManager.count > 0;
    self.nextButton.enabled = self.playlistManager.hasNextTrack;

    BOOL trackLoaded = track != nil;
    self.totalTimeTextField.hidden = !trackLoaded;
    self.currentTimeTextField.hidden = !trackLoaded;
    self.waveformView.hidden = !trackLoaded;

    if (track) {
        if (track.hasArtistAndTitle) {
            setStringValueIfChanged(self.artistTextField, track.artist);
            [self setTitleLabelText:track.title];
        }
        else {
            setStringValueIfChanged(self.artistTextField, @"");
            [self setTitleLabelText:track.singleLineTitle];
        }
        setStringValueIfChanged(self.totalTimeTextField, [[Formatters sharedInstance] durationStringFromTimeInterval:self.audioPlayer.duration / self.playbackRate]);
        if (_statusMessage) {
            // Transient player status (e.g. "Load timed out") takes the
            // bitrate label's spot until the next play attempt.
            [self setFileMetadataLabel:_statusMessage];
            _lastFileMetadataString = nil;
        }
        else if (track.metadata.fileType) {
            // bitrate/sampleRate can be nil even with fileType set — TagLib
            // can return no audioProperties. Guard so the label never shows
            // "(null) kbps" / "0.0 kHz".
            NSString *bitrate = @"";
            if (!track.metadata.isLossless && track.metadata.bitrate) {
                bitrate = [NSString stringWithFormat:@"%@ kbps | ", track.metadata.bitrate];
            }
            NSString *sampleRate = @"";
            if (track.metadata.sampleRate) {
                sampleRate = [NSString stringWithFormat:@"%.1f kHz", [track.metadata.sampleRate doubleValue] / 1000];
            }
            NSString *fileMetadata = (bitrate.length || sampleRate.length)
                    ? [NSString stringWithFormat:@"%@ | %@%@", track.metadata.fileType, bitrate, sampleRate]
                    : track.metadata.fileType;
            if (![fileMetadata isEqualToString:_lastFileMetadataString]) {
                [self setFileMetadataLabel:fileMetadata];
                _lastFileMetadataString = fileMetadata;
            }
        }
        else {
            setStringValueIfChanged(self.fileMetadataTextField, @"");
            _lastFileMetadataString = nil;
        }
    }
    else {
        setStringValueIfChanged(self.artistTextField, @"");
        [self setTitleLabelText:@""];
        setStringValueIfChanged(self.totalTimeTextField, @"");
        setStringValueIfChanged(self.currentTimeTextField, @"");
        if (_statusMessage) {
            [self setFileMetadataLabel:_statusMessage];
        }
        else {
            setStringValueIfChanged(self.fileMetadataTextField, @"");
        }
        _lastFileMetadataString = nil;
    }

    self.albumArtImageView.fileURL = track.url;

    [self updateBPMLabel];

    [_artworkController updateForTrack:track];

    if (track && track == _lastReloadedTrack) {
        // Same track as last time: only the play/pause indicator can have
        // changed in the playlist row.
        [self.playlistManager reloadCurrentTrackPlayState];
    }
    else {
        [self.playlistManager reloadCurrentTrack];
        _lastReloadedTrack = track;
    }
    [self updatePlaybackUI];
    [self updateNowPlaying];
}

// Publish the current track + playback state to the system Now Playing UI
// (Control Center, media keys). Driven off updateUI so it refreshes on every
// transport event, metadata delivery, and artwork resolution; also called on
// seek, pitch-range change, and fader-gesture end (the things that move
// position/rate without an updateUI — a fader drag deliberately publishes
// once at gesture end, not per tick). Cheap and non-blocking — safe to call
// this often.
- (void)updateNowPlaying {
    AudioTrack *track = self.playlistManager.currentTrack;
    NowPlayingPlaybackState state;
    if (self.audioPlayer.isPaused) {
        state = NowPlayingPlaybackStatePaused;
    }
    else if (self.audioPlayer.isPlaying) { // Playing or Loading
        state = NowPlayingPlaybackStatePlaying;
    }
    else {
        state = NowPlayingPlaybackStateStopped;
    }
    // Report pitch-adjusted (wall-clock) time so Control Center matches the
    // app's own current/total labels and tracks the pitch fader: the varispeed
    // rate divides file time exactly as -playbackRate / -updatePlaybackUI do
    // on screen. Wall-clock time then advances at real time, so the rate handed
    // to the system is 1.0 while playing (NowPlayingController zeroes it when
    // not) — NOT the varispeed rate, which would double-count against the
    // already-scaled position.
    double rate = self.playbackRate;
    NSTimeInterval duration = self.audioPlayer.duration;
    NSTimeInterval position = self.audioPlayer.position;
    if (rate > 0) {
        duration /= rate;
        position /= rate;
    }
    [_nowPlayingController updateWithTrack:track
                                 position:position
                                 duration:duration
                                    state:state
                                     rate:1.0
                                  hasNext:self.playlistManager.hasNextTrack
                              hasPrevious:self.playlistManager.hasPreviousTrack];
}

// Varispeed rate: the track plays this much faster/slower than file time, so
// the time labels show file time divided by it (the wall-clock time a DJ
// counting bars actually experiences). The waveform progress is a ratio and
// needs no scaling.
- (double)playbackRate {
    return 1.0 + self.audioPlayer.pitch / 100.0;
}

- (void)updatePlaybackUI {

    if (!self.playlistManager.currentTrack) {
        return;
    }

    NSTimeInterval duration = _currentTrackDuration;
    NSTimeInterval position = self.audioPlayer.position;
    if (duration > 0) {
        self.waveformView.progress = (float) position / (float) duration;
    }
    NSTimeInterval displayPosition = position / self.playbackRate;
    if (round(displayPosition) != round(_lastPosition)) {
        self.currentTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:displayPosition];
        _lastPosition = displayPosition;
    }
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

- (void)play:(NSArray<NSURL *> *)urls {
    [self.playlistManager play:urls];
    // Defer the playlist-wide metadata load until playback has actually
    // started: four workers reading every file can starve the player's own
    // file open on slow disks, delaying first sound by seconds. The fallback
    // covers the case where playback never starts (bad file, device error).
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

- (void)startPendingMetadataLoad {
    if (!_metadataLoadPending) {
        return;
    }
    _metadataLoadPending = NO;
    [self.metadataCache loadMetadata:self.playlistManager.playlist];
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

// Skip distances. When the track's tempo is known (tagged BPM wins over the
// analyzed one, same precedence as the BPM label) a skip moves by whole bars
// (4 beats) — a fixed span of *file* time, so the jump stays on the musical
// grid at any pitch. Without a tempo the fallback is the fixed wall-clock
// distance, as before.
static const NSTimeInterval kSkipSeconds = 10.0;
static const NSTimeInterval kSkipMoreSeconds = 30.0;
static const NSTimeInterval kSkipMostSeconds = 60.0;
static const double kSkipBars = 8.0;
static const double kSkipMoreBars = 16.0;
static const double kSkipMostBars = 32.0;

- (NSTimeInterval)skipFileSecondsForBars:(double)bars fallbackWallClockSeconds:(NSTimeInterval)wallSeconds {
    AudioTrack *track = self.playlistManager.currentTrack;
    float bpm = track.metadata.bpm > 0 ? track.metadata.bpm : track.detectedBPM;
    if (bpm > 0) {
        return bars * 4.0 * 60.0 / bpm;
    }
    // The fallback is expressed in the wall-clock seconds the user reads off
    // the time label; convert to file time (the player's units) with the same
    // varispeed rate the labels divide by, so a skip advances the displayed
    // clock by exactly the stated amount at any pitch.
    return wallSeconds * self.playbackRate;
}

- (IBAction)skipForward:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:kSkipBars fallbackWallClockSeconds:kSkipSeconds]];
}

- (IBAction)skipForwardMore:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:kSkipMoreBars fallbackWallClockSeconds:kSkipMoreSeconds]];
}

- (IBAction)skipForwardMost:(nullable id)sender {
    [self skipByFileSeconds:[self skipFileSecondsForBars:kSkipMostBars fallbackWallClockSeconds:kSkipMostSeconds]];
}

- (IBAction)skipBack:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:kSkipBars fallbackWallClockSeconds:kSkipSeconds]];
}

- (IBAction)skipBackMore:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:kSkipMoreBars fallbackWallClockSeconds:kSkipMoreSeconds]];
}

- (IBAction)skipBackMost:(nullable id)sender {
    [self skipByFileSeconds:-[self skipFileSecondsForBars:kSkipMostBars fallbackWallClockSeconds:kSkipMostSeconds]];
}

- (void)skipByFileSeconds:(NSTimeInterval)fileDelta {
    if (!self.playlistManager.currentTrack) {
        return;
    }
    NSTimeInterval duration = self.audioPlayer.duration;
    if (duration <= 0) {
        return; // Nothing seekable yet (loading, or no file open).
    }
    NSTimeInterval target = self.audioPlayer.position + fileDelta;
    if (target >= duration) {
        // Past the end: finish the track like a natural end — the delegate
        // (didFinishPlaying:) advances to the next track, or stops at the end
        // of the playlist.
        [self.audioPlayer finishCurrentTrack];
        return;
    }
    if (target < 0) {
        target = 0; // Skipping before the start seeks to the beginning.
    }
    self.audioPlayer.position = target;
}

- (IBAction)toggleLowKill:(nullable id)sender {
    self.audioPlayer.lowKillEnabled = !self.audioPlayer.lowKillEnabled;
}

- (void)setLowKillBoostActive:(BOOL)active {
    self.audioPlayer.lowKillBoostActive = active;
}

- (void)setReverbSendActive:(BOOL)active {
    self.audioPlayer.reverbSendEnabled = active;
}

- (void)setDelaySendActive:(BOOL)active {
    self.audioPlayer.delaySendEnabled = active;
}

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

// Right-aligned, kerned like the file-metadata string it replaces.
- (void)setFileMetadataLabel:(NSString *)text {
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = NSTextAlignmentRight;
    self.fileMetadataTextField.attributedStringValue = [[NSMutableAttributedString alloc] initWithString:text
                                                                                              attributes:@{
                                                                NSKernAttributeName:@(-1.2),
                                                                NSParagraphStyleAttributeName:paragraph,
                                                            }];
}

// Shrink-to-fit for the title: long titles reduce the font size (down to a
// floor) so they fit the label's capped width instead of running under the
// codec/BPM labels; anything still too long at the floor truncates with an
// ellipsis. updateUI re-runs on every transport event and metadata delivery
// (once per track during the sweep), so only re-fit when the text changes.
- (void)setTitleLabelText:(NSString *)text {
    static const CGFloat kTitleFontSize = 23;
    static const CGFloat kTitleMinFontSize = 15;
    if ([text isEqualToString:self.titleTextField.stringValue]) {
        return;
    }
    NSFont *font = [Fonts font:kTitleFontSize];
    CGFloat maxWidth = self.titleTextField.frame.size.width;
    CGFloat width = [text sizeWithAttributes:@{NSFontAttributeName: font}].width;
    if (width > maxWidth) {
        // Glyph advance scales linearly with point size, so one scale step
        // lands on the fitting size; the 2% margin covers rounding.
        CGFloat fitted = kTitleFontSize * (maxWidth / width) * 0.98;
        font = [Fonts font:MAX(kTitleMinFontSize, floor(fitted * 2) / 2)];
    }
    self.titleTextField.font = font;
    self.titleTextField.stringValue = text;
}

// The BPM line sits under the codec line and matches its style exactly
// (right-aligned, same kern). Tagged tempo wins over the analyzed one; the
// displayed value scales with the pitch fader. This re-runs on every updateUI
// pass and every fader tick during a drag (updateRateDependentUI), so skip
// the attributed-string rebuild when nothing changed.
- (void)updateBPMLabel {
    AudioTrack *track = self.playlistManager.currentTrack;
    float baseBPM = track.metadata.bpm > 0 ? track.metadata.bpm : track.detectedBPM;
    // This funnel sees every source of an effective-tempo change (track
    // change, BPM delivery, fader tick), so the delay echo's 1/8-note tap is
    // fed here — before the label early-return, whose string granularity
    // (0.1 BPM) is coarser than the fader's. The setter no-ops on same value.
    self.audioPlayer.delayTapBPM = baseBPM > 0 ? baseBPM * self.playbackRate : 0;
    NSString *text = (track && baseBPM > 0)
            ? [NSString stringWithFormat:@"%.1f BPM", baseBPM * self.playbackRate]
            : @"";
    if ([text isEqualToString:_lastBPMString]) {
        return;
    }
    _lastBPMString = text;
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = NSTextAlignmentRight;
    self.bpmTextField.attributedStringValue = [[NSMutableAttributedString alloc] initWithString:text
                                                                                      attributes:@{
                                                            NSKernAttributeName:@(-1.2),
                                                            NSParagraphStyleAttributeName:paragraph,
                                                        }];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didBeginLoading:(AudioTrack *)track {
    _statusMessage = nil;
    // Show the pending track's title/artist while it loads.
    [self updateUI];
    [self.waveformView showLoadingIndicator];
    self.waveformView.hidden = NO;
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track  {
    [_artworkController trackDidStartPlaying:track];
    _statusMessage = nil;
    [self.waveformView hideLoadingIndicator];
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:track.url];
    // Only the current playlist's start may consume the deferred load: a
    // stale didStartPlaying from a just-replaced playlist would otherwise
    // start the new playlist's load while its first track is still opening.
    // (The new playlist's own didStartPlaying — or the 2s fallback — follows.)
    if (track == [self.playlistManager currentTrack]) {
        [self startPendingMetadataLoad];
    }
    _currentTrackDuration = self.audioPlayer.duration;
    [self.waveformView prepareForWaveformLoad];
    [self.waveformCache loadWaveformForTrack:track];
    // Pre-open the likely-next file so auto-advance and Next skip the file
    // open — the dominant transition latency. Recomputed on every track start
    // (next/previous, double-click, re-drop all land here); nil past the last
    // track drops the parked handle.
    AudioTrack *nextTrack = nil;
    NSUInteger nextIndex = self.playlistManager.currentIndex + 1;
    if (nextIndex < self.playlistManager.count) {
        nextTrack = self.playlistManager.playlist[nextIndex];
    }
    [self.audioPlayer prefetchTrack:nextTrack];
    // Whoever initiated this play already fully rendered the row (play:'s
    // reloadData, next/previous's two-row window, doubleClick's pair); the
    // mark makes resumeUIUpdateTimer -> updateUI refresh only the play-state
    // cell (the equalizer indicator must flip to animating) instead of
    // rebuilding the whole row again. Guarded like the metadata load above —
    // a stale start from a just-replaced playlist must not mark the new
    // playlist's row as rendered.
    if (track == [self.playlistManager currentTrack]) {
        _lastReloadedTrack = track;
    }
    [self resumeUIUpdateTimer];
    self.playButton.enabled = YES;
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    [self pauseUIUpdateTimer];
    [self updateUI];
    self.playButton.enabled = YES;
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    [self resumeUIUpdateTimer];
    self.playButton.enabled = YES;
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
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain] && error.code == VibeAudioErrorNotPlaying) {
        // A play/pause toggle raced a track ending (or nothing is loaded).
        // Harmless — ignore silently rather than popping a modal alert.
        return;
    }
    [self startPendingMetadataLoad];
    [self pauseUIUpdateTimer];
    // Playback failed — the duration cached at the last didStartPlaying no
    // longer describes anything the player holds.
    _currentTrackDuration = 0;
    [self.waveformView hideLoadingIndicator];
    if ([error.domain isEqualToString:kVibeAudioErrorDomain] && error.code == VibeAudioErrorFileOpenTimedOut) {
        // Slow/unreachable file (cloud placeholder, dead network): no modal,
        // no auto-skip — just an inline status where the bitrate info goes.
        LogError(@"%@", error.localizedDescription);
        _statusMessage = @"Load timed out";
        [self updateUI];
        return;
    }
    // Present the alert as a sheet, not with runModal. runModal spins a nested
    // app-modal run loop with no parent window; on this borderless window the
    // window fails to reclaim key status afterward, which silently kills the
    // unmodified transport key equivalents (Space/B/N) until the app is
    // relaunched. Errors can also fire back-to-back (a folder of bad files),
    // and _errorAlertVisible collapses those into a single sheet instead of
    // nesting modal sessions.
    if (_errorAlertVisible) {
        return;
    }
    _errorAlertVisible = YES;
    NSAlert *alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:@"Ok"];
    [alert setMessageText:@"AudioPlayer Error"];
    [alert setInformativeText:error.userInfo[NSLocalizedDescriptionKey]];
    [alert setAlertStyle:NSAlertStyleWarning];
    __weak MainPlayerController *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_errorAlertVisible = NO;
        // Through the next: funnel: if it couldn't start anything (end of
        // playlist, single bad track), its updateUI makes the header/waveform/
        // play-button reflect the stopped player instead of the previous track.
        [strongSelf next:nil];
        // Belt-and-suspenders: guarantee the borderless window is key again so
        // the transport key equivalents keep working after the sheet closes.
        [strongSelf.window makeKeyWindow];
    }];
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

#pragma mark - NowPlayingControllerDelegate (system media keys / Control Center)

// Commands arrive on the main thread; route them through the same transport
// entry points the on-screen buttons and keyboard use.

- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    // Discrete "play" — start/resume only if not already playing (playPause:
    // would otherwise pause a playing track).
    if (!self.audioPlayer.isPlaying) {
        [self playPause:nil];
    }
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    // Discrete "pause" — act only when something is actually playing.
    if (self.audioPlayer.isPlaying) {
        [self playPause:nil];
    }
}

- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {
    [self playPause:nil];
}

- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {
    [self next:nil];
}

- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {
    [self previous:nil];
}

- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {
    // The scrubber position arrives in the wall-clock time updateNowPlaying
    // publishes (elapsed/duration divided by the varispeed rate); the player
    // seeks in file time, so convert back with the same rate — exactly as
    // the skip actions' wall-clock fallback does.
    self.audioPlayer.position = position * self.playbackRate;
}

#pragma mark - Metadata and Waveform

- (void)didLoadMetadata:(AudioTrack *)track {
    [self.playlistManager reloadTrack:track];
    if (self.playlistManager.currentTrack == track) {
        [self updateUI];
    }
}

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage {
    self.audioPlayer.position = self.audioPlayer.duration * percentage;
}

// Progressive snapshots and the final waveform, on the main thread. The view
// just renders what it's handed; cancellation filtering already happened in
// the cache.
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded {
    [self.waveformView showWaveform:waveform];
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
        for (AudioTrack *candidate in self.playlistManager.playlist) {
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
        [self updateBPMLabel];
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
        setStringValueIfChanged(self.totalTimeTextField,
                [[Formatters sharedInstance] durationStringFromTimeInterval:self.audioPlayer.duration / self.playbackRate]);
    }
    [self updateBPMLabel];
    [self updatePlaybackUI];
}

- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch {
    self.audioPlayer.pitch = pitch;
    // The time labels scale with the rate — refresh immediately (the 3 Hz
    // timer isn't running while paused).
    [self updateRateDependentUI];
}

- (void)pitchFaderViewDidEndAdjusting:(PitchFaderView *)faderView {
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
    NSURL *url = self.playlistManager.playlist[(NSUInteger)row].url;
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
