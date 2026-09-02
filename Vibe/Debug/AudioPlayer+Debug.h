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
#import "AudioLevelMath.h"

@interface AudioPlayer (Debug)

// The player's own copy of the loading configuration, for dump_audio_loading's
// three-way comparison against the materialization coordinator's and the
// metadata cache's. Nothing in the app reads it back — the player is told its
// configuration, it is never asked.
- (AudioLoadingConfiguration *)loadingConfiguration;

// The current file's channel count, for dump_state. Nothing in the app asks
// the player for one.
- (NSUInteger)numChannels;

#if TARGET_OS_OSX
// The HAL device the output unit is actually bound to, for dump_state's
// outputDeviceId; implemented in AudioPlayer+Devices.m with the rest of that
// macOS-only layer. Reads the engine on _queue, where every other engine touch
// in the app runs — the command channel calls this from main.
- (NSInteger)currentlyActiveAudioDeviceId;
#endif

// Whether --no-audio-hw's manual rendering actually engaged. The argv flag alone
// does not prove it: enableManualRenderingMode can fail, and the engine then
// opens the output device exactly as usual. Written once during the async init;
// lock-free.
- (BOOL)manualRenderingActive;

// {attachedNodes, retiredFades} for dump_health and check_consistency. A track
// change that failed to retire its node pair leaks them, which nothing else
// observes — and since a soak run is thousands of track changes, unbounded
// growth is the signal. The two are reported together because they fail apart:
// a fade entry dropped with its nodes still attached and a fade entry stranded
// after its nodes were detached are different bugs that either number alone
// cannot tell from the other.
//
// One dispatch_sync serves both. It reads on _queue, so it must not be called
// from there, and it doubles as a liveness probe for that queue: the command
// channel runs on the main thread and would otherwise never see the player
// wedged.
- (NSDictionary<NSString *, NSNumber *> *)debugEngineCounts;

// Mode selection is session-only. A valid change synchronously replaces an
// active tap, so the next state snapshot describes the replacement analyzer.
- (void)debugSetEqualizerNormalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode;

// Demand, installation, actual output liveness, audio callback/window/
// publication counts, newest lifetime sequence and delivered format. Counters
// are atomics incremented by the tap; creating this dictionary happens only on
// the command thread, never on the audio render thread.
- (NSDictionary<NSString *, id> *)debugEqualizerState;

@end

#endif
