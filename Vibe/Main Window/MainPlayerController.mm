//
//  MainPlayerController.m
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "MainPlayerController.h"
#import "NSDockTile+Util.h"
#import "OutputDevicesMenuController.h"
#import "AppDelegate.h"
#import "Formatters.h"
#import "Fonts.h"
#import "ArtworkImageView.h"
#import "BackgroundArtworkImageView.h"
#import "AudioDeviceManager.h"

#define UPDATE_HZ 3

@implementation MainPlayerController {
    dispatch_source_t           _timer;
    NSTimeInterval              _lastPosition;
    NSTimeInterval              _currentTrackDuration;
    BOOL                        _timerRunning;
    __weak NSImage*             _displayedArt;
    __weak AudioTrack*          _lastReloadedTrack;
    // Track whose full-res art is currently held decoded (weak: if the
    // playlist was replaced the track deallocates and takes its art with it).
    __weak AudioTrack*          _artOwnerTrack;
    NSString*                   _lastFileMetadataString;
    NSString*                   _statusMessage;
    BOOL                        _metadataLoadPending;
    // Pairs each play:'s 2s fallback timer with its own playlist: a timer
    // armed by playlist A firing after a re-drop must not start playlist B's
    // load early (while B's first track is still opening — exactly the I/O
    // contention the deferral exists to avoid).
    NSUInteger                  _metadataLoadGeneration;
    BOOL                        _artDisplayInitialized;
    BOOL                        _errorAlertVisible;
    id                          _keyDownMonitor;
}

- (id) init {
    if((self = [super initWithWindowNibName:@"MainPlayerWindow"])) {
    }
    return self;
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

    // Resolve the saved device by UID first (robust against duplicate device
    // names); fall back to the persisted name for pre-UID settings.
    NSString *savedDeviceName = Settings.audioOutputDeviceName;
    AudioDevice *savedDevice = [[AudioDeviceManager sharedInstance] outputDeviceForUID:Settings.audioOutputDeviceUID];
    if (savedDevice) {
        savedDeviceName = savedDevice.name;
    }
    self.audioPlayer = [[AudioPlayer alloc] initWithDevice:savedDeviceName
                                            lockSampleRate:Settings.audioPlayerLockSampleRate
                                                  delegate:self
    ];
    self.metadataManager = [[AudioTrackMetadataCache alloc] init];
    self.metadataManager.delegate = self;

    self.playlistManager = [[PlaylistManager alloc] initWithAudioPlayer:self.audioPlayer];
    self.playlistManager.tableView = self.playlistTableView;

    self.devicesMenuController.audioPlayer = self.audioPlayer;

    // Setup Views

    self.window.appearance = Settings.windowAppearance;

    self.albumArtGradientView.wantsLayer = YES;
    CAGradientLayer *g = [[CAGradientLayer alloc] init];
    g.colors = @[
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.85].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.25].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
    ];
    self.albumArtGradientView.layer = g;

    self.playButton.image = [NSImage imageNamed:@"button-play"];
    self.nextButton.image = [NSImage imageNamed:@"button-skip-next"];

    self.artistTextField.wantsLayer = YES;
    self.artistTextField.layer.shadowColor = NSColor.blackColor.CGColor;
    self.artistTextField.layer.shadowRadius = 0.25;
    self.artistTextField.layer.shadowOpacity = 0.75;
    self.artistTextField.layer.shadowOffset = CGSizeMake(0, -1);
    self.artistTextField.layer.shouldRasterize = true;
    self.artistTextField.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    self.artistTextField.layer.masksToBounds = NO;

    self.titleTextField.wantsLayer = YES;
    self.titleTextField.layer.shadowColor = NSColor.blackColor.CGColor;
    self.titleTextField.layer.shadowRadius = 0.25;
    self.titleTextField.layer.shadowOpacity = 0.75;
    self.titleTextField.layer.shadowOffset = CGSizeMake(0, -1);
    self.titleTextField.layer.shouldRasterize = true;
    self.titleTextField.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    self.titleTextField.layer.masksToBounds = NO;

    self.totalTimeTextField.wantsLayer = YES;
    self.totalTimeTextField.layer.shadowColor = NSColor.blackColor.CGColor;
    self.totalTimeTextField.layer.shadowRadius = 0.25;
    self.totalTimeTextField.layer.shadowOpacity = 0.75;
    self.totalTimeTextField.layer.shadowOffset = CGSizeMake(0, -1);
    self.totalTimeTextField.layer.masksToBounds = NO;
    self.totalTimeTextField.layer.shouldRasterize = true;
    self.totalTimeTextField.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    self.totalTimeTextField.font = [Fonts fontForNumbers:self.totalTimeTextField.font.pointSize bold:YES];

    self.currentTimeTextField.wantsLayer = YES;
    self.currentTimeTextField.layer.shadowColor = NSColor.blackColor.CGColor;
    self.currentTimeTextField.layer.shadowRadius = 0.25;
    self.currentTimeTextField.layer.shadowOpacity = 0.75;
    self.currentTimeTextField.layer.shadowOffset = CGSizeMake(0, -1);
    self.currentTimeTextField.layer.masksToBounds = NO;
    // No shouldRasterize here: this field's content changes every second, so
    // rasterization would just force a re-raster on every update.
    self.currentTimeTextField.font = [Fonts fontForNumbers:self.currentTimeTextField.font.pointSize bold:YES];

    self.albumArtImageView.wantsLayer = YES;
    self.albumArtImageView.layer.shadowRadius = 6;
    self.albumArtImageView.layer.shadowOpacity = 0.25;
    self.albumArtImageView.layer.shadowOffset = CGSizeMake(4, 0);
    self.albumArtImageView.layer.masksToBounds = NO;
    self.albumArtImageView.layer.shouldRasterize = true;
    self.albumArtImageView.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;

    self.backgroundAlbumArtImageView.wantsLayer = YES;
    self.backgroundAlbumArtImageView.layer.masksToBounds = NO;
    // shouldRasterize was only there to cache the (now removed) live
    // CIGaussianBlur filter output; the image is pre-blurred these days.

    self.fileMetadataTextField.wantsLayer = YES;
    self.fileMetadataTextField.layer.shadowColor = NSColor.blackColor.CGColor;
    self.fileMetadataTextField.layer.shadowRadius = 0.25;
    self.fileMetadataTextField.layer.shadowOpacity = 0.75;
    self.fileMetadataTextField.layer.shadowOffset = CGSizeMake(0, -1);
    self.fileMetadataTextField.layer.masksToBounds = NO;
    self.fileMetadataTextField.layer.shouldRasterize = true;
    self.fileMetadataTextField.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    self.fileMetadataTextField.font = [Fonts fontForNumbers:self.totalTimeTextField.font.pointSize bold:NO];

