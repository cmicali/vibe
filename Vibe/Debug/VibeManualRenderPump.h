//
//  VibeManualRenderPump.h
//  Vibe
//
//  Stands in for the HAL IO thread that `--no-audio-hw`'s manual rendering
//  mode never starts. A timer pulls frames through the engine at real-time
//  pace and discards them, so scheduled segments are consumed, completion
//  handlers fire, and lastRenderTime advances exactly as they would against
//  hardware — which is what lets the whole player be driven with no audio
//  device at all, under a sanitizer or on a machine with none.
//
//  Debug-only, whole file. An object rather than ivars on AudioPlayer, so the
//  player's shipping header carries no conditional about a pump that does not
//  ship; holding one is how it answers `manualRenderingActive`.
//

#if DEBUG

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// The pump's per-renderOffline chunk, which is also the engine's
// manual-rendering maximumFrameCount — one number, deliberately: the engine
// refuses a render larger than what it was configured for, so the caller that
// enables manual rendering reads it from here rather than picking its own.
static const AVAudioFrameCount kVibeManualPumpMaxFrames = 4096;

@interface VibeManualRenderPump : NSObject

// Starts pumping immediately. The engine must already be in manual rendering
// mode; queue is the player queue, and every tick runs on it, so the pump
// mutates the engine under the same serialization everything else does.
- (instancetype)initWithEngine:(AVAudioEngine *)engine queue:(dispatch_queue_t)queue;

// Idempotent, and safe from dealloc.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END

#endif
