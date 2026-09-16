// Shared manual output driver: paced app debugging or frame-driven audio tests.
#if DEBUG
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioFX.h"
NS_ASSUME_NONNULL_BEGIN
static const AVAudioFrameCount kVibeManualPumpMaxFrames = 4096;
@interface VibeManualRenderPump : NSObject
@property (nonatomic, readonly) AVAudioFormat *format;
@property (nonatomic, readonly) BOOL automatic;
@property (nonatomic, readonly) uint64_t renderedFrames;
@property (nonatomic, copy, nullable) void (^capture)(AVAudioPCMBuffer *buffer);
- (instancetype)initWithFormat:(AVAudioFormat *)format automatic:(BOOL)automatic;
- (void)attachToEngine:(AVAudioEngine *)engine queue:(dispatch_queue_t)queue;
// Queue-confined. The returned buffer belongs to the pump until the next call.
- (nullable AVAudioPCMBuffer *)renderFrames:(AVAudioFrameCount)frames error:(NSError **)error;
- (void)scheduleAfter:(NSTimeInterval)seconds block:(dispatch_block_t)block;
- (void)cancel;
@end

// The player attaches the same clock before FX installation. Debug-only.
@interface AudioFX (RenderDebug)
- (void)debugSetManualRenderPump:(VibeManualRenderPump *)pump;
@end
NS_ASSUME_NONNULL_END
#endif
