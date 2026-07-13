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
#import "PitchControlPanel.h"

@class OutputDevicesMenuController;
@class ArtworkImageView;
@class BackgroundArtworkImageView;
@class AudioTrackMetadataCache;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController : NSWindowController <NSMenuItemValidation,
                                                      NSMenuDelegate,
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

@property (strong) OutputDevicesMenuController *devicesMenuController;

@property (strong) AudioPlayer *audioPlayer;
@property (strong) PlaylistManager *playlistManager;
@property (strong) AudioTrackMetadataCache *metadataCache;

- (void)play:(NSArray<NSURL *> *)urls;
- (void)playURL:(NSURL *)url;

- (IBAction)closeApp:(id)sender;

- (IBAction)playPause:(nullable id)sender;
- (IBAction)next:(nullable id)sender;
- (IBAction)previous:(nullable id)sender;

- (IBAction)setSmallSize:(id)sender;
- (IBAction)setLargeSize:(id)sender;
- (IBAction)toggleSize:(nullable id)sender;

- (IBAction)togglePitchPanel:(nullable id)sender;
- (IBAction)setPitchRange:(id)sender;

- (IBAction)showInFinder:(id)sender;

- (IBAction)setAppearance:(id)sender;

#if DEBUG
// Debug command channel (Util/DebugUtil.mm) drives the app through these;
// not part of the normal UI surface.
- (PitchControlPanel *)pitchPanel;
- (void)debugRefreshUI;
#endif
@end

NS_ASSUME_NONNULL_END
