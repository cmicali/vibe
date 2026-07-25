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

// Seek relative to the current position, in wall-clock seconds (the units the
// time labels show). Forward past the end advances to the next track or stops
// at the end of the playlist; back before the start seeks to 0.
- (IBAction)skipForward:(nullable id)sender;      // +8 bars (+10s without BPM)
- (IBAction)skipForwardMore:(nullable id)sender;  // +16 bars (+30s without BPM)
- (IBAction)skipForwardMost:(nullable id)sender;  // +32 bars (+60s without BPM)
- (IBAction)skipBack:(nullable id)sender;         // −8 bars (−10s without BPM)
- (IBAction)skipBackMore:(nullable id)sender;     // −16 bars (−30s without BPM)
- (IBAction)skipBackMost:(nullable id)sender;     // −32 bars (−60s without BPM)

// DJ-style low kill: toggle a high-pass filter on the master bus (bare Q key).
- (IBAction)toggleLowKill:(nullable id)sender;

// Momentary effects, driven by holding a bare key (down = YES, up = NO):
// W = low-kill boost (double Q's cutoff), E = reverb send, R = 1/8-note
// delay echo send, T = the same echo on 1/16 taps. Not IBActions — a hold
// has no menu-item equivalent.
- (void)setLowKillBoostActive:(BOOL)active;
- (void)setReverbSendActive:(BOOL)active;
- (void)setDelaySendActive:(BOOL)active;
- (void)setShortDelaySendActive:(BOOL)active;

- (IBAction)setSmallSize:(id)sender;
- (IBAction)setLargeSize:(id)sender;
- (IBAction)toggleSize:(nullable id)sender;

- (IBAction)togglePitchPanel:(nullable id)sender;
- (IBAction)setPitchRange:(id)sender;

- (IBAction)showInFinder:(id)sender;

- (IBAction)setAppearance:(id)sender;

@end

NS_ASSUME_NONNULL_END
