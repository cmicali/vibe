//
//  AudioPlayer+Engine.h
//  Vibe
//
//  Engine start, retained-track shutdown, deferred idle stop, and their beta
//  timing/signal observations.
//
//  The engine is not held running for the life of the player, because a running
//  engine owns the output device — which on Bluetooth keeps the link up, and on
//  any device stops another app from claiming an exclusive format. Nor is it
//  stopped the moment playback ends, because a natural track end is followed
//  within milliseconds by the auto-advance's play, and an immediate stop made
//  every consecutive-track transition pay an output-unit stop and start. So the
//  stop is deferred and cancelled by generation, and starting playback is the
//  single funnel that cancels it.
//
//  All run on the player queue.
//

#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Engine)

// Starts the engine if it is not already running, then plays node. Every path
// that starts or restarts playback goes through here, which is what dissolves
// any pending idle stop.
- (BOOL)startEngineAndPlayNode:(AVAudioPlayerNode *)node error:(NSError * _Nullable * _Nullable)outError;

// Arms the deferred idle stop. Call it wherever playback goes idle — a pause,
// a stop, a failure reset, a parked start.
- (void)scheduleEngineIdleStopOnQueue;

// Retires stop-fired completions and reschedules the retained track silently.
- (void)stopEnginePreservingTrackOnQueue;

// Queue-side beta phase attribution; the operation runs unchanged in stable builds.
- (uint64_t)diagnosticPlayIdentifierOnQueue;
- (void)beginOutputSignalDiagnosticsOnQueue:(NSString *)reason;
- (BOOL)performDiagnosticPhase:(NSString *)phase device:(NSInteger)deviceID
                     operation:(BOOL (^)(void))operation;

@end

NS_ASSUME_NONNULL_END
