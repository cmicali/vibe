//
//  AudioFX.h
//  Vibe
//

#import <Foundation/Foundation.h>

@class AVAudioEngine;

NS_ASSUME_NONNULL_BEGIN

// The DJ performance effects on the master bus: the low-kill high-pass (Q
// toggle + held-W boost) and the momentary send/returns (E reverb wash,
// R/T ping-pong delays). Owns the FX segment of the engine graph —
// everything between the main mixer and the output node:
//
//   mainMixer -> lowKillEQ -+-> masterMix -> output
//                           +-> reverb send/return       -> masterMix
//                           +-> 1/8 delay send/return    -> masterMix
//                           +-> 1/16 delay send/return   -> masterMix
//
// Downstream of the per-track player/varispeed chains, so track changes,
// seeks, and the crossfade never touch it.
//
// Threading mirrors AudioPlayer: property setters record lock-guarded intent
// and dispatch the graph/parameter work onto the player's serial engine
// queue; the ramp/sweep state is queue-confined. The object is created
// before the engine exists (AudioPlayer's synchronous init) so intent set
// early — a menu action or the BPM feed racing the async engine init — is
// never lost; installInEngine: applies whatever was recorded.
@interface AudioFX : NSObject

// queue: the player's serial engine queue — every mutation this class makes
// runs there.
- (instancetype)initWithQueue:(dispatch_queue_t)queue;

// Builds, attaches, and wires the whole FX segment, then applies any intent
// recorded before the engine existed. Must run ON the queue, once, before
// the engine first starts (called from AudioPlayer's async init).
- (void)installInEngine:(AVAudioEngine *)engine;

// DJ-style low kill: a resonant high-pass filter on the master bus that cuts
// the bass. A deck control — it persists across tracks and applies to
// whatever is (or starts) playing. Toggling sweeps the cutoff over ~80ms
// rather than switching instantly, so it never clicks.
@property (nonatomic) BOOL lowKillEnabled;

// Momentary boost of the low kill (held W key): while YES the same high-pass
// runs at DOUBLE the usual cutoff, whether or not lowKillEnabled is on;
// releasing sweeps back to whatever lowKillEnabled implies. Same declick
// sweep as the toggle.
@property (nonatomic) BOOL lowKillBoostActive;

// Momentary reverb send (held E key): while YES, the master signal also feeds
// a long, fully-wet reverb return (low-cut so the tail can't muddy the bass).
// Setting NO cuts only the send — the tail rings out naturally.
@property (nonatomic) BOOL reverbSendEnabled;

// Momentary delay echo send (held R key): while YES, the master signal also
// feeds an 1/8-note ping-pong echo with aggressive feedback, high-passed so
// the repeats don't stack up bass. Setting NO cuts only the send — the trail
// decays through the feedback naturally.
@property (nonatomic) BOOL delaySendEnabled;

// Momentary short delay echo send (held T key): the same ping-pong echo as
// delaySendEnabled, on 1/16-note taps — twice as fast. The two are
// independent sends and can run together.
@property (nonatomic) BOOL shortDelaySendEnabled;

// Effective (pitch-scaled) tempo in BPM the echo's 1/8-note tap follows.
// The controller feeds it from the same tagged/detected BPM the label shows;
// <= 0 means unknown and a 120 BPM default applies.
@property (nonatomic) float delayTapBPM;

@end

NS_ASSUME_NONNULL_END
