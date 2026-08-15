//
//  MainPlayerController+Transport.h
//  Vibe
//
//  The relative-seek skips, bar-aligned when the track's tempo is known, and
//  the DJ performance-effect pass-throughs. They touch only the public
//  collaborators, never internal state.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Transport)

// Seeks relative to the current position. With a known tempo the three sizes
// are Settings.skipBaseBars, twice it and four times it; without one they fall
// back to fixed wall-clock distances, the units the time labels show. Going
// forward past the end advances to the next track, or stops at the end of the
// playlist; going back before the start seeks to 0.
- (IBAction)skipForward:(nullable id)sender;      // +base bars (+10s without BPM)
- (IBAction)skipForwardMore:(nullable id)sender;  // +2× base (+30s without BPM)
- (IBAction)skipForwardMost:(nullable id)sender;  // +4× base (+60s without BPM)
- (IBAction)skipBack:(nullable id)sender;         // −base bars (−10s without BPM)
- (IBAction)skipBackMore:(nullable id)sender;     // −2× base (−30s without BPM)
- (IBAction)skipBackMost:(nullable id)sender;     // −4× base (−60s without BPM)

// One toggle per performance effect, for the FX menu. The bare keys do not use
// these: they go through the getter and setter pairs below, so that their hold
// mode can restore the pre-press state.
- (IBAction)toggleLowKill:(nullable id)sender;           // Q — low-kill high-pass
- (IBAction)toggleLowKillBoost:(nullable id)sender;      // W — double Q's cutoff
- (IBAction)toggleReverbSend:(nullable id)sender;        // E — reverb wash
- (IBAction)toggleDelaySend:(nullable id)sender;         // R — 1/8-note echo
- (IBAction)toggleShortDelaySend:(nullable id)sender;    // T — 1/16-note echo

// The performance-effect state pass-throughs, one getter and setter pair per
// effect: Q is low kill, W is the low-kill boost that doubles Q's cutoff, E is
// the reverb send, R is the 1/8-note delay echo send and T is the same echo on
// 1/16 taps. TransportKeyMonitor drives them for its tap-against-hold state
// machine, reading the state at keyDown, flipping it, and perhaps restoring it
// at keyUp. The FX menu's toggles above are written in terms of them, and the
// debug command channel uses the setters directly.
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

// Pushes the live AudioFX flags to the header's FX indicator symbols. The five
// setters above call it, so every path that can change an effect — a menu
// item, a bare key whether tapped or held, a debug command — refreshes the
// display without each caller having to remember. The updateUI funnel calls it
// too.
- (void)updateFXIndicators;

@end

NS_ASSUME_NONNULL_END
