//
//  MainPlayerController+Transport.h
//  Vibe
//
//  The relative-seek skips (bar-aligned when the track's tempo is known) and
//  the DJ performance-effect pass-throughs, split from the main
//  implementation purely for file size, like MainPlayerController+Menus.
//  Touches only the public collaborators — no internal state. The actions are
//  declared here rather than in MainPlayerController.h (same pattern as the
//  Menus category's setWaveformStyle:) so the compiler checks their
//  implementation in this file.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Transport)

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

@end

NS_ASSUME_NONNULL_END
