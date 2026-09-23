// Shared manual output driver: paced app debugging or frame-driven audio tests.
#if DEBUG
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
NS_ASSUME_NONNULL_BEGIN
static const AVAudioFrameCount kVibeManualPumpMaxFrames = 4096;
@interface VibeManualRenderPump : NSObject
@property (nonatomic, readonly) AVAudioFormat *format;
@property (nonatomic, readonly) BOOL automatic;
@property (nonatomic, readonly) uint64_t renderedFrames;
@property (nonatomic, copy, nullable) void (^capture)(AVAudioPCMBuffer *buffer);
// The pump stands in for the IO thread, so the player hangs the two things
// the IO thread's cadence gives it on these hooks: beforeRender runs before
// every slice (the frame-driven mode decodes inline here; the automatic mode
// leaves it nil), afterRender after every slice (the drain, both modes).
@property (nonatomic, copy, nullable) dispatch_block_t beforeRender;
@property (nonatomic, copy, nullable) dispatch_block_t afterRender;
// The starved-decoder seam: while set, beforeRender is skipped, so a
// frame-driven bus underruns and zero-fills until it is cleared.
@property (nonatomic) BOOL starveDecoder;
- (instancetype)initWithFormat:(AVAudioFormat *)format automatic:(BOOL)automatic;
- (void)attachToEngine:(AVAudioEngine *)engine queue:(dispatch_queue_t)queue;
// Queue-confined. The returned buffer belongs to the pump until the next call.
- (nullable AVAudioPCMBuffer *)renderFrames:(AVAudioFrameCount)frames error:(NSError **)error;
- (void)scheduleAfter:(NSTimeInterval)seconds block:(dispatch_block_t)block;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
#endif
