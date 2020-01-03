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
#import "SYFlatButton.h"
#import "AudioTrackMetadataCache.h"

@class OutputDevicesMenuController;
@class ArtworkImageView;
@class AudioTrackMetadataCache;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController : NSWindowController <NSMenuItemValidation,
                                                      NSMenuDelegate,
                                                      FileDropDelegate,
                                                      AudioPlayerDelegate,
                                                      AudioWaveformViewDelegate,
                                                      AudioTrackMetadataManagerDelegate>

@property (weak) IBOutlet SYFlatButton *nextButton;
@property (weak) IBOutlet SYFlatButton *playButton;

@property (weak) IBOutlet NSTableView *playlistTableView;
@property (weak) IBOutlet NSTextField *artistTextField;
@property (weak) IBOutlet NSTextField *titleTextField;
@property (weak) IBOutlet ArtworkImageView *albumArtImageView;
@property (weak) IBOutlet AudioWaveformView *waveformView;
@property (weak) IBOutlet NSTextField *totalTimeTextField;
@property (weak) IBOutlet NSTextField *currentTimeTextField;
@property (weak) IBOutlet NSView *playlistBackgroundView;
@property (weak) IBOutlet NSView *albumArtGradientView;

@property (weak) IBOutlet OutputDevicesMenuController *devicesMenuController;

@property (strong) AudioTrackMetadata *metadata;

@property (strong) AudioPlayer *audioPlayer;
@property (strong) PlaylistManager *playlistManager;
@property (strong) AudioTrackMetadataCache *metadataManager;

- (void)play:(NSArray<NSURL *> *)urls;
- (void)playURL:(NSURL *)url;


- (IBAction)playPause:(id)sender;
- (IBAction)next:(id)sender;

- (IBAction)setSmallSize:(id)sender;
- (IBAction)setLargeSize:(id)sender;
- (IBAction)toggleSize:(id)sender;

- (IBAction)showInFinder:(id)sender;

- (IBAction)setAppearance:(id)sender;
@end

NS_ASSUME_NONNULL_END
