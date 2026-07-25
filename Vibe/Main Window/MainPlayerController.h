//
//  MainPlayerController.h
//  Vibe
//
//  Created by Christopher Micali on 12/15/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@class AudioPlayer;
@class PlaylistController;
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
@property (strong) PlaylistController *playlistController;
@property (strong) AudioTrackMetadataCache *metadataCache;
@property (strong) AudioWaveformCache *waveformCache;

- (void)play:(NSArray<NSURL *> *)urls;
- (void)playURL:(NSURL *)url;

// Varispeed playback rate (1.0 + pitch/100): the track plays this much faster
// or slower than file time; the time labels (and the Now Playing publish)
// show file time divided by it, and the bar-less skip fallback multiplies by
// it. Read by the Transport and NowPlaying categories.
- (double)playbackRate;

// Appends to the current playlist without disturbing playback (plays when the
// playlist is empty). Later batches of AppDelegate's open burst land here.
- (void)addURLs:(NSArray<NSURL *> *)urls;

// Ends the launch grace period: the header starts blank rather than flashing
// the empty state while a launch-time open (Finder double-click, argv) is
// still resolving. The app delegate calls this once it knows nothing is being
// opened; play: ends the grace on its own. Idempotent.
- (void)revealEmptyState;

- (IBAction)closeApp:(id)sender;
- (IBAction)minimizeWindow:(id)sender;

- (IBAction)playPause:(nullable id)sender;
- (IBAction)next:(nullable id)sender;
- (IBAction)previous:(nullable id)sender;

// File > Close (⌘W): stops playback, clears the playlist, and returns the app
// to the empty state.
- (IBAction)closeFile:(nullable id)sender;

// The relative-seek skips and the DJ effect toggles are declared (and
// implemented) in MainPlayerController+Transport.h.

- (IBAction)setSmallSize:(id)sender;
- (IBAction)setLargeSize:(id)sender;
- (IBAction)toggleSize:(nullable id)sender;

- (IBAction)togglePitchPanel:(nullable id)sender;
- (IBAction)setPitchRange:(id)sender;

- (IBAction)showInFinder:(id)sender;

- (IBAction)setAppearance:(id)sender;

@end

NS_ASSUME_NONNULL_END