//
//    if ([MacOSUtil isDarkMode:self.window.appearance]) {
//        self.playlistTableView.backgroundColor = [NSColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1];
//    }
//    else {
//        self.playlistBackgroundView.hidden = YES;
//    }

    self.waveformView.delegate = self;
    self.waveformView.waveformStyle = Settings.waveformStyle;

    NSScrollView *playlistScrollView = self.playlistTableView.enclosingScrollView;
    self.playlistTableView.delegate = self.playlistManager;
    self.playlistTableView.dataSource = self.playlistManager;
    self.playlistTableView.intercellSpacing = NSMakeSize(0, 0);
    self.playlistTableView.columnAutoresizingStyle = NSTableViewSequentialColumnAutoresizingStyle;
    // Type-select would swallow plain keystrokes (jump to the first row
    // starting with that letter) before the menu sees them, breaking the
    // unmodified transport key equivalents (Space/B/N) whenever the table
    // has focus.
    self.playlistTableView.allowsTypeSelect = NO;

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
        return event;
    }];
    // Opt out of the macOS 11+ inset look; we want the selection highlight
    // and row content flush with the scroll view's left/right edges.
    if (@available(macOS 11.0, *)) {
        self.playlistTableView.style = NSTableViewStyleFullWidth;
    }
    // Let the autoresize mask from the xib govern width/height so the table
    // tracks its clip view. Previously we set
    // translatesAutoresizingMaskIntoConstraints = NO without adding any
    // Auto Layout constraints, leaving the table stuck at its xib-time
    // width (712 px) — wider than the clip view, hence horizontal scroll.

    playlistScrollView.automaticallyAdjustsContentInsets = NO;
    playlistScrollView.contentInsets = NSEdgeInsetsZero;
    playlistScrollView.hasHorizontalScroller = NO;
    playlistScrollView.horizontalScrollElasticity = NSScrollElasticityNone;
    [self.playlistTableView sizeToFit];
    
    
    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;

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

    // [self configureTrackingArea];
    
    [NSApp activateIgnoringOtherApps:YES];

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
    self.nextButton.enabled = self.playlistManager.count > 1;

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
        setStringValueIfChanged(self.totalTimeTextField, [[Formatters sharedInstance] durationStringFromTimeInterval:self.audioPlayer.duration]);
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

    [self updateArtworkForTrack:track];

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

