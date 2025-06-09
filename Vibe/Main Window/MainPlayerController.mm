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
#import "AudioDeviceManager.h"

#define UPDATE_HZ 3

@implementation MainPlayerController {
    dispatch_source_t           _timer;
    NSTimeInterval              _lastPosition;
    BOOL                        _timerRunning;
    __weak NSImage*             _displayedArt;

}

- (id) init {
    if((self = [super initWithWindowNibName:@"MainPlayerWindow"])) {
    }
    return self;
}

- (void)dealloc {
    if (!_timerRunning) {
        dispatch_resume(_timer);
    }
}

- (void)windowDidLoad {

    self.audioPlayer = [[AudioPlayer alloc] initWithDevice:Settings.audioOutputDeviceName
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
    self.currentTimeTextField.layer.shouldRasterize = true;
    self.currentTimeTextField.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    self.currentTimeTextField.font = [Fonts fontForNumbers:self.currentTimeTextField.font.pointSize bold:YES];

    self.albumArtImageView.wantsLayer = YES;
    self.albumArtImageView.layer.shadowRadius = 6;
    self.albumArtImageView.layer.shadowOpacity = 0.25;
    self.albumArtImageView.layer.shadowOffset = CGSizeMake(4, 0);
    self.albumArtImageView.layer.masksToBounds = NO;
    self.albumArtImageView.layer.shouldRasterize = true;
    self.albumArtImageView.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;

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

    // self.playlistTableView
    self.playlistTableView.delegate = self.self.playlistManager;
    self.playlistTableView.dataSource = self.self.playlistManager;

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / UPDATE_HZ, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(_timer, ^{
        [self updatePlaybackUI];
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

    if (track) {
        if (track.hasArtistAndTitle) {
            self.artistTextField.stringValue = track.artist;
            self.titleTextField.stringValue = track.title;
        }
        else {
            self.artistTextField.stringValue = @"";
            self.titleTextField.stringValue = track.singleLineTitle;
        }
        self.totalTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:self.audioPlayer.duration];
        if (track.metadata.fileType) {
            NSString *bitrate = @"";
            if (!track.metadata.isLossless) {
                bitrate = [NSString stringWithFormat:@"%@ kbps | ", track.metadata.bitrate];
            }
            NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
            paragraph.alignment = NSTextAlignmentRight;
            self.fileMetadataTextField.attributedStringValue = [[NSMutableAttributedString alloc] initWithString:
                                                                [NSString stringWithFormat:@"%@ | %@%.1f kHz", track.metadata.fileType, bitrate, ([track.metadata.sampleRate doubleValue]/1000)]
                                                                                                      attributes:@{
                                                                    NSKernAttributeName:@(-1.2),
                                                                    NSParagraphStyleAttributeName:paragraph,
                                                                }];
        }
        else {
            self.fileMetadataTextField.stringValue = @"";
        }
    }
    else {
        self.artistTextField.stringValue = @"";
        self.titleTextField.stringValue = @"";
        self.totalTimeTextField.stringValue = @"";
        self.currentTimeTextField.stringValue = @"";
        self.fileMetadataTextField.stringValue = @"";
    }

    self.albumArtImageView.fileURL = track.url;

    if (track.albumArt) {
        if (_displayedArt != track.albumArt) {
            self.albumArtImageView.image = track.albumArt;
            [NSDockTile setDockIcon:self.playlistManager.currentTrack.albumArt];
            _displayedArt = track.albumArt;
        }
    }
    else {
        if (_displayedArt) {
            self.albumArtImageView.image = [NSImage imageNamed:@"record"];
            [NSDockTile resetToAppIcon];
            _displayedArt = nil;
        }
    }

    [self.playlistManager reloadCurrentTrack];
    [self updatePlaybackUI];
}

- (void)updatePlaybackUI {

    BOOL trackLoaded = self.playlistManager.currentTrack != nil;

    self.totalTimeTextField.hidden = !trackLoaded;
    self.currentTimeTextField.hidden = !trackLoaded;
    self.waveformView.hidden = !trackLoaded;

    if (trackLoaded) {
        NSTimeInterval duration = self.audioPlayer.duration;
        NSTimeInterval position = self.audioPlayer.position;
        if (duration > 0) {
            self.waveformView.progress = (float) position / (float) duration;
        }
        if (round(position) != round(_lastPosition)) {
            self.currentTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:position];
            _lastPosition = position;
        }
    }
}

- (IBAction)playPause:(id)sender {
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
    [self.metadataManager loadMetadata:self.playlistManager.playlist];
}

- (IBAction)next:(id)sender {
    [self.playlistManager next];
    [self updateUI];
}

- (IBAction)previous:(id)sender {
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

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track  {
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:track.url];
    [self.waveformView loadWaveformForTrack:track];
    [self.playlistManager reloadCurrentTrack];
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
    [self pauseUIUpdateTimer];
    [self next:self];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    [alert addButtonWithTitle:@"Ok"];
    [alert setMessageText:@"AudioPlayer Error"];
    [alert setInformativeText:error.userInfo[NSLocalizedDescriptionKey]];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert runModal];
    [self.playlistManager next];
}

- (void)audioPlayerDidInitialize:(AudioPlayer *)audioPlayer {

}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didChangeOuputDevice:(NSInteger)newDeviceIndex {
    LogDebug(@"MainPlayerController: didChangeOutputDevice: %zd", newDeviceIndex);
    if (newDeviceIndex == -1) {
        Settings.audioOutputDeviceName = @"";
    }
    else {
        AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForId:newDeviceIndex];
        Settings.audioOutputDeviceName = device.name;
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishSeeking:(AudioTrack *)track {
    [self updatePlaybackUI];
    self.waveformView.needsDisplay = YES;
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

//- (NSTouchBar *)makeTouchBar {
//    return [[PlayerTouchBar alloc] init];
//}


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
