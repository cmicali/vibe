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
#import "ArtworkImageView.h"
#import "BackgroundArtworkImageView.h"
#import "AudioDeviceManager.h"
#import "MainPlayerContentView.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformView.h"
#import "PlaylistManager.h"
#import "MainWindow.h"
#import "SYFlatButton.h"
#import "PitchControlPanel.h"

#define UPDATE_HZ 3

// View outlets (adopted from MainPlayerContentView in buildContentInWindow:)
// and protocol conformances are internal: nothing outside this file needs
// them except the debug command channel, which re-declares what it reads in
// MainPlayerController+Debug.h against these synthesized accessors.
@interface MainPlayerController () <NSMenuItemValidation,
                                    NSWindowDelegate,
                                    NSWindowRestoration,
                                    FileDropDelegate,
                                    AudioPlayerDelegate,
                                    AudioWaveformViewDelegate,
                                    AudioTrackMetadataCacheDelegate,
                                    PitchFaderViewDelegate>

@property (weak) SYFlatButton *nextButton;
@property (weak) SYFlatButton *playButton;
@property (weak) SYFlatButton *closeButton;

@property (weak) NSTableView *playlistTableView;
@property (weak) NSTextField *artistTextField;
@property (weak) NSTextField *titleTextField;
@property (weak) ArtworkImageView *albumArtImageView;
@property (weak) BackgroundArtworkImageView *backgroundAlbumArtImageView;
@property (weak) AudioWaveformView *waveformView;
@property (weak) NSTextField *totalTimeTextField;
@property (weak) NSTextField *currentTimeTextField;
@property (weak) NSTextField *fileMetadataTextField;
@property (weak) NSView *albumArtGradientView;

@end

@implementation MainPlayerController {
    dispatch_source_t           _timer;
    NSTimeInterval              _lastPosition;
    NSTimeInterval              _currentTrackDuration;
    BOOL                        _timerRunning;
    __weak AudioTrack*          _lastReloadedTrack;
    NSString*                   _lastFileMetadataString;
    NSString*                   _statusMessage;
    BOOL                        _metadataLoadPending;
    // Pairs each play:'s 2s fallback timer with its own playlist: a timer
    // armed by playlist A firing after a re-drop must not start playlist B's
    // load early (while B's first track is still opening — exactly the I/O
    // contention the deferral exists to avoid).
    NSUInteger                  _metadataLoadGeneration;
    BOOL                        _errorAlertVisible;
    id                          _keyDownMonitor;
    PitchControlPanel*          _pitchPanel;
    ArtworkDisplayController*   _artworkController;
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
    self.albumArtGradientView = content.albumArtGradientView;
    self.waveformView = content.waveformView;
    self.artistTextField = content.artistTextField;
    self.titleTextField = content.titleTextField;
    self.totalTimeTextField = content.totalTimeTextField;
    self.currentTimeTextField = content.currentTimeTextField;
    self.fileMetadataTextField = content.fileMetadataTextField;
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
}

