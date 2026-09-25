//
//  AudioPlayer+Debug.h
//  Vibe
//
//  Declaration-only, and deliberately so: the implementation stays in the
//  class's own .m, and ObjC's dynamic dispatch needs no more than this to call
//  it. Re-declaring here is what keeps the shipping header free of #if DEBUG.
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

// How the current voice's file reaches the bus (AudioVoiceBus's
// conversionOfVoice:): nil when it is read direct.
- (nullable NSDictionary<NSString *, id> *)debugCurrentConversion;

// The output's rate moved under the pump, as a device's would under the
// unit: the pipeline follows through followOutputFormatOnQueue:, keeping
// the current track at its position and state. NO when it could not.
- (BOOL)debugSetOutputRate:(double)rate;

// The player's own copy of the loading configuration, for dump_audio_loading's
// three-way comparison against the materialization coordinator's and the
// metadata cache's. Nothing in the app reads it back — the player is told its
// configuration, it is never asked.
- (AudioLoadingConfiguration *)loadingConfiguration;

// The current file's channel count, for dump_state. Nothing in the app asks
// the player for one.
- (NSUInteger)numChannels;

// Whether --no-audio-hw's render pump is attached. The argv flag alone does
// not prove it: the pump attaches during the async init, before any voice.
// Written once during the async init;
// lock-free.
- (BOOL)manualRenderingActive;

// Pipeline snapshot for dump_health, check_consistency and the render tests:
// hosted units (`hostedUnits`: the varispeed and the FX chain's, created once
// and kept) and the FX chain's renders so far (`unitRenders`, flat while no
// effect is engaged), retiring voices (`retiredFades`, the name the stress
// tooling reads), live voices, decoder turns run so far (`decodeTurns`, flat
// while every voice is paused at its end), whether the hardware drain is polling, whether
// the output is running, rendered frames, varispeed presence and latency, the
// current voice's gain and underrun count, the output rate (`outputRate`),
// whether the varispeed is in the chain, how often it has rendered and how
// often its history ring was written (`varispeedEngaged`, `varispeedRenders`,
// `varispeedHistoryWrites`, the last two flat at zero pitch settled), and the
// hosted output unit's dropouts and callback cost (`renderCycles`,
// `renderMeanMicros`, `renderMaxMicros`, cumulative). A retiring voice that
// never ends is the leak this exists to catch, and since a soak run is
// thousands of track changes, unbounded growth is the signal.
//
// One dispatch_sync serves all. It reads on _queue, so it must not be called
// from there, and it doubles as a liveness probe for that queue: the command
// channel runs on the main thread and would otherwise never see the player
// wedged.
- (NSDictionary<NSString *, NSNumber *> *)debugRenderCounts;

// Zeroes the cumulative ones — the output unit's cycles, mean and max cost
// and dropouts, and the pipeline's render refusals — on the queue, so a
// measurement phase reads on its own instead of as a delta.
- (void)debugClearRenderCounters;

// The installed meter, for the render suite's signal-probe reads; nil while
// no indicator or probe wants levels.
- (nullable AudioLevelMeter *)debugLevelMeter;

// While set, a render blocks inside the pipeline after it has read the bus —
// a render stuck past the wait's bound, on a thread of its own — so every
// withdrawal defers what it could be inside (`renderLeaveWork` in
// debugRenderCounts counts those deferrals) and every other render is
// refused meanwhile (`renderRefusals`). debugRenderOnCallerThread: is the
// render to hold: a carrier's callback on the calling thread, into buffers
// of its own, which blocks there until the hold lifts; debugRendersHeld
// counts the renders blocked inside (`rendersHeld`). Any thread.
- (void)debugHoldRenderInside:(BOOL)hold;
- (void)debugRenderOnCallerThread:(NSUInteger)frames;
- (NSUInteger)debugRendersHeld;

// Mode selection is session-only. A valid change synchronously replaces an
// active meter, so the next state snapshot describes the replacement analyzer.
- (void)debugSetEqualizerNormalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode;

// Demand, installation, actual output liveness, audio callback/window/
// publication counts, newest lifetime sequence and delivered format. Counters
// are atomics incremented by the meter; creating this dictionary happens only on
// the command thread, never on the audio render thread.
- (NSDictionary<NSString *, id> *)debugEqualizerState;

@end

@interface AudioVoiceBus (Debug)

// A render stuck inside the bus: while set, a render blocks in
// VibeVoiceBusRender after it has entered, so a decoder waiting for it to
// leave waits in earnest; debugRendersHeld counts the renders blocked there.
// Debug builds only. Any thread.
- (void)debugHoldRender:(BOOL)hold;
- (NSUInteger)debugRendersHeld;
// A converter that fails: while set, every fill of a converting voice
// reports kAudio_ParamError in place of its frames. Debug builds only.
- (void)debugRefuseConversion:(BOOL)refuse;

@end

NS_ASSUME_NONNULL_END

#endif
