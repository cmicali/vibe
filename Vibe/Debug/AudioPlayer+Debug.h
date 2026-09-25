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
#import <AVFoundation/AVFoundation.h>
#import "AudioLevelMath.h"

@class AudioLevelTap;

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

// The current voice's decode format: the file's own, or the 16-bit integer
// form bit-perfect output reads a lossy source in. nil with no voice.
- (nullable AVAudioFormat *)debugCurrentDecodeFormat;

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

// Whether --no-audio-hw's manual rendering actually engaged. The argv flag alone
// does not prove it: enableManualRenderingMode can fail, and the engine then
// opens the output device exactly as usual. Written once during the async init;
// lock-free.
- (BOOL)manualRenderingActive;

// Pipeline snapshot for dump_health, check_consistency and the render tests:
// hosted units (`hostedUnits`: the varispeed and the FX chain's, created once
// and kept) and the FX chain's renders so far (`unitRenders`, flat while no
// effect is engaged), retiring voices (`retiredFades`, the name the stress
// tooling reads), live voices, whether the hardware drain is polling, whether
// the output is running, rendered frames, varispeed presence and latency, the
// current voice's gain and underrun count, the output rate (`outputRate`),
// whether the varispeed is in the chain and how often it has rendered
// (`varispeedEngaged`, `varispeedRenders`, flat at zero pitch), and the
// hosted output unit's dropouts and callback cost (`renderCycles`,
// `renderMeanMicros`, `renderMaxMicros`, cumulative). A retiring voice that
// never ends is the leak this exists to catch, and since a soak run is
// thousands of track changes, unbounded growth is the signal.
//
// One dispatch_sync serves all. It reads on _queue, so it must not be called
// from there, and it doubles as a liveness probe for that queue: the command
// channel runs on the main thread and would otherwise never see the player
// wedged.
- (NSDictionary<NSString *, NSNumber *> *)debugEngineCounts;

// The installed meter, for the render suite's signal-probe reads; nil while
// no indicator or probe wants levels.
- (nullable AudioLevelTap *)debugLevelTap;

// Mode selection is session-only. A valid change synchronously replaces an
// active tap, so the next state snapshot describes the replacement analyzer.
- (void)debugSetEqualizerNormalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode;

// Demand, installation, actual output liveness, audio callback/window/
// publication counts, newest lifetime sequence and delivered format. Counters
// are atomics incremented by the tap; creating this dictionary happens only on
// the command thread, never on the audio render thread.
- (NSDictionary<NSString *, id> *)debugEqualizerState;

@end

NS_ASSUME_NONNULL_END

#endif
