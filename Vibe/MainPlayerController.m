//
//  MainPlayerController.m
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "MainPlayerController.h"
#import "PlaylistManager.h"
#import "AudioPlayer.h"
#import "AudioWaveformView.h"
#import "AudioPlayer.h"
#import "NSDockTile+Util.h"
#import "SYFlatButton.h"
#import <CocoaLumberjack/CocoaLumberjack.h>

#define UPDATE_HZ 10

@interface MainPlayerController ()

@end

@implementation MainPlayerController {
    dispatch_source_t   _timer;
    NSDateComponentsFormatter *_timeFormatter;
}

- (id) init {
    if((self = [super initWithWindowNibName:@"MainPlayerWindow"])) {
    }
    return self;
}

- (void)windowDidLoad {

    LogInfo(@"Hello lydia!");

    _timeFormatter = [[NSDateComponentsFormatter alloc] init];
    _timeFormatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    _timeFormatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropAll;
    self.audioPlayer = [[AudioPlayer alloc] init];

    self.audioPlayer.delegate = self;
    self.playlistManager = [[PlaylistManager alloc] initWithAudioPlayer:self.audioPlayer];

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
    self.artistTextField.layer.opacity = 0.35;
    self.titleTextField.wantsLayer = YES;
    self.titleTextField.layer.opacity = 0.8;
    self.totalTimeTextField.wantsLayer = YES;
    self.totalTimeTextField.layer.opacity = 0.6;

    self.albumArtImageView.wantsLayer = YES;
    self.albumArtImageView.shadow = [[NSShadow alloc] init];
    self.albumArtImageView.layer.shadowRadius = 4;
    self.albumArtImageView.layer.shadowOffset = CGSizeMake(4, 0);
    self.albumArtImageView.layer.shadowOpacity = 1;

    self.playlistBackgroundView.wantsLayer = YES;
    self.playlistBackgroundView.layer.opacity = 1.0;
    self.playlistBackgroundView.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.5].CGColor;
    self.waveformView.delegate = self;

    self.playlistTableView.delegate = self.self.playlistManager;
    self.playlistTableView.dataSource = self.self.playlistManager;
    self.playlistManager.tableView = self.playlistTableView;

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / UPDATE_HZ, NSEC_PER_SEC / 3);
    dispatch_source_set_event_handler(_timer, ^{
        [self timerHandler];
    });
    dispatch_resume(_timer);

    [self reloadData];

    [NSApp activateIgnoringOtherApps:YES];
}

- (void)updatePlayingUI {

    self.playButton.enabled = self.playlistManager.count > 0;
    self.nextButton.enabled = self.playlistManager.count > 0;

    self.titleTextField.stringValue = self.playlistManager.currentTrack.title;
    self.artistTextField.stringValue = self.playlistManager.currentTrack.artist;
    self.totalTimeTextField.stringValue = [_timeFormatter stringFromTimeInterval:self.audioPlayer.duration];

    if (self.playlistManager.currentTrack.albumArt) {
        self.albumArtImageView.image = self.playlistManager.currentTrack.albumArt;
        [NSDockTile setDockIcon:self.playlistManager.currentTrack.albumArt];
    }
    else {
        self.albumArtImageView.image = [NSImage imageNamed:@"record-black-1024.png"];
        [NSDockTile resetToAppIcon];
    }
}

- (void)reloadData {
    [self updatePlayingUI];
    [self.playlistTableView reloadData];
    __block MainPlayerController *weakSelf = (MainPlayerController *)self;
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        [weakSelf.playlistTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:self.playlistManager.currentIndex] byExtendingSelection:NO];
    });
}

- (void)timerHandler {

    NSTimeInterval duration = self.audioPlayer.duration;
    NSTimeInterval position = self.audioPlayer.position;

    self.waveformView.progress = (float)position / (float)duration;
    self.currentTimeTextField.stringValue = [_timeFormatter stringFromTimeInterval:position];

}

- (void)playURL:(NSURL *)url {
    [self.playlistManager reset:@[url]];
}

- (IBAction)playPause:(id)sender {
    [self.audioPlayer playPause];
}

- (IBAction)next:(id)sender {
    [self.playlistManager next];
}

- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *> *)urls {
    [self.playlistManager reset:urls];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartPlaying:(AudioTrack *)track  {
    self.waveformView.waveform = self.audioPlayer.audioWaveform;
    [self reloadData];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishPlaying:(AudioTrack *)track {
    [self next:nil];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didLoadMetadata:(AudioTrack *)track  {
    [self reloadData];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer error:(NSError *)error {
    [self.playlistManager next];
}

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage {
    self.audioPlayer.position = self.audioPlayer.duration * percentage;
    [self timerHandler];
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

@end
