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

@interface MainPlayerController ()

@end

@implementation MainPlayerController

- (id) init {
    if((self = [super initWithWindowNibName:@"MainPlayerWindow"])) {
        self.audioPlayer = [[AudioPlayer alloc] init];
        self.audioPlayer.delegate = self;
        self.playlistManager = [[PlaylistManager alloc] initWithAudioPlayer:self.audioPlayer];
    }
    return self;
}


- (void)windowDidLoad {

    [super windowDidLoad];

    self.window.styleMask = NSWindowStyleMaskBorderless |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskFullSizeContentView
    ;
    [self.window setMovableByWindowBackground:YES];
    self.window.backgroundColor = [NSColor clearColor];
    self.window.opaque = NO;
    self.window.contentView.wantsLayer = YES;
    self.window.contentView.layer.cornerRadius = 5;
    self.window.contentView.layer.borderColor = [NSColor.blackColor colorWithAlphaComponent:0.5].CGColor;
    self.window.contentView.layer.borderWidth = 1;
    [self.window invalidateShadow];

    [self setup];

    [NSApp activateIgnoringOtherApps:YES];
}

- (void)setup {

    self.artistTextField.wantsLayer = YES;
    self.artistTextField.layer.opacity = 0.35;
    self.titleTextField.wantsLayer = YES;
    self.titleTextField.layer.opacity = 0.8;

    self.playlistTableView.delegate = self.self.playlistManager;
    self.playlistTableView.dataSource = self.self.playlistManager;

    MainWindow *window = (MainWindow *)self.window;
    window.dropDelegate = self;

    [self reloadData];

}

- (void)reloadData {
    if (self.playlistManager.currentTrack.url) {
        [self.waveformView setDisabled:NO];
        [self.waveformView openAudioURL:self.playlistManager.currentTrack.url startFrame:0 withLength:self.audioPlayer.totalFrames];
    }
    self.titleTextField.stringValue = self.playlistManager.currentTrack.title;
    self.artistTextField.stringValue = self.playlistManager.currentTrack.artist;
    self.albumArtImageView.image = self.playlistManager.currentTrack.albumArt;
    [self.playlistTableView reloadData];
}

- (void)play:(NSURL *)url {
    [self.playlistManager reset:@[url]];
}

- (void)mainWindow:(MainWindow *)mainWindow filesDropped:(NSArray<NSURL *> *)urls {
    [self.playlistManager reset:urls];
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartRenderingURL:(NSURL *)url {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishRenderingURL:(NSURL *)url {
    audioPlayer.delegate;
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didStartDecodingURL:(NSURL *)url {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didFinishDecodingURL:(NSURL *)url {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didMakePlaybackProgress:(NSURL *)url {
}

- (void)audioPlayer:(AudioPlayer *)audioPlayer didLoadMetadata:(NSURL *)url {
    [self reloadData];
}

@end
