//
//  MainPlayerController.h
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

#import "AudioPlayer.h"
#import "AudioTrackMetadata.h"
#import "AudioWaveformView.h"
#import "PlaylistManager.h"

#import "MainWindow.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController : NSWindowController <NSMenuDelegate,
                                                      FileDropDelegate,
                                                      AudioPlayerDelegate,
                                                      AudioWaveformViewDelegate>

@property (weak) IBOutlet NSImageView *nextButton;
@property (weak) IBOutlet NSImageView *playButton;

@property (weak) IBOutlet NSTableView *playlistTableView;
@property (weak) IBOutlet NSTextField *artistTextField;
@property (weak) IBOutlet NSTextField *titleTextField;
@property (weak) IBOutlet NSImageView *albumArtImageView;
@property (weak) IBOutlet AudioWaveformView *waveformView;
@property (weak) IBOutlet NSTextField *totalTimeTextField;
@property (weak) IBOutlet NSTextField *currentTimeTextField;
@property (weak) IBOutlet NSView *playlistBackgroundView;
@property (weak) IBOutlet NSView *albumArtGradientView;

@property (strong) AudioTrackMetadata *metadata;

@property (strong) PlaylistManager *playlistManager;
@property (strong) AudioPlayer *audioPlayer;

- (IBAction)playPause:(id)sender;
- (IBAction)next:(id)sender;

- (IBAction)setSmallSize:(id)sender;

- (IBAction)setLargeSize:(id)sender;

- (IBAction)toggleSize:(id)sender;
@end

NS_ASSUME_NONNULL_END
