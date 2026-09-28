//
//  AudioPlayer+Pipeline.h
//  Vibe
//
//  voice bus -> [varispeed] -> [FX] -> [meter] -> [volume] -> the output
//  unit's buffers.
//
//  The player queue owns mutations. The render reads plain memory and atomics,
//  admits one callback at a time and renders an output unit's larger cycle in
//  bounded slices. Withdrawn storage survives until afterRenderLeavesOnQueue:
//  sees the render outside; the output unit's bounded stop alone cannot free
//  it. The platform categories make the output unit and own device and
//  session work. Audio/AGENTS.md is the reading guide.
//

#import "AudioPlayer.h"
#import "AudioVoiceBus.h"
#import <AVFAudio/AVFAudio.h>

@class AudioFileHandle, AudioOutputUnit;

NS_ASSUME_NONNULL_BEGIN

// The largest slice the pipeline renders at once — the bus's own span, so
// the bus mixes every slice whole — and every hosted unit's frames per
// slice; an output unit's larger cycle is rendered in slices.
static const AVAudioFrameCount kVibeMasterBusMaxFrames = kVibeVoiceBusMaxRenderFrames;

// The pipeline's audio-thread state, AudioPlayer+Pipeline.m's.
typedef struct VibeMasterBus VibeMasterBus;
OSStatus VibeMasterBusRender(void *context, const AudioTimeStamp * _Nullable timestamp,
                            UInt32 frames, AudioBufferList *data) CA_REALTIME_API;

@interface AudioPlayer (Pipeline)

// Creates the output — the hosted unit on the system default at that
// device's rate on macOS; on iOS the pipeline at the route's rate, the unit
// itself made at the first start; the debug pump under --no-audio-hw — and
// the master bus it pulls; the init path and the iOS media-services rebuild
// must configure them identically.
- (void)createOutputOnQueue;
// Makes `unit` the output unit and routes its later failures back to the queue:
// one a later start or stop has not superseded stops the output, and a
// refused start also parks the current voice Paused and tells the owning play.
- (void)attachOutputUnitOnQueue:(AudioOutputUnit *)unit;
// The unit's IO-cycle counters, for the reports.
- (NSDictionary<NSString *, NSNumber *> *)outputUnitCountersOnQueue;
// Whether the FX segment belongs in the chain: the setting, unless
// bit-perfect output outranks it. The one home of the rule.
- (BOOL)fxWantedOnQueue;
// Connects or disconnects the FX segment per fxWantedOnQueue, with the
// output stopped. Idempotent.
- (void)reconcileFXOnQueue;
// Clears every stage's intent at submission, so a queued bypass cannot erase
// a newer FX action.
- (void)clearFXIntent;
// After an output stop for a pipeline edit (a format follow, an FX toggle):
// a playing voice restarts the output and re-arms the signal probe, a paused
// one re-arms the idle stop. NO when the output refuses to start; the voice
// is then parked Paused and the error sent.
- (BOOL)resumeOutputAfterEditOnQueue:(BOOL)wasPlaying reason:(NSString *)reason;
// The meter is created at the first demand and kept; a demand toggle is the
// render's pointer and a publisher session. dropLevelMeterOnQueue frees it
// for a replacement (rate or normalization mode) once the render is outside.
- (void)applyLevelMeterOnQueue;
- (void)dropLevelMeterOnQueue;
// Runs `work` once no render is inside the pipeline; the caller has already
// withdrawn what it frees. Usually at once; a render stuck past the bounded
// wait parks `work` until a later wait or drain sees it outside. A block that
// only captures an object keeps it alive exactly as long as a render could be
// inside it. `work` must not capture the player.
- (void)afterRenderLeavesOnQueue:(dispatch_block_t)work;
#if !TARGET_OS_OSX
// Forgets every reference bound to the dead media server without messaging
// it (the unit's own dealloc still stops and disposes it) — the
// media-services-reset rebuild's first half.
- (void)dropOutputBoundStateOnQueue;
#endif

