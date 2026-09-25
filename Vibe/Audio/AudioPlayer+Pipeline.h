//
//  AudioPlayer+Pipeline.h
//  Vibe
//
//  Master renderer, source/stage publication and render retirement.
//  voice bus -> [varispeed] -> [FX] -> [meter] -> carrier buffers.
//
//  The player queue owns mutations. The render reads plain memory and atomics,
//  admits one callback at a time and splits larger carrier requests into bounded
//  slices. Withdrawn storage survives until afterRenderLeavesOnQueue: observes
//  the render outside; a bounded carrier stop alone cannot free it.
//
//  Platform categories own carrier construction, device/session operations and
//  observations. The shared pipeline owns the gate, format/segment reconciliation,
//  idle stop, drain scheduling and debug-pump attachment. Transport interprets
//  drained events; Diagnostics assembles reports from this owner's render facts.
//  Audio/CLAUDE.md is the architecture and threading reading guide.
//

#import "AudioPlayer.h"
#import "AudioVoiceBus.h"
#import <AVFAudio/AVFAudio.h>

@class AudioFileHandle;

NS_ASSUME_NONNULL_BEGIN

// The largest slice the pipeline renders at once — the bus's own span, so
// the bus mixes every slice whole — and every hosted unit's frames per
// slice; a carrier's larger cycle is rendered in slices.
static const AVAudioFrameCount kVibeMasterBusMaxFrames = kVibeVoiceBusMaxRenderFrames;

// The pipeline's audio-thread state, AudioPlayer+Pipeline.m's.
typedef struct VibeMasterBus VibeMasterBus;
OSStatus VibeMasterBusRender(void *context, const AudioTimeStamp * _Nullable timestamp,
                            UInt32 frames, AudioBufferList *data) CA_REALTIME_API;

@interface AudioPlayer (Pipeline)

// Creates the carrier — the hosted unit on the system default at that
// device's rate on macOS, the engine and its source node on iOS, the debug
// pump under --no-audio-hw — and the master bus it pulls; the init path and
// the iOS media-services rebuild must configure them identically.
- (void)createOutputOnQueue;
// Whether the FX segment belongs in the chain: the setting, unless
// bit-perfect output outranks it. The one home of the rule.
- (BOOL)fxWantedOnQueue;
// Connects or disconnects the FX segment per fxWantedOnQueue, with the
// output stopped. Idempotent.
- (void)reconcileFXOnQueue;
// Reconciles the equalizer's meter with the queue-side demand: the meter is
// created at the first demand and kept, so a demand toggle is the render's
// pointer and a publisher session, live. dropLevelMeterOnQueue frees it for a
// replacement — a rate or normalization-mode change — after the render was
// seen outside it.
- (void)applyLevelMeterOnQueue;
- (void)dropLevelMeterOnQueue;
// Runs `work` once no render is inside the pipeline. The caller has
// withdrawn what `work` resets or frees, and a render that read it before
// that finishes on its own within a block's time, so `work` usually runs at
// once; the wait is bounded, as the output unit's stop is, and a render not
// seen outside within it — stuck — parks `work` until a later withdrawal or
// the drain sees the render outside (one bound per stuck render, not per
// withdrawal). What `work` captures lives until then, so a block that
// captures an object and does nothing else keeps it alive for exactly as
// long as a render could be inside it. Never captures the player.
- (void)afterRenderLeavesOnQueue:(dispatch_block_t)work;
#if !TARGET_OS_OSX
// Forgets every reference bound to the dead engine without messaging it —
// the media-services-reset rebuild's first half.
- (void)dropEngineBoundStateOnQueue;
#endif

// The output's format moved under the pipeline — the iOS route's rate, the
// debug pump's — and the pipeline follows it: the output stops, the carrier
// takes the format (the unit on macOS, a new source node on iOS, the pump's
// buffers), the bus is rebuilt at it and the current track kept
// (reconcileSourceSegmentOnQueue), and a playing output restarts. NO when
// the carrier or the segment refuses; the player is then Stopped, or parked
// Paused, with an error sent. A no-op at the current format. The macOS
// device paths rebind through AudioPlayer+Devices instead, which does the
// device's own work between the same steps.
- (BOOL)followOutputFormatOnQueue:(AVAudioFormat *)format;

// The pipeline's format: stereo float32 at the output's rate.
- (AVAudioFormat *)masterBusFormatOnQueue;
- (void)setMasterBusFormatOnQueue:(AVAudioFormat *)format;
- (NSDictionary<NSString *, id> *)pipelineRenderSnapshotOnQueue;
// The shared gate and carrier state; under the pump, the gate alone.
- (BOOL)renderingOnQueue;
// The output-timeline frame the next render begins at, plus the block in
// flight: the signal probe's clock on every carrier.
- (nullable AVAudioTime *)outputRenderTimeOnQueue;
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

// Hosted units alive: the varispeed and the FX chain's.
- (NSUInteger)hostedUnitCountOnQueue;

// Makes the source segment what the mode wants — the bus at the output's
// format, with a varispeed unless bit-perfect output is on — building or
// rebuilding it with the output stopped. `rebuilt` reports whether every
// voice died with the old segment, so the caller re-voices. NO when it
// cannot be built.
- (BOOL)ensureSourceSegmentOnQueueRebuilt:(nullable BOOL *)rebuilt;
// ensureSourceSegmentOnQueueRebuilt: plus the restore: the current track's
// intent — position, playing or paused — is read first, and a current voice
// the rebuild killed is started again at it and published. The caller
// restarts the output for a playing one. The one owner of "rebuild and keep
// the track", for the device rebind, the route follow and the debug seam.
- (BOOL)reconcileSourceSegmentOnQueue;
// Pitch in percent onto the varispeed's rate, and whether it is in the
// chain at all (off zero); a no-op without one.
- (void)applyPitchOnQueue:(float)pitch;

// Opens the gate and starts the carrier, then the meter, so the pipeline
// renders whenever the output pulls; a carrier that will not start closes
// the gate again. Every path that starts or resumes playback goes through
// here, which is what dissolves a pending idle stop.
- (BOOL)startOutputOnQueue:(NSError * _Nullable * _Nullable)outError;
// Stops the carrier, closes the gate and waits for the render to leave, and
// kills every retiring voice: silence cannot click, and nothing would ever
// land their fades. The one stop site.
- (void)stopOutputOnQueue;
// Arms the deferred idle stop. Call it wherever playback goes idle.
- (void)scheduleOutputIdleStopOnQueue;

// Polls the bus and routes its events to the transport; starts or stops the
// hardware drain timer to match.
- (void)drainVoiceBusOnQueue;
- (void)updateDrainTimerOnQueue;

@end

// The pipeline's audio-thread state, gate closed and nothing hosted. The
// player owns it from its init to its dealloc, so no queue-side reader ever
// finds it absent; a calloc this small fails only with the process.
VibeMasterBus *VibeMasterBusCreate(void);
// Whether a render is inside the pipeline right now: the teardown's last
// check before it frees what one could be inside.
BOOL VibeMasterBusRenderInside(VibeMasterBus *master);
// Disposes the hosted varispeed and frees the master bus; the carrier is
// stopped and no render is inside. The player's dealloc.
void VibeMasterBusFree(VibeMasterBus *master);

NS_ASSUME_NONNULL_END
