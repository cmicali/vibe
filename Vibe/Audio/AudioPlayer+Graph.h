//
//  AudioPlayer+Graph.h
//  Vibe
//
//  The AVAudioEngine graph and its lifetime. Three segments:
//
//    voice bus → [varispeed] → mainMixer → [FX] → output
//
//  The SOURCE segment is the bus and, in ordinary playback, one varispeed for
//  the pitch fader. It is built lazily at the first settlement and rebuilt
//  only when the mode or the bus format the file wants differs — bit-perfect
//  output delivers each file at its own format with no varispeed, ordinary
//  playback converts everything to the mixer's format inside the bus. A
//  rebuild kills every voice, so its callers guarantee nothing audible.
//
//  The MASTER bus is the mixer to the output, through the FX segment when it
//  is enabled (AudioFX.h). The level tap sits on whatever feeds the output.
//
//  The engine is not held running for the life of the player, because a
//  running engine owns the output device — on Bluetooth it keeps the link up,
//  on any device it blocks another app's exclusive format. Nor is it stopped
//  the moment playback ends: a natural track end is followed within
//  milliseconds by the auto-advance's play, and an immediate stop made every
//  consecutive-track transition pay an output-unit stop and start. So the stop
//  is deferred and cancelled by generation, and starting playback is the one
//  funnel that cancels it. Voices keep their state across an engine stop;
//  nothing is rescheduled.
//
//  The DRAIN is how the transport hears the bus: a 10 ms timer on the player
//  queue while the engine runs voices (nothing at idle), or, under the debug
//  pump, a call after every rendered slice.
//
//  Everything here runs on the player queue.
//

#import "AudioPlayer.h"
#import "AudioVoiceBus.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Graph)

// Creates the engine and wires the master bus, debug argv flags
// (--no-audio-hw, --silent) included; the init path and the iOS
// media-services rebuild must configure the engine identically.
- (void)createEngineAndMasterBusOnQueue;
// Wires the master bus: the FX segment, or, with FX disabled or bit-perfect
// on, the mixer straight to the output. Engine stopped.
- (void)installMasterBusOnQueue;
- (void)reconnectMasterBusOnQueueWithFormat:(AVAudioFormat *)format;
// Reconciles the equalizer tap with the queue-side demand.
- (void)applyLevelTapOnQueue;

// Makes the source segment what `file` wants — the bus at the file's format
// under bit-perfect output, else the one ordinary bus — building or
// rebuilding it with the engine stopped. `rebuilt` reports whether every
// voice died with the old segment, so the caller re-voices. NO when the
// file's format cannot be carried.
- (BOOL)ensureSourceSegmentOnQueueForFile:(AVAudioFile *)file rebuilt:(nullable BOOL *)rebuilt;
// The format the bus reads `file` as: its own, or the 16-bit integer form
// bit-perfect output prefers for a lossy source on a 16-bit device.
- (AVAudioFormat *)decodeFormatOnQueueForFile:(AVAudioFile *)file;
// Pitch in percent onto the varispeed's rate and bypass; a no-op without one.
- (void)applyPitchOnQueue:(float)pitch;

// Starts the engine if it is not running. Every path that starts or resumes
// playback goes through here, which is what dissolves a pending idle stop.
- (BOOL)startEngineOnQueue:(NSError * _Nullable * _Nullable)outError;
// Stops the engine and kills every retiring voice: silence cannot click, and
// nothing would ever land their fades. The one stop site.
- (void)stopEngineOnQueue;
// Arms the deferred idle stop. Call it wherever playback goes idle.
- (void)scheduleEngineIdleStopOnQueue;

// Polls the bus and routes its events to the transport; starts or stops the
// hardware drain timer to match.
- (void)drainVoiceBusOnQueue;
- (void)updateDrainTimerOnQueue;

// Forgets every reference bound to the current engine without messaging it —
// the iOS media-services-reset rebuild's first half.
- (void)dropEngineBoundStateOnQueue;

@end

NS_ASSUME_NONNULL_END
