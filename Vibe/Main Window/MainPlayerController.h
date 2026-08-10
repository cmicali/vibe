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
@class AudioFileConverter;
@class OutputDevicesMenuController;

NS_ASSUME_NONNULL_BEGIN

// The central coordinator for the main window. View outlets and most protocol
// conformances are internal, in the class extension in the implementation, and
// the debug command channel's extra surface lives in
// MainPlayerController+Debug.h. NSMenuDelegate stays public because
// MainMenuBuilder wires the controller as the waveform-style submenu's
// delegate.
@interface MainPlayerController : NSWindowController <NSMenuDelegate>

// The collaborators, created in init. MainMenuBuilder wires
// devicesMenuController as the Output menu's delegate.
@property (strong) OutputDevicesMenuController *devicesMenuController;
@property (strong) AudioPlayer *audioPlayer;
@property (strong) PlaylistController *playlistController;
@property (strong) AudioTrackMetadataCache *metadataCache;
@property (strong) AudioWaveformCache *waveformCache;
// Convert to FLAC's engine. The controller owns it because it also owns the
// swap afterwards, and every menu's item validates against it.
@property (strong) AudioFileConverter *fileConverter;

- (void)play:(NSArray<NSURL *> *)urls;

// The varispeed playback rate, 1.0 + pitch/100: the track plays this much
// faster or slower than file time. The time labels, and the Now Playing
// publish, show file time divided by it, and the bar-less skip fallback
// multiplies by it. The Transport and NowPlaying categories read it.
- (double)playbackRate;

// Appends to the current playlist without disturbing playback, and starts
// playing when the playlist is empty. The later batches of AppDelegate's open
// burst land here.
- (void)addURLs:(NSArray<NSURL *> *)urls;

// Ends the launch grace period. The header starts blank rather than flashing
// the empty state while a launch-time open, from a Finder double-click or
// argv, is still resolving. The app delegate calls this once it knows nothing
// is being opened, and play: ends the grace on its own. Idempotent.
- (void)revealEmptyState;

- (IBAction)closeApp:(id)sender;
- (IBAction)minimizeWindow:(id)sender;

- (IBAction)playPause:(nullable id)sender;
- (IBAction)next:(nullable id)sender;
- (IBAction)previous:(nullable id)sender;

// File > Close (⌘W). It stops playback, clears the playlist and returns the
// app to the empty state.
- (IBAction)closeFile:(nullable id)sender;

// MainPlayerController+Transport.h declares, and implements, the
// relative-seek skips and the DJ effect toggles.

- (IBAction)toggleSize:(nullable id)sender;
- (IBAction)setWindowSize:(id)sender;

- (IBAction)togglePitchPanel:(nullable id)sender;
- (IBAction)setPitchRange:(id)sender;

// Pushes Settings.pitchRange to the player and the fader UI. The Settings
// pane calls it after writing the setting; the menu action funnels through it
// too.
- (void)applyPitchRange;

// Re-renders the time labels after Settings.showRemainingTime changes
// somewhere other than the label click, i.e. the Settings pane.
- (void)refreshTimeDisplay;

- (IBAction)showInFinder:(id)sender;
- (IBAction)copyFile:(id)sender;
- (IBAction)copyName:(id)sender;

// The Convert to FLAC and undo/redo actions live in
// MainPlayerController+Convert.h, like the Transport actions.

- (IBAction)setAppearance:(id)sender;

@end

NS_ASSUME_NONNULL_END
