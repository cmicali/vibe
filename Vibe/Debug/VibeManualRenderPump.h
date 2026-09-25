// Shared manual output driver: paced app debugging or frame-driven audio tests.
#if DEBUG
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
NS_ASSUME_NONNULL_BEGIN
// Larger than the pipeline's slice, so a test can hand the render a cycle it
// must slice, as a device with a big IO buffer would.
static const AVAudioFrameCount kVibeManualPumpMaxFrames = 16384;
// What the pump pulls: `count` frames into `chunk` (its frameLength set on
// return). The player hands it the pipeline's render, which keeps its own
// timeline.
typedef OSStatus (^VibeManualRenderBlock)(AVAudioPCMBuffer *chunk, AVAudioFrameCount count);
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
// The output's format moved under the pump — a test's device rate change:
// the buffers follow, the clock and the pending steps stay. Queue-confined.
- (BOOL)adoptFormat:(AVAudioFormat *)format;
// `running` says whether the output is started; stopped, a slice is silence.
- (void)attachRender:(VibeManualRenderBlock)render running:(BOOL (^)(void))running queue:(dispatch_queue_t)queue;
// Queue-confined. The returned buffer belongs to the pump until the next call.
- (nullable AVAudioPCMBuffer *)renderFrames:(AVAudioFrameCount)frames error:(NSError **)error;
- (void)scheduleAfter:(NSTimeInterval)seconds block:(dispatch_block_t)block;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
#endif