- (void)dealloc {
    if (_keyDownMonitor) {
        [NSEvent removeMonitor:_keyDownMonitor];
    }
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

    // Resolve the saved device by UID first (robust against duplicate device
    // names); fall back to the persisted name for pre-UID settings.
    NSString *savedDeviceName = Settings.audioOutputDeviceName;
    AudioDevice *savedDevice = [[AudioDeviceManager sharedInstance] outputDeviceForUID:Settings.audioOutputDeviceUID];
    if (savedDevice) {
        savedDeviceName = savedDevice.name;
    }
    self.audioPlayer = [[AudioPlayer alloc] initWithDevice:savedDeviceName
                                                  delegate:self
    ];
    self.metadataCache = [[AudioTrackMetadataCache alloc] init];
    self.metadataCache.delegate = self;

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

    // Handle the transport keys with a local event monitor instead of relying
    // on the menu's unmodified key equivalents. Those only fire as a fallback
    // after the focused view's keyDown/input-context machinery declines the
    // event, and that path is fragile: the playlist table's input context can
    // wedge after an unhandled letter (observed: press any unbound key while
    // the table is focused and every subsequent key beeps, killing B/N until
    // relaunch). The monitor sees the event before any of that runs.
    __weak MainPlayerController *weakSelf = self;
    _keyDownMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent *(NSEvent *event) {
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf || event.window != strongSelf.window) {
            return event;
        }
        // Leave anything that isn't a bare keypress alone (menu shortcuts,
        // future text editing in a field editor).
        NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
                    NSEventModifierFlagOption | NSEventModifierFlagShift)) {
            return event;
        }
        if ([strongSelf.window.firstResponder isKindOfClass:[NSTextView class]]) {
            return event;
        }
        NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
        if ([chars isEqualToString:@" "]) {
            [strongSelf playPause:nil];
            return nil;
        }
        if ([chars isEqualToString:@"b"]) {
            [strongSelf previous:nil];
            return nil;
        }
        if ([chars isEqualToString:@"n"]) {
            [strongSelf next:nil];
            return nil;
        }
        if ([chars isEqualToString:@"p"]) {
            [strongSelf togglePitchPanel:nil];
            return nil;
        }
        // Tab is also a menu key equivalent (installed by MainMenuBuilder),
        // but that path only fires as a fallback after the focused view
        // declines the event — handle it here like the other bare keys.
        if ([chars isEqualToString:@"\t"]) {
            [strongSelf toggleSize:nil];
            return nil;
        }
        return event;
    }];

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
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf updatePlaybackUI];
    });
    _timerRunning = NO;

    [self.playlistTableView reloadData];
    [self updateUI];

    [NSApp activateIgnoringOtherApps:YES];

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

    if (self.audioPlayer.isPlaying) {
        self.playButton.image = [NSImage imageNamed:@"button-pause"];
    }
    else {
        self.playButton.image = [NSImage imageNamed:@"button-play"];
    }

    self.playButton.enabled = self.playlistManager.count > 0;
    // Same rule as the Next Track menu item: only when a track actually
    // follows the current one.
    self.nextButton.enabled = self.playlistManager.currentIndex + 1 < self.playlistManager.count;

    BOOL trackLoaded = track != nil;
    self.totalTimeTextField.hidden = !trackLoaded;
    self.currentTimeTextField.hidden = !trackLoaded;
    self.waveformView.hidden = !trackLoaded;

    if (track) {
        if (track.hasArtistAndTitle) {
            setStringValueIfChanged(self.artistTextField, track.artist);
            setStringValueIfChanged(self.titleTextField, track.title);
        }
        else {
            setStringValueIfChanged(self.artistTextField, @"");
            setStringValueIfChanged(self.titleTextField, track.singleLineTitle);
        }
        setStringValueIfChanged(self.totalTimeTextField, [[Formatters sharedInstance] durationStringFromTimeInterval:self.audioPlayer.duration / self.playbackRate]);
        if (_statusMessage) {
            // Transient player status (e.g. "Load timed out") takes the
            // bitrate label's spot until the next play attempt.
            [self setFileMetadataLabel:_statusMessage];
            _lastFileMetadataString = nil;
        }
        else if (track.metadata.fileType) {
            // bitrate/sampleRate can be nil even with fileType set: the art
            // re-read path fills fileType as a side effect after a failed
            // initial parse, and TagLib can return no audioProperties. Guard
            // so the label never shows "(null) kbps" / "0.0 kHz".
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
        setStringValueIfChanged(self.titleTextField, @"");
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
    [self updateUI];
}

- (IBAction)previous:(nullable id)sender {
    [self.playlistManager previous];
    [self updateUI];
}

- (IBAction)closeApp:(id)sender {
    [self close];
}

- (void)mainWindow:(MainWindow *)mainWindow filesDropped:urls {
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
    [self.waveformView loadWaveformForTrack:track];
    // No reloadCurrentTrack here: resumeUIUpdateTimer -> updateUI already
    // reloads the current row.
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
    [self next:self];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    if ([error.domain isEqualToString:kVibeAudioErrorDomain] && error.code == VibeAudioErrorNotPlaying) {
        // A play/pause toggle raced a track ending (or nothing is loaded).
        // Harmless — ignore silently rather than popping a modal alert.
        return;
    }
    [self startPendingMetadataLoad];
    [self pauseUIUpdateTimer];
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
        [strongSelf.playlistManager next];
        // If next couldn't start anything (end of playlist, single bad track),
        // make the header/waveform/play-button reflect the stopped player
        // instead of the previous track.
        [strongSelf updateUI];
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
}

// Only the time labels depend on the playback rate. The full updateUI would
// also re-resolve artwork and reload the current playlist row (rebuilding the
// cell view) — far too heavy to run on every fader tick during a drag.
- (void)updateRateDependentUI {
    if (self.playlistManager.currentTrack) {
        setStringValueIfChanged(self.totalTimeTextField,
                [[Formatters sharedInstance] durationStringFromTimeInterval:self.audioPlayer.duration / self.playbackRate]);
    }
    [self updatePlaybackUI];
}

- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch {
    self.audioPlayer.pitch = pitch;
    // The time labels scale with the rate — refresh immediately (the 3 Hz
    // timer isn't running while paused).
    [self updateRateDependentUI];
}

- (IBAction) showInFinder:(id)sender {
    NSURL *url = self.playlistManager.currentTrack.url;
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

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    if ([menuItem.identifier isEqualToString:@"menu_show_playlist"]) {
        menuItem.state = StateForBOOL(window.isPlaylistShown);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_show_pitch"]) {
        menuItem.state = StateForBOOL(window.isPitchPanelShown);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_system_default"]) {
        menuItem.state = StateForString(Settings.windowAppearanceStyle, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_light"]) {
        menuItem.state = StateForString(Settings.windowAppearanceStyle, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT);
    }
    else if ([menuItem.identifier isEqualToString:@"view_appearance_dark"]) {
        menuItem.state = StateForString(Settings.windowAppearanceStyle, SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_next_track"]) {
        // Only when there is actually a track after the current one; at the
        // end of the playlist next: is a no-op.
        return self.playlistManager.currentIndex + 1 < self.playlistManager.count;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_previous_track"]) {
        return self.playlistManager.count > 0 && self.playlistManager.currentIndex > 0;
    }
    else if ([menuItem.identifier isEqualToString:@"pitch_range_8"]) {
        menuItem.state = StateForBOOL(Settings.pitchRange == 8);
    }
    else if ([menuItem.identifier isEqualToString:@"pitch_range_16"]) {
        menuItem.state = StateForBOOL(Settings.pitchRange == 16);
    }
    else if ([menuItem.identifier isEqualToString:@"menu_play"]) {
        return self.playlistManager.count > 0;
    }
    else if ([menuItem.identifier isEqualToString:@"show_in_finder"]) {
        return self.playlistManager.currentTrack.url != nil;
    }
    return YES;
}

- (NSInteger)numberOfItemsInMenu:(NSMenu *)menu {
    if ([menu.identifier isEqualToString:@"waveform_style"]) {
        return self.waveformView.availableWaveformStyles.count;
    }
    return 0;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if ([menu.identifier isEqualToString:@"waveform_style"]) {
        NSInteger count = [self numberOfItemsInMenu:menu];
        while ([menu numberOfItems] < count)
            [menu insertItem:[NSMenuItem new] atIndex:0];
        while ([menu numberOfItems] > count)
            [menu removeItemAtIndex:0];
        NSArray<NSString*>* styles = [self.waveformView.availableWaveformStyles sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        for (NSUInteger i = 0; i < count; ++i) {
            NSMenuItem *item = [menu itemAtIndex:i];
            item.title = styles[i];
            item.state = StateForBOOL([item.title isEqualToString:self.waveformView.currentWaveformStyle]);
            item.enabled = YES;
            item.target = self;
            item.action = @selector(setWaveformStyle:);
        }
    }
}

- (IBAction)setWaveformStyle:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        NSString *title = ((NSMenuItem *)sender).title;
        self.waveformView.waveformStyle = title;
        Settings.waveformStyle = title;
    }
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
