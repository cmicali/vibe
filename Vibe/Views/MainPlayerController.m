//
//  MainPlayerController.m
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "MainPlayerController.h"
#import "NSDockTile+Util.h"
#import "MacOSUtil.h"
#import "PlayerTouchBar.h"
#import "DevicesMenuController.h"
#import "AppDelegate.h"
#import "Formatters.h"
#import "Fonts.h"

#define UPDATE_HZ 3

@interface MainPlayerController ()

@end

@implementation MainPlayerController {
    dispatch_source_t   _timer;
    NSTimeInterval      _lastPosition;
    BOOL                _timerRunning;
    __weak NSImage*     _displayedArt;
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

    self.audioPlayer = [[AudioPlayer alloc] initWithDevice:Settings.audioPlayerCurrentDevice];
    self.audioPlayer.delegate = self;

    self.playlistManager = [[PlaylistManager alloc] initWithAudioPlayer:self.audioPlayer];
    self.playlistManager.tableView = self.playlistTableView;

    self.devicesMenuController.audioPlayer = self.audioPlayer;

    // Setup Views

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

    self.totalTimeTextField.font = [Fonts fontForNumbers:self.currentTimeTextField.font.pointSize];
    self.currentTimeTextField.font = [Fonts fontForNumbers:self.currentTimeTextField.font.pointSize];

    self.albumArtImageView.wantsLayer = YES;
    self.albumArtImageView.shadow = [[NSShadow alloc] init];
    self.albumArtImageView.layer.shadowRadius = 4;
    self.albumArtImageView.layer.shadowOffset = CGSizeMake(4, 0);
    self.albumArtImageView.layer.shadowOpacity = 1;

    if ([MacOSUtil isDarkMode:self.window.appearance]) {
        self.playlistBackgroundView.wantsLayer = YES;
        self.playlistBackgroundView.layer.opacity = 1.0;
        self.playlistBackgroundView.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.5].CGColor;
    }
    else {
        self.playlistBackgroundView.hidden = YES;
    }

    self.waveformView.delegate = self;

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
    }
    else {
        self.artistTextField.stringValue = @"";
        self.titleTextField.stringValue = @"";
        self.totalTimeTextField.stringValue = @"";
        self.currentTimeTextField.stringValue = @"";
    }

    if (track.albumArt) {
        if (_displayedArt != track.albumArt) {
            self.albumArtImageView.image = track.albumArt;
            [NSDockTile setDockIcon:self.playlistManager.currentTrack.albumArt];
            _displayedArt = track.albumArt;
        }
    }
    else {
        if (_displayedArt) {
            self.albumArtImageView.image = [NSImage imageNamed:@"record-black-1024.png"];
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
        self.waveformView.progress = (float) position / (float) duration;
        if (round(position) != round(_lastPosition)) {
            self.currentTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:position];
            _lastPosition = position;
        }
    }
}

- (void)playURL:(NSURL *)url {
    [self.playlistManager play:@[url]];
}

- (void)playURLs:(NSArray<NSURL *> *)urls {
    [self.playlistManager play:urls];
}

- (IBAction)playPause:(id)sender {
    if (self.audioPlayer.isStopped) {
        [self.playlistManager play];
    }
    else {
        [self.audioPlayer playPause];
    }
}

- (IBAction)next:(id)sender {
    [self.playlistManager next];
    [self updateUI];
}

- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *> *)urls {
    [self.playlistManager play:urls];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track  {
    [self.waveformView loadWaveformForTrack:track];
    [self resumeUIUpdateTimer];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didPausePlaying:(AudioTrack *)track {
    [self pauseUIUpdateTimer];
    [self updateUI];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didResumePlaying:(AudioTrack *)track {
    [self resumeUIUpdateTimer];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    [self pauseUIUpdateTimer];
    [self next:self];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didLoadMetadata:(AudioTrack *)track  {
    [self.playlistManager reloadTrack:track];
    if (self.playlistManager.currentTrack == track) {
        [self updateUI];
    }
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishLoadingMetadata:(NSUInteger)numTracks {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    [self.playlistManager next];
}

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage {
    self.audioPlayer.position = self.audioPlayer.duration * percentage;
    [self updatePlaybackUI];
    self.waveformView.needsDisplay = YES;
}

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

- (NSTouchBar *)makeTouchBar {
    return [[PlayerTouchBar alloc] init];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    MainWindow *window = (MainWindow *)self.window;
    if ([menuItem.identifier isEqualToString:@"menu_show_playlist"]) {
        menuItem.state = window.isPlaylistShown ? NSControlStateValueOn : NSControlStateValueOff;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_next_track"]) {
        return self.playlistManager.count > 1;
    }
    else if ([menuItem.identifier isEqualToString:@"menu_play"]) {
        return self.playlistManager.count > 0;
    }
    return YES;
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
