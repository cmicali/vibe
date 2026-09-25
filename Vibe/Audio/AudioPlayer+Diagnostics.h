//
//  AudioPlayer+Diagnostics.h
//  Vibe
//
//  Audio-path reports for Settings and Debug in every build; Timeline, Phase,
//  Callback, Signal and Stall instrumentation under VIBE_VERBOSE_LOGGING.
//  Hooks leave transport readable. performDiagnosticPhase: always runs its
//  operation. All methods run on the player queue unless noted.
//

#import "AudioPlayer.h"
#import "AudioVoiceBus.h"
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Diagnostics)

// The render chain, stage by stage, from the source file to the output
// device: `stage` names each (source, decode, bus, varispeed, fx, meter,
// output, and on macOS device), `present` whether it is there now, and the
// rest is that stage's facts — rates, sample formats, channels, whether it
// is in the render. For the Settings window, the debug report and the
// dump_audio_path verb.
- (NSArray<NSDictionary<NSString *, id> *> *)audioPathOnQueue;


// Installs the process-lifetime stall watchers for the production player. Main thread.
- (void)startStallWatchers;

// The watcher's reads of queue-confined output state, from its timer on the queue.
- (BOOL)diagnosticOutputRunning;
// The play the current transport state belongs to: the loading submission
// while Loading, else the active one.
- (uint64_t)diagnosticPlayIdentifierOnQueue;

// Runs operation, timing it as a named phase of a device or pipeline change.
- (BOOL)performDiagnosticPhase:(NSString *)phase device:(NSInteger)deviceID operation:(BOOL (^)(void))operation;

// Submission-side hooks. Main thread; they return a stamp for the queue side.
- (uint64_t)noteSubmittedPlay:(uint64_t)submittedPlay track:(nullable AudioTrack *)track position:(NSTimeInterval)position paused:(BOOL)paused;
- (uint64_t)noteSubmittedAction:(NSString *)action position:(NSTimeInterval)position;

// Queue-side hooks.
- (void)noteAdmittedPlay:(uint64_t)submittedPlay submittedAt:(uint64_t)submittedAt;
- (void)noteAdmittedAction:(NSString *)action submittedAt:(uint64_t)submittedAt position:(NSTimeInterval)position;
- (void)noteOpenSettledForPlay:(uint64_t)submittedPlay track:(nullable AudioTrack *)track file:(nullable AudioFileHandle *)file error:(nullable NSError *)error;
- (void)noteVoiceStarted:(VibeVoiceID)voice file:(AudioFileHandle *)file fromFrame:(AVAudioFramePosition)frame reason:(NSString *)reason;
- (void)noteBusEvent:(VibeVoiceEvent)event voice:(VibeVoiceID)voice current:(BOOL)current;
// Every drain: the first-render line for a voice whose live event preceded its render.
- (void)noteDrainOnQueue;
- (void)noteSettled:(NSString *)what reason:(NSString *)reason;
// Wraps a main-thread delivery: logs its latency and whether it was accepted.
- (void)noteDelivery:(NSString *)what forPlay:(uint64_t)submittedPlay accepted:(BOOL)accepted deliveredAt:(uint64_t)deliveredAt;
- (uint64_t)deliveryStamp;

// The `Signal:` probe on the level meter: armed at every start and resume,
// re-anchored at a gapless boundary, and released once its capture ends.
// The meter is held for the capture on hardware even with no indicator demand.
@property (nonatomic, readonly) BOOL signalProbeWanted;
- (void)armSignalProbeOnQueue:(NSString *)reason;
- (void)noteRetiringAudioSilentOnQueue;

// Beta builds record the first UI position beyond each published playing
// position, so a late display can be told from late audio. Main thread.
- (void)notePublishedPlayingPosition:(NSTimeInterval)position track:(nullable AudioTrack *)track voice:(VibeVoiceID)voice;
// The body of the public noteDisplayedPosition:forTrack:, which AudioPlayer.m forwards here.
- (void)recordDisplayedPosition:(NSTimeInterval)position forTrack:(nullable AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