// Artwork display policy: new art replaces old art directly. While the new
// track's art is still unresolved (metadata pending, load worth dispatching,
// or a load in flight), the PREVIOUS track's art stays on screen — no flash
// of the default between tracks. The default backdrop is installed only when
// the track is known to be artless.
- (void)updateArtworkForTrack:(AudioTrack *)track {
    if (track.albumArt) {
        if (_displayedArt != track.albumArt) {
            self.albumArtImageView.image = track.albumArt;
            [self.backgroundAlbumArtImageView setArtworkImage:track.albumArt];
            [NSDockTile setDockIcon:self.playlistManager.currentTrack.albumArt];
            _displayedArt = track.albumArt;
        }
        _artDisplayInitialized = YES;
        return;
    }

    AudioTrackMetadata *metadata = track.metadata;
    // albumArtLoadDispatched is cleared when a load completes, so here it
    // means exactly "a load is in flight".
    BOOL artUnresolved = !metadata || metadata.albumArtNeedsLoad || metadata.albumArtLoadDispatched;
    if (!artUnresolved || !_artDisplayInitialized) {
        [self showDefaultArtwork];
    }
    _artDisplayInitialized = YES;

    // Cache-hit metadata doesn't carry the art bytes; extracting them
    // re-reads the audio file, which can block on a cloud placeholder
    // until it downloads. Do it off the main thread and refresh when done.
    if (metadata.albumArtNeedsLoad && !metadata.albumArtLoadDispatched) {
        metadata.albumArtLoadDispatched = YES;
        __weak MainPlayerController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSImage *loaded = metadata.albumArt; // may block; background thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // Resolved either way — clear the in-flight marker. No
                // duplicate-dispatch risk: albumArtNeedsLoad is NO after any
                // completion (image decoded, or attempted and artless).
                metadata.albumArtLoadDispatched = NO;
                MainPlayerController *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.playlistManager.currentTrack != track) {
                    return;
                }
                if (loaded) {
                    [strongSelf updateUI];
                }
                else {
                    // Definitively artless: only now does the default
                    // replace the previous track's art.
                    [strongSelf showDefaultArtwork];
                }
            });
        });
    }
}

// Installs the record-bg default backdrop (no-op if it's already showing).
- (void)showDefaultArtwork {
    if (!_displayedArt && _artDisplayInitialized) {
        return;
    }
    self.albumArtImageView.image = [NSImage imageNamed:@"record-bg"];
    [self.backgroundAlbumArtImageView setArtworkImage:[NSImage imageNamed:@"record-bg"]];
    [NSDockTile resetToAppIcon];
    _displayedArt = nil;
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
    if (round(position) != round(_lastPosition)) {
        self.currentTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:position];
        _lastPosition = position;
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
    [self.metadataManager loadMetadata:self.playlistManager.playlist];
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
    // Demote the previous track's full-res art (decoded bitmap + compressed
    // bytes, ~4-9MB together). Without this, every track played in a session
    // stays pinned for the playlist's lifetime. The thumbnail is kept; the art
    // reloads on demand if the track becomes current again.
    if (_artOwnerTrack && _artOwnerTrack != track) {
        [_artOwnerTrack.metadata discardDecodedAlbumArt];
    }
    _artOwnerTrack = track;
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

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOuputDevice:(NSInteger)newDeviceIndex {
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
        [menuItem setKeyEquivalent:[NSString stringWithFormat:@"%c", NSTabCharacter]];
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
        return self.playlistManager.count > 1;
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
