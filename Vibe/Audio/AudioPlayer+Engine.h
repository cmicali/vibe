//
//  AudioPlayer+Engine.h
//  Vibe
//
//  When the AVAudioEngine runs, and nothing else. Two methods, and they are a
//  pair: one starts the engine to play a node, the other stops it once playback
//  has been idle long enough to be worth releasing the output device for.
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
//  Both run on the player queue.
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

@end

NS_ASSUME_NONNULL_END
