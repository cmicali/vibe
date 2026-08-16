//
//  VibeManualRenderPump.m
//  Vibe
//
//  See VibeManualRenderPump.h.
//

#import "VibeManualRenderPump.h"

#if DEBUG

// The tick interval, and the largest wall-clock gap credited per tick, so a
// debugger pause or queue stall does not render the backlog in one burst and
// teleport the position. The render chunk itself is kVibeManualPumpMaxFrames,
// in the header, because the engine's setup has to agree with it.
static const NSTimeInterval kManualPumpIntervalSeconds = 0.02;
static const NSTimeInterval kManualPumpMaxCatchUpSeconds = 0.25;

@implementation VibeManualRenderPump {
    __weak AVAudioEngine    *_engine;
    AVAudioPCMBuffer        *_buffer;
    dispatch_source_t       _timer;
    uint64_t                _lastNs;
    double                  _frameDebt;
}

- (instancetype)initWithEngine:(AVAudioEngine *)engine queue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _engine = engine;
        _buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:engine.manualRenderingFormat
                                                frameCapacity:kVibeManualPumpMaxFrames];
        _lastNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW,
                (uint64_t)(kManualPumpIntervalSeconds * NSEC_PER_SEC), 5 * NSEC_PER_MSEC);
        __weak VibeManualRenderPump *weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{
            [weakSelf tickOnQueue];
        });
        dispatch_resume(_timer);
    }
    return self;
}

- (void)dealloc {
    [self cancel];
}

- (void)cancel {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

// Rendering only while the engine is running keeps the pump inert across the
// idle stop, device rebinds and teardown, and re-baselining the clock on every
// tick means a stopped stretch is never credited as playback when the engine
// comes back.
- (void)tickOnQueue {
    AVAudioEngine *engine = _engine;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NSTimeInterval elapsed = (NSTimeInterval)(now - _lastNs) / NSEC_PER_SEC;
    _lastNs = now;
    if (!engine.isRunning) {
        _frameDebt = 0;
        return;
    }
    _frameDebt += MIN(elapsed, kManualPumpMaxCatchUpSeconds) * engine.manualRenderingFormat.sampleRate;
    while (_frameDebt >= 1) {
        AVAudioFrameCount frames = (AVAudioFrameCount)MIN(_frameDebt, (double)kVibeManualPumpMaxFrames);
        NSError *renderError = nil;
        if ([engine renderOffline:frames toBuffer:_buffer error:&renderError]
                != AVAudioEngineManualRenderingStatusSuccess) {
            LogError(@"VibeManualRenderPump: render failed (%@)", renderError);
            _frameDebt = 0;
            return;
        }
        _frameDebt -= frames;
    }
}

@end

#endif
