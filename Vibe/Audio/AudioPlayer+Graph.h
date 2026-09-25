//
//  AudioPlayer+Graph.h
//  Vibe
//
//  The render pipeline and its lifetime. One C function, VibeMasterBusRender,
//  over one plain struct, renders everything the output plays:
//
//    voice bus → [varispeed] → [FX] → [meter] → the output's buffers
//
//  The SOURCE segment is the bus and, in ordinary playback on macOS, one
//  hosted Varispeed unit for the pitch fader. It is built lazily at the first
//  settlement and rebuilt only when the mode or the output's format changes —
//  the bus always runs at the output's format, so the file's own rate is
//  read direct when the output follows it (bit-perfect) and converted inside
//  the bus otherwise. A rebuild kills every voice, so its callers guarantee
//  nothing audible, or go through reconcileSourceSegmentOnQueue, which
//  starts the current one again at its retained intent. The varispeed is in
//  the chain only while the pitch is off zero: at zero the render plays the
//  bus straight, no unit rendered and no delay, and the render engages and
//  disengages it at a slice boundary without a click — priming its filter
//  with the last frames heard on the way in, replaying the frames it pulled
//  ahead on the way out.
//
//  The FX segment (AudioFX.h) renders in place while it is connected — its
//  pointer is in the master bus only then — and the meter (AudioLevelTap.h)
//  reads the final samples while the equalizer wants them. Both are stages
//  the render skips when they have nothing to do.
//
//  Every conversion the path can make, and why: the bus's converter, when a
//  file's rate, sample format or channels are not the output's (the
//  mastering algorithm at maximum quality on macOS, read back; iOS's
//  resampler offers no algorithm and runs at the quality alone); the
//  varispeed's resampling, while the pitch is off zero (its highest render
//  quality); the 16-bit integer form a lossy file takes on a 16-bit device
//  under bit-perfect output, one rounding in that same converter. The carriers convert nothing: the macOS unit runs at its
//  device's nominal rate (the bound device's rate is watched), and the iOS
//  engine's output node is fed the route's own rate, the pipeline following
//  a route change (followOutputFormatOnQueue:).
//
//  Two CARRIERS pull the render. On macOS it is Vibe's own HAL output unit
//  bound to the chosen device (AudioOutputUnit.h), through a C proc, so
//  nothing follows the system default on its own; the unit, the bus and the
//  FX all run at the device's rate, and applyOutputRateOnQueue: is the one
//  place that changes. On iOS it is AVAudioEngine, shrunk to one source node
//  wired to its output node, whose render block calls the same function.
//  Under --no-audio-hw there is no carrier on either platform: the debug pump
//  calls the function at real-time pace, or frame by frame in the tests. The
//  render slices whatever count a carrier hands it.
//
//  Everything the audio thread reads is plain memory and atomics in the
//  master bus. A structural change — the bus, the varispeed, the FX chain's
//  hosting — happens with the output stopped; the meter comes and goes live
//  by its pointer. An object the render could still be inside is freed only
//  after its pointer was withdrawn and the render seen outside
//  (waitForRenderToLeaveOnQueue).
//
//  The output is not held running for the life of the player, because a
//  running output owns the device — on Bluetooth it keeps the link up, on any
//  device it blocks another app's exclusive format. Nor is it stopped the
//  moment playback ends: a natural track end is followed within milliseconds
//  by the auto-advance's play, and an immediate stop made every
//  consecutive-track transition pay an output stop and start. So the stop is
//  deferred and cancelled by generation, and starting playback is the one
//  funnel that cancels it. Voices keep their state across an output stop;
//  nothing is rescheduled.
//
//  The DRAIN is how the transport hears the bus: a 10 ms timer on the player
//  queue while the output runs voices (nothing at idle), or, under the debug
//  pump, a call after every rendered slice.
//
//  Everything here runs on the player queue.
//

#import "AudioPlayer.h"
#import "AudioVoiceBus.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// The largest slice the pipeline renders at once, and every hosted unit's
// frames per slice; a carrier's larger cycle is rendered in slices.
static const AVAudioFrameCount kVibeMasterBusMaxFrames = 4096;

// The pipeline's audio-thread state, AudioPlayer+Graph.m's.
typedef struct VibeMasterBus VibeMasterBus;

@interface AudioPlayer (Graph)

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
// Reconciles the equalizer's meter with the queue-side demand: the tap is
// created at the first demand and kept, so a demand toggle is the render's
// pointer and a publisher session, live. dropLevelTapOnQueue frees it for a
// replacement — a rate or normalization-mode change — after the render was
// seen outside it.
- (void)applyLevelTapOnQueue;
- (void)dropLevelTapOnQueue;
// Returns once no render is inside the pipeline: the caller has withdrawn
// what it is about to reset or free, and a render that read it before that
// finishes on its own within a block's time. The wait is bounded, as the
// output unit's stop is.
- (void)waitForRenderToLeaveOnQueue;
#if !TARGET_OS_OSX
// Forgets every reference bound to the dead engine without messaging it —
// the media-services-reset rebuild's first half.
- (void)dropEngineBoundStateOnQueue;
#endif
#if TARGET_OS_OSX
// Brings the unit and the pipeline to `rate`: the output stopped, the unit
// reconfigured, the FX chain re-hosted, the meter replaced. The bus is the
// caller's to reconcile through ensureSourceSegmentOnQueueRebuilt:, which
// rebuilds one at the old rate and reports it, so the caller re-voices. A
// no-op at the current rate. NO without a unit, or when the unit refuses.
- (BOOL)applyOutputRateOnQueue:(double)rate;
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
// The render chain, stage by stage, from the source file to the output
// device: `stage` names each (source, decode, bus, varispeed, fx, meter,
// output, and on macOS device), `present` whether it is there now, and the
// rest is that stage's facts — rates, sample formats, channels, whether it
// is in the render. For the Settings window, the debug report and the
// dump_audio_path verb.
- (NSArray<NSDictionary<NSString *, id> *> *)audioPathOnQueue;
// Whether the carrier is rendering: the gate the start opens and the stop
// closes, or on iOS the engine's own state, since it can stop itself.
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
// The format the bus reads `file` as: its own, or the 16-bit integer form
// bit-perfect output prefers for a lossy source on a 16-bit device, at the
// bus's own rate and width.
- (AVAudioFormat *)decodeFormatOnQueueForFile:(AVAudioFile *)file;
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

// Disposes the hosted varispeed and frees the master bus; the carrier is
// stopped and no render is inside. The player's dealloc.
void VibeMasterBusFree(VibeMasterBus * _Nullable master);

NS_ASSUME_NONNULL_END
