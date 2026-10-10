//
//  AudioPlayer+Debug.h
//  Vibe
//
//  Declaration-only: the implementations sit under #if DEBUG in the classes'
//  own .m files, which keeps the shipping headers free of it.
//

#if DEBUG

#import "AudioPlayer.h"
#import "AudioVoiceBus.h"
#import <AVFAudio/AVFAudio.h>
#import "AudioLevelMath.h"

@class AudioLevelMeter;

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Debug)
- (instancetype)initForManualRendering:(AVAudioFormat *)format enableFX:(BOOL)enableFX automatic:(BOOL)automatic delegate:(id<AudioPlayerDelegate>)delegate;
- (nullable AVAudioPCMBuffer *)debugRenderFrames:(AVAudioFrameCount)frames error:(NSError **)error;
- (void)debugSetCapture:(void (^ _Nullable)(AVAudioPCMBuffer *buffer))capture;
- (void)debugShutdown;
- (void)debugBlockQueueForSeconds:(NSTimeInterval)seconds;

// Frame-driven manual rendering only: while starved, no decode turn runs
// before a slice, so the bus underruns and zero-fills, holding its position,
// until decoding is allowed again.
- (void)debugStarveDecoder:(BOOL)starve;

// How the current voice's file reaches the bus; nil when it is read direct.
- (nullable NSDictionary<NSString *, id> *)debugCurrentConversion;
// The current bus's resampler costs (AudioVoiceBus's debugResamplerCostsResetting:);
// nil before a bus exists. A rebuilt bus starts from zero.
- (nullable NSDictionary<NSString *, id> *)debugResamplerCostsResetting:(BOOL)reset;

// Moves the output's rate under the pump, as a device's would under the
// output unit; the pipeline follows, keeping the track at its position and
// state. NO when it could not.
- (BOOL)debugSetOutputRate:(double)rate;

// For dump_audio_loading's comparison against the coordinator's and the
// metadata cache's copies; nothing in the app reads it back.
- (AudioLoadingConfiguration *)loadingConfiguration;

// For dump_state; nothing in the app asks.
- (NSUInteger)numChannels;

// The buffering holds since launch, for dump_state: holds begun, releases
// (each a resume), stalls (Connection lost), and heldSeconds, the current
// hold's age while buffering, else the last hold's length.
- (NSDictionary<NSString *, NSNumber *> *)debugBufferingRecord;

// Whether a render pump stands in for the output unit. Under --no-audio-hw it
// attaches during the async init, so the argv flag alone does not prove it.
// Written once, before any voice; read lock-free.
- (BOOL)manualRenderingActive;

// Pipeline counters for dump_health, check_consistency and the render tests.
// `retiredFades` (the name the stress tooling reads) counts retiring voices:
// its unbounded growth across a soak is the leak this exists to catch.
// `unitRenders` stays flat while no effect is engaged, `decodeTurns` while
// every voice is paused at its end, `varispeedRenders` and
// `varispeedHistoryWrites` at zero pitch settled. The output unit's
// `renderCycles`, `renderMeanMicros`, `renderMaxMicros`, `outputDropouts`,
// `lateCycles`, `clockJumps` and `skippedFrames` are cumulative.
//
// Reads with dispatch_sync on the player queue, so never call it from there;
// that makes it the main-thread channel's liveness probe for the queue.
- (NSDictionary<NSString *, NSNumber *> *)debugRenderCounts;

// Zeroes the cumulative counters and the render refusals, so a measurement
// phase reads on its own instead of as a delta.
- (void)debugClearRenderCounters;

// The installed meter, for the render suite's signal-probe reads; nil while
// no indicator or probe wants levels.
- (nullable AudioLevelMeter *)debugLevelMeter;

// While set, a render blocks inside the pipeline after it has read the bus,
// stuck past the wait's bound: every withdrawal defers what it could be
// inside (`renderLeaveWork`) and every other render is refused
// (`renderRefusals`). debugRenderOnCallerThread: is the render to hold, an
// output unit's callback on the calling thread into buffers of its own;
// debugRendersHeld counts the renders blocked inside. Any thread.
- (void)debugHoldRenderInside:(BOOL)hold;
- (void)debugRenderOnCallerThread:(NSUInteger)frames;
// While set, the current bus's decode turns wait at their start, as a read
// stalled on a slow volume would, so the rings drain and the render underruns
// once they are empty. The bus a later rebuild makes is not held.
- (void)debugHoldDecoder:(BOOL)hold;
- (NSUInteger)debugRendersHeld;

// Not persisted. A change synchronously replaces an active meter, so the next
// debugEqualizerState describes the replacement.
- (void)debugSetEqualizerNormalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode;

// Built on the player queue from the meter's atomics, never on the render
// thread.
- (NSDictionary<NSString *, id> *)debugEqualizerState;

@end

@interface AudioVoiceBus (Debug)

// While set, a render blocks in VibeVoiceBusRender after it has entered, so a
// decoder waiting for it to leave waits in earnest; debugRendersHeld counts
// the renders blocked there. Any thread.
- (void)debugHoldRender:(BOOL)hold;
- (NSUInteger)debugRendersHeld;
- (void)debugHoldDecoder:(BOOL)hold;
// Decode-thread CPU spent resampling, the file reads inside the fill excluded,
// against the bus audio it produced, and that as a percent of one core. Since
// the bus was made, or the last reset.
- (NSDictionary<NSString *, id> *)debugResamplerCostsResetting:(BOOL)reset;

@end

NS_ASSUME_NONNULL_END

#endif
