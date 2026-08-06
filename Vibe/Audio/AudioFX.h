//
//  AudioFX.h
//  Vibe
//

#import <Foundation/Foundation.h>

@class AVAudioEngine;

NS_ASSUME_NONNULL_BEGIN

// The DJ performance effects on the master bus: the low-kill high-pass, on Q
// with a W boost, and the send-returns — E for a reverb wash, R and T for
// ping-pong delays. A bare key drives each one, and the same key both taps and
// holds. TransportKeyMonitor owns that distinction; this class simply holds
// plain on-off state per effect.
//
// It owns the FX segment of the engine graph, everything between the main
// mixer and the output node:
//
//   mainMixer -> lowKillEQ -+-> masterMix -> output
//                           +-> reverb send/return       -> masterMix
//                           +-> 1/8 delay send/return    -> masterMix
//                           +-> 1/16 delay send/return   -> masterMix
//
// It sits downstream of the per-track player and varispeed chains, so track
// changes, seeks and the crossfade never touch it.
//
// Threading mirrors AudioPlayer. Property setters record lock-guarded intent
// and dispatch the graph and parameter work onto the player's serial engine
// queue, while the ramp and sweep state stays queue-confined. The object is
// created before the engine exists, in AudioPlayer's synchronous init, so
// intent set early — a menu action or the BPM feed racing the async engine
// init — is never lost, and installInEngine: applies whatever was recorded.
@interface AudioFX : NSObject

// queue is the player's serial engine queue. Every mutation this class makes
// runs there.
- (instancetype)initWithQueue:(dispatch_queue_t)queue;

// Builds, attaches and wires the whole FX segment, then applies any intent
// recorded before the engine existed. It must run on the queue, once, before
// the engine first starts, and AudioPlayer's async init calls it.
- (void)installInEngine:(AVAudioEngine *)engine;

// DJ-style low kill on the Q key: a resonant high-pass filter on the master
// bus that cuts the bass. It is a deck control, so it persists across tracks
// and applies to whatever is playing or starts to play. Toggling sweeps the
// cutoff over about 80ms rather than switching instantly, so it never clicks.
//
// Setting this to NO also clears lowKillBoostActive, because the boost
// modifies this filter and must never outlive it.
@property (nonatomic) BOOL lowKillEnabled;

// The low kill's boost, on the W key. While YES the same high-pass runs at
// double the usual cutoff, whether or not lowKillEnabled is on, and clearing
// it sweeps back to whatever lowKillEnabled implies. It uses the same declick
// sweep as the toggle, and is subordinate to lowKillEnabled; see the note
// above.
@property (nonatomic) BOOL lowKillBoostActive;

// The reverb send, on the E key. While YES the master signal also feeds a
// long, fully wet reverb return, low-cut so the tail cannot muddy the bass.
// Setting NO cuts only the send, and the tail rings out naturally.
@property (nonatomic) BOOL reverbSendEnabled;

// The delay echo send, on the R key. While YES the master signal also feeds an
// 1/8-note ping-pong echo with aggressive feedback, high-passed so the repeats
// do not stack up bass. Setting NO cuts only the send, and the trail decays
// through the feedback naturally.
@property (nonatomic) BOOL delaySendEnabled;

// The short delay echo send, on the T key: the same ping-pong echo as
// delaySendEnabled, on 1/16-note taps, so twice as fast. The two are
// independent sends and can run together.
@property (nonatomic) BOOL shortDelaySendEnabled;

// The effective, pitch-scaled tempo in BPM that the echo's 1/8-note tap
// follows. The controller feeds it from the same tagged or detected BPM the
// label shows. A value of 0 or less means unknown, and a default of 120 BPM
// applies.
@property (nonatomic) float delayTapBPM;

@end

NS_ASSUME_NONNULL_END
