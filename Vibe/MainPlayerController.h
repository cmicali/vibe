//
//  MainPlayerController.h
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "PlaylistManager.h"
#import "AudioPlayer.h"
#import "AudioTrackMetadata.h"
#import "MainWindow.h"

#import "Vibe-Swift.h"

@class AudioWaveformView;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController : NSWindowController <AudioPlayerDelegate, FileDropDelegate>

@property (weak) IBOutlet NSButton *playButton;
@property (weak) IBOutlet NSTableView *playlistTableView;
@property (weak) IBOutlet NSTextField *artistTextField;
@property (weak) IBOutlet NSTextField *titleTextField;
@property (weak) IBOutlet NSImageView *albumArtImageView;
@property (weak) IBOutlet WaveFormViewOSX *waveformView;

@property (strong) AudioTrackMetadata *metadata;

@property (strong) PlaylistManager *playlistManager;
@property (strong) AudioPlayer *audioPlayer;

@end

NS_ASSUME_NONNULL_END
