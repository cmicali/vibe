//
//  AudioPlayer+Diagnostics.h
//  Vibe
//
//  Every beta observation the player makes, behind named hooks so the
//  transport stays readable: the `Timeline:` join of a play's submission,
//  admission, settlement, first render and delivery; the `Callback:` line per
//  bus event; the `Signal:` probe on the level tap; the `Stall:` watchers over
//  the main thread, the player queue and the output render clock. Under
//  VIBE_VERBOSE_LOGGING every hook logs; otherwise each is an empty method.
//
//  performDiagnosticPhase:device:operation: is the one hook with a job in
//  every build — it runs the operation — and brackets it with `Phase:` lines
//  in betas. All run on the player queue unless noted.
//

#import "AudioPlayer.h"
#import "AudioVoiceBus.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Diagnostics)

// Installs the process-lifetime stall watchers for the production player. Main thread.
- (void)startStallWatchers;

// The watcher's reads of queue-confined engine state, from its timer on the queue.
- (BOOL)diagnosticEngineRunning;
// IO cycles the hosted output unit wrote as silence because the engine could
// not render; cumulative, any thread. 0 without a unit.
- (uint64_t)diagnosticOutputDropouts;

// The play the current transport state belongs to: the loading submission
// while Loading, else the active one.
- (uint64_t)diagnosticPlayIdentifierOnQueue;

// Runs operation, timing it as a named phase of a device or engine change.
- (BOOL)performDiagnosticPhase:(NSString *)phase device:(NSInteger)deviceID operation:(BOOL (^)(void))operation;

// Submission-side hooks. Main thread; they return a stamp for the queue side.
- (uint64_t)noteSubmittedPlay:(uint64_t)submittedPlay track:(nullable AudioTrack *)track position:(NSTimeInterval)position paused:(BOOL)paused;
- (uint64_t)noteSubmittedAction:(NSString *)action position:(NSTimeInterval)position;

// Queue-side hooks.
- (void)noteAdmittedPlay:(uint64_t)submittedPlay submittedAt:(uint64_t)submittedAt;
- (void)noteAdmittedAction:(NSString *)action submittedAt:(uint64_t)submittedAt position:(NSTimeInterval)position;
- (void)noteOpenSettledForPlay:(uint64_t)submittedPlay track:(nullable AudioTrack *)track file:(nullable AVAudioFile *)file error:(nullable NSError *)error;
- (void)noteVoiceStarted:(VibeVoiceID)voice file:(AVAudioFile *)file fromFrame:(AVAudioFramePosition)frame reason:(NSString *)reason;
- (void)noteBusEvent:(VibeVoiceEvent)event voice:(VibeVoiceID)voice current:(BOOL)current;
- (void)noteSettled:(NSString *)what reason:(NSString *)reason;
// Wraps a main-thread delivery: logs its latency and whether it was accepted.
- (void)noteDelivery:(NSString *)what forPlay:(uint64_t)submittedPlay accepted:(BOOL)accepted deliveredAt:(uint64_t)deliveredAt;
- (uint64_t)deliveryStamp;

// The `Signal:` probe on the level tap: armed at every start and resume,
// re-anchored at a gapless boundary, and released once its capture ends.
// The tap is held for the capture on hardware even with no indicator demand.
@property (nonatomic, readonly) BOOL signalProbeWanted;
- (void)armSignalProbeOnQueue:(NSString *)reason;
- (void)noteRetiringAudioSilentOnQueue;
// The output node's own render clock, one block ahead; nil while it has none.
- (nullable AVAudioTime *)outputSignalRenderTimeOnQueue;

// Beta builds record the first UI position beyond each published playing
// position, so a late display can be told from late audio. Main thread.
- (void)notePublishedPlayingPosition:(NSTimeInterval)position track:(nullable AudioTrack *)track voice:(VibeVoiceID)voice;
// The body of the public noteDisplayedPosition:forTrack:, which AudioPlayer.m forwards here.
- (void)recordDisplayedPosition:(NSTimeInterval)position forTrack:(nullable AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
