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

// One toggle per performance effect, for the FX menu. The bare keys don't use
// these — they go through the getter/setter pairs below, so their hold mode can
// restore the pre-press state.
- (IBAction)toggleLowKill:(nullable id)sender;           // Q — low-kill high-pass
- (IBAction)toggleLowKillBoost:(nullable id)sender;      // W — double Q's cutoff
- (IBAction)toggleReverbSend:(nullable id)sender;        // E — reverb wash
- (IBAction)toggleDelaySend:(nullable id)sender;         // R — 1/8-note echo
- (IBAction)toggleShortDelaySend:(nullable id)sender;    // T — 1/16-note echo

// Performance-effect state pass-throughs, one getter/setter pair per effect:
// Q = low kill, W = low-kill boost (double Q's cutoff), E = reverb send,
// R = 1/8-note delay echo send, T = the same echo on 1/16 taps.
// TransportKeyMonitor drives these for its tap-vs-hold state machine (read
// state at keyDown, flip it, maybe restore it at keyUp), the FX menu's toggles
// above are written in terms of them, and the debug command channel uses the
// setters directly.
- (BOOL)lowKillActive;
- (void)setLowKillActive:(BOOL)active;
- (BOOL)lowKillBoostActive;
- (void)setLowKillBoostActive:(BOOL)active;
- (BOOL)reverbSendActive;
- (void)setReverbSendActive:(BOOL)active;
- (BOOL)delaySendActive;
- (void)setDelaySendActive:(BOOL)active;
- (BOOL)shortDelaySendActive;
- (void)setShortDelaySendActive:(BOOL)active;

@end

NS_ASSUME_NONNULL_END
