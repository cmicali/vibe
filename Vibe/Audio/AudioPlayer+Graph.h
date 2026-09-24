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
//  nothing audible.
//
//  The FX segment (AudioFX.h) renders in place when it is connected; the
//  meter (AudioLevelTap.h) reads the final samples while the equalizer wants
//  them. Both are stages the render skips when they have nothing to do.
//
//  Two CARRIERS pull the render. On macOS it is Vibe's own HAL output unit
//  bound to the chosen device (AudioOutputUnit.h), through a C proc, so
//  nothing follows the system default on its own; the unit, the bus and the
//  FX all run at the device's rate, and applyOutputRateOnQueue: is the one
//  place that changes. On iOS it is AVAudioEngine, shrunk to one source node
//  wired to its output node, whose render block calls the same function. The
//  debug pump calls it directly on macOS and through the engine's offline
//  render on iOS.
//
//  Everything the audio thread reads is plain memory and atomics in the
//  master bus. A structural change — the bus, the varispeed, the FX chain's
//  hosting, the meter — happens with the output stopped, or is published
//  through an atomic the render checks before entering the stage and then
//  retired only once no render is inside (retireRenderObjectOnQueue:).
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

// The largest render the pipeline accepts; a larger IO cycle is sliced.
static const AVAudioFrameCount kVibeMasterBusMaxFrames = 4096;

@interface AudioPlayer (Graph)

// Creates the carrier — the hosted unit on the system default at that
// device's rate on macOS, the engine and its source node on iOS, the debug
// pump under --no-audio-hw — and the master bus it pulls; the init path and
// the iOS media-services rebuild must configure them identically.
- (void)createOutputOnQueue;
// Connects or disconnects the FX segment per the setting and the mode, with
// the output stopped.
- (void)reconcileFXOnQueue;
// Reconciles the equalizer's meter with the queue-side demand. Live: the
// meter is installed before the gate opens and retired after the render was
// seen outside it. removeLevelTapOnQueue retires it whatever the demand,
// for a replacement.
- (void)applyLevelTapOnQueue;
- (void)removeLevelTapOnQueue;
#if !TARGET_OS_OSX
// Forgets every reference bound to the dead engine without messaging it —
// the media-services-reset rebuild's first half.
- (void)dropEngineBoundStateOnQueue;
#endif
// Publishes the removal of a render-visible object (the bus, the meter) and
// waits for the render to leave; when it will not within the bound, the
// object is parked until a later edge sees the render outside.
- (void)retireRenderObjectOnQueue:(nullable id)object;
#if TARGET_OS_OSX
// Brings the unit and the pipeline to `rate`: the output stopped, the unit
// reconfigured, the FX chain re-hosted, the bus rebuilt if it exists. A no-op
// at the current rate. NO without a unit, or when the unit refuses.
- (BOOL)applyOutputRateOnQueue:(double)rate;
#endif

// The pipeline's format: stereo float32 at the output's rate.
- (AVAudioFormat *)masterBusFormatOnQueue;
// Whether the carrier is rendering: the gate the start opens and the stop
// closes on macOS, the engine's own state on iOS.
- (BOOL)renderingOnQueue;
// The output-timeline frame the next render begins at, plus the block in
// flight: the signal probe's clock on every carrier.
- (nullable AVAudioTime *)outputRenderTimeOnQueue;
// The hosted varispeed, in ordinary playback on macOS.
- (BOOL)varispeedPresentOnQueue;
- (NSTimeInterval)varispeedLatencyOnQueue;
// Hosted units alive: the varispeed and the FX chain's.
- (NSUInteger)hostedUnitCountOnQueue;

// Makes the source segment what the mode wants — the bus at the output's
// format, with a varispeed unless bit-perfect output is on — building or
// rebuilding it with the output stopped. `rebuilt` reports whether every
// voice died with the old segment, so the caller re-voices. NO when it
// cannot be built.
- (BOOL)ensureSourceSegmentOnQueueRebuilt:(nullable BOOL *)rebuilt;
// The format the bus reads `file` as: its own, or the 16-bit integer form
// bit-perfect output prefers for a lossy source on a 16-bit device.
- (AVAudioFormat *)decodeFormatOnQueueForFile:(AVAudioFile *)file;
// Pitch in percent onto the varispeed's rate and bypass; a no-op without one.
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

NS_ASSUME_NONNULL_END
