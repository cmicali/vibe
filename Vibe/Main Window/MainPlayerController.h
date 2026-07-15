//
//  MainPlayerController.h
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class AudioPlayer;
@class PlaylistManager;
@class AudioTrackMetadataCache;
@class AudioWaveformCache;
@class OutputDevicesMenuController;

NS_ASSUME_NONNULL_BEGIN

// Central coordinator for the main window. View outlets and most protocol
// conformances are internal (class extension in the implementation); the
// debug command channel's extra surface lives in MainPlayerController+Debug.h.
// NSMenuDelegate stays public: MainMenuBuilder wires the controller as the
// waveform-style submenu's delegate.
@interface MainPlayerController : NSWindowController <NSMenuDelegate>

// Collaborators (created in init). devicesMenuController is wired as the
// Output menu's delegate by MainMenuBuilder.
@property (strong) OutputDevicesMenuController *devicesMenuController;
@property (strong) AudioPlayer *audioPlayer;
@property (strong) PlaylistManager *playlistManager;
@property (strong) AudioTrackMetadataCache *metadataCache;
@property (strong) AudioWaveformCache *waveformCache;

- (void)play:(NSArray<NSURL *> *)urls;
- (void)playURL:(NSURL *)url;

- (IBAction)closeApp:(id)sender;
- (IBAction)minimizeWindow:(id)sender;

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

@end

NS_ASSUME_NONNULL_END
