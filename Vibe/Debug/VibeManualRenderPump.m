#import "VibeManualRenderPump.h"
#if DEBUG
@implementation VibeManualRenderPump {
    __weak AVAudioEngine *_engine;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    AVAudioPCMBuffer *_buffer;
    AVAudioPCMBuffer *_chunk;
    NSMutableArray<NSDictionary *> *_pending;
    double _time;
    uint64_t _lastNs;
    double _frameDebt;
}
- (instancetype)initWithFormat:(AVAudioFormat *)format automatic:(BOOL)automatic {
    if ((self = [super init])) {
        _format = format;
        _automatic = automatic;
        _pending = [NSMutableArray array];
        _buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:kVibeManualPumpMaxFrames];
        _chunk = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:kVibeManualPumpMaxFrames];
    }
    return self;
}
- (void)attachToEngine:(AVAudioEngine *)engine queue:(dispatch_queue_t)queue {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    _frameDebt = 0;
    _engine = engine;
    _queue = queue;
    if (!_automatic) return;
    _lastNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    __weak VibeManualRenderPump *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tickOnQueue]; });
    dispatch_resume(_timer);
}
- (void)dealloc { [self cancel]; }
- (void)cancel {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    [_pending removeAllObjects];
    self.capture = nil;
    self.beforeRender = nil;
    self.afterRender = nil;
}
- (void)scheduleAfter:(NSTimeInterval)seconds block:(dispatch_block_t)block {
    if (_automatic) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), _queue, block);
        return;
    }
    NSDictionary *entry = @{@"time": @(_time + seconds), @"block": [block copy]};
    NSUInteger index = 0;
    while (index < _pending.count && [_pending[index][@"time"] doubleValue] <= _time + seconds) index++;
    [_pending insertObject:entry atIndex:index];
}
- (AVAudioPCMBuffer *)renderFrames:(AVAudioFrameCount)frames error:(NSError **)error {
    if (error) *error = nil;
    if (!frames || frames > kVibeManualPumpMaxFrames) {
        if (error) *error = [NSError errorWithDomain:@"VibeManualRender" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid render frame count"}];
        return nil;
    }
    _buffer.frameLength = 0;
    while (_buffer.frameLength < frames) {
        while (_pending.count && [_pending[0][@"time"] doubleValue] <= _time + 1e-10) {
            dispatch_block_t block = _pending[0][@"block"];
            [_pending removeObjectAtIndex:0];
            block();
        }
        AVAudioFrameCount count = frames - _buffer.frameLength;
        if (_pending.count) {
            double until = ([_pending[0][@"time"] doubleValue] - _time) * _format.sampleRate;
            count = MIN(count, (AVAudioFrameCount)MAX(1, ceil(until - 1e-7)));
        }
        _chunk.frameLength = 0;
        if (_engine.isRunning) {
            if (self.beforeRender && !self.starveDecoder) self.beforeRender();
            AVAudioEngineManualRenderingStatus status;
            // A graph mutation can temporarily prevent rendering. Retry only
            // a zero-frame result; never discard or duplicate a partial block.
            NSUInteger attempts = 0;
            do {
                status = [_engine renderOffline:count toBuffer:_chunk error:error];
            } while (status == AVAudioEngineManualRenderingStatusCannotDoInCurrentContext
                     && _chunk.frameLength == 0 && ++attempts < 8);
            if (status != AVAudioEngineManualRenderingStatusSuccess || _chunk.frameLength != count) {
                if (error && !*error) *error = [NSError errorWithDomain:@"VibeManualRender" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Render status %ld, %u of %u frames", (long)status, _chunk.frameLength, count]}];
                return nil;
            }
        } else {
            _chunk.frameLength = count;
            for (AVAudioChannelCount c = 0; c < _format.channelCount; c++) memset(_chunk.floatChannelData[c], 0, count * sizeof(float));
        }
        for (AVAudioChannelCount c = 0; c < _format.channelCount; c++)
            memcpy(_buffer.floatChannelData[c] + _buffer.frameLength, _chunk.floatChannelData[c], count * sizeof(float));
        _buffer.frameLength += count;
        _time += count / _format.sampleRate;
        _renderedFrames += count;
        if (self.afterRender) self.afterRender();
    }
    if (self.capture) self.capture(_buffer);
    return _buffer;
}
- (void)tickOnQueue {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    double elapsed = (double)(now - _lastNs) / NSEC_PER_SEC;
    _lastNs = now;
    if (!_engine.isRunning) { _frameDebt = 0; return; }
    _frameDebt += MIN(elapsed, 0.25) * _format.sampleRate;
    while (_frameDebt >= 1) {
        AVAudioFrameCount frames = (AVAudioFrameCount)MIN(_frameDebt, kVibeManualPumpMaxFrames);
        NSError *error = nil;
        if (![self renderFrames:frames error:&error]) {
            LogError(@"VibeManualRenderPump: %@", error);
            _frameDebt = 0;
            return;
        }
        _frameDebt -= frames;
    }
}
@end
#endif
