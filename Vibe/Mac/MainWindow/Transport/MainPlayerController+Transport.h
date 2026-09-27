//
//  MainPlayerController+Transport.h
//  Vibe
//
//  The relative-seek skips and the performance-effect pass-throughs.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Transport)

// With a known tempo: AppSettings.skipBaseBars, twice and four times it; else
// wall-clock seconds. Past the end finishes the track; before the start seeks
// to 0.
- (IBAction)skipForward:(nullable id)sender;      // +base bars (+10s without BPM)
- (IBAction)skipForwardMore:(nullable id)sender;  // +2× base (+30s without BPM)
- (IBAction)skipForwardMost:(nullable id)sender;  // +4× base (+60s without BPM)
- (IBAction)skipBack:(nullable id)sender;         // −base bars (−10s without BPM)
- (IBAction)skipBackMore:(nullable id)sender;     // −2× base (−30s without BPM)
- (IBAction)skipBackMost:(nullable id)sender;     // −4× base (−60s without BPM)

// For the FX menu. The bare keys use the pairs below, so a hold can restore the
// pre-press state.
- (IBAction)toggleLowKill:(nullable id)sender;           // Q — low-kill high-pass
- (IBAction)toggleLowKillBoost:(nullable id)sender;      // W — double Q's cutoff
- (IBAction)toggleReverbSend:(nullable id)sender;        // E — reverb wash
- (IBAction)toggleDelaySend:(nullable id)sender;         // R — 1/8-note echo
- (IBAction)toggleShortDelaySend:(nullable id)sender;    // T — 1/16-note echo

// The single funnel for menus, keys and debug commands.
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

// The five setters and updateUI call it, so no caller has to remember.
- (void)updateFXIndicators;

// One sentence, shared by the header's open-lock tooltip and the Settings >
// Audio caption so the two cannot disagree.
- (NSString *)bitPerfectStatusText;

@end

NS_ASSUME_NONNULL_END