// Follows a format change under the pipeline (the iOS route's rate, the debug
// pump's): stops the output, adopts the format, rebuilds the bus keeping the
// current track, and restarts a playing output. NO when refused; the player
// is then Stopped or parked Paused, with an error sent. macOS device changes
// go through AudioPlayer+Devices instead.
- (BOOL)followOutputFormatOnQueue:(AVAudioFormat *)format;

// The pipeline's format: stereo float32 at the output's rate.
- (AVAudioFormat *)masterBusFormatOnQueue;
- (void)setMasterBusFormatOnQueue:(AVAudioFormat *)format;
- (NSDictionary<NSString *, id> *)pipelineRenderSnapshotOnQueue;
// The shared gate and output unit state; under the pump, the gate alone.
- (BOOL)renderingOnQueue;
// Frames rendered plus the block in flight: the signal probe's clock and the
// render-clock check's count.
- (uint64_t)renderedFramesOnQueue;
// As a timestamp: sample time only, in the pipeline's frames; no flag set
// before the pipeline has a format.
- (AudioTimeStamp)outputRenderTimeOnQueue;
// The hosted varispeed, in ordinary playback on macOS: whether it exists,
// whether the render has it in the chain (the pitch off zero), its declared
// latency while it does and 0 otherwise, and how often it has rendered.
- (BOOL)varispeedPresentOnQueue;
- (BOOL)varispeedEngagedOnQueue;
- (NSTimeInterval)varispeedLatencyOnQueue;
- (uint64_t)varispeedRendersOnQueue;
// Writes into the history ring: only while an engage is being prepared or
// the unit is in the chain, never at zero pitch settled.
- (uint64_t)varispeedHistoryWritesOnQueue;
// Renders the pipeline turned away because another was inside; cumulative,
// zero through every soak.
- (uint64_t)renderRefusalsOnQueue;
- (void)clearRenderRefusalsOnQueue;

// Hosted units alive: the varispeed and the FX chain's.
- (NSUInteger)hostedUnitCountOnQueue;

// Makes the source segment what the mode wants — the bus at the output's
// format, with a varispeed unless bit-perfect output is on — building or
// rebuilding it with the output stopped. `rebuilt` reports whether every
// voice died with the old segment, so the caller re-voices. NO when it
// cannot be built.
- (BOOL)ensureSourceSegmentOnQueueRebuilt:(nullable BOOL *)rebuilt;
// ensureSourceSegmentOnQueueRebuilt: keeping the track: the intent is read
// before the rebuild kills the voice, and a killed current voice is started
// again at it. The caller restarts the output for a playing one.
- (BOOL)reconcileSourceSegmentOnQueue;
// Pitch in percent onto the varispeed's rate, and whether it is in the
// chain at all (off zero); a no-op without one.
- (void)applyPitchOnQueue:(float)pitch;

// Opens the gate and starts the output unit, then the meter. Every start and
// resume goes through here, which is what cancels a pending idle stop.
- (BOOL)startOutputOnQueue:(NSError * _Nullable * _Nullable)outError;
// The one stop site: stops the unit, closes the gate, waits for the render to
// leave and kills every retiring voice, whose fades nothing would land.
- (void)stopOutputOnQueue;
// Arms the deferred idle stop. Call it wherever playback goes idle.
- (void)scheduleOutputIdleStopOnQueue;

// Polls the bus and routes its events to the transport; starts or stops the
// hardware drain timer to match.
- (void)drainVoiceBusOnQueue;
- (void)updateDrainTimerOnQueue;

@end

// Gate closed, nothing hosted. Lives from the player's init to its dealloc,
// so no queue-side reader finds it absent.
VibeMasterBus *VibeMasterBusCreate(void);
// The output volume's gain, 0..1, from any thread; the render ramps to it
// across its next slice, or lands on it at the next output start. 1, the
// default, leaves every sample untouched.
void VibeMasterBusSetVolume(VibeMasterBus *master, float gain);
// Whether a render is inside the pipeline right now.
BOOL VibeMasterBusRenderInside(VibeMasterBus *master);
// Disposes the hosted varispeed and frees the master bus; the output unit is
// stopped and no render is inside. The player's dealloc.
void VibeMasterBusFree(VibeMasterBus *master);

NS_ASSUME_NONNULL_END
