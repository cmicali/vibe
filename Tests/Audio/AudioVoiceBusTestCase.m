//
//  AudioVoiceBusTestCase.m
//

#import "AudioVoiceBusTestCase.h"

#pragma mark - Fixtures

// Deterministic noise in [-0.5, 0.5): a seeded LCG, so a file's contents are a
// function of its seed and the comparison is exact.
static void FillNoise(float *samples, NSUInteger count, uint32_t seed) {
    uint32_t state = seed;
    for (NSUInteger i = 0; i < count; i++) {
        state = state * 1664525u + 1013904223u;
        samples[i] = ((float)(state >> 8) / 16777216.0f) - 0.5f;
    }
}

@implementation AudioVoiceBusTestCase

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    _queue = dispatch_queue_create("bus-tests", DISPATCH_QUEUE_SERIAL);
    _events = [NSMutableArray array];
    _endedSnapshots = [NSMutableDictionary dictionary];
    _endedErrors = [NSMutableDictionary dictionary];
}

- (void)tearDown {
    [self releaseOutput];
    _bus = nil;
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
}

// Interleaved float PCM at `rate`/`channels`, written as a float WAV.
- (NSURL *)writePCM:(NSData *)interleaved rate:(double)rate channels:(NSUInteger)channels name:(NSString *)name {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:(AVAudioChannelCount)channels];
    AVAudioFrameCount frames = (AVAudioFrameCount)(interleaved.length / channels / sizeof(float));
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:MAX(frames, 1u)];
    buffer.frameLength = frames;
    const float *p = interleaved.bytes;
    for (NSUInteger f = 0; f < frames; f++) {
        for (NSUInteger c = 0; c < channels; c++) {
            buffer.floatChannelData[c][f] = p[f * channels + c];
        }
    }
    return [self writeBuffer:buffer name:name];
}

- (NSURL *)writeBuffer:(AVAudioPCMBuffer *)buffer name:(NSString *)name {
    NSURL *url = [_temporary URLByAppendingPathComponent:name];
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"%@", error);
    return url;
}

- (NSData *)noiseFrames:(NSUInteger)frames channels:(NSUInteger)channels seed:(uint32_t)seed {
    NSMutableData *data = [NSMutableData dataWithLength:frames * channels * sizeof(float)];
    FillNoise(data.mutableBytes, frames * channels, seed);
    return data;
}

- (NSData *)constant:(float)value frames:(NSUInteger)frames channels:(NSUInteger)channels {
    NSMutableData *data = [NSMutableData dataWithLength:frames * channels * sizeof(float)];
    float *p = data.mutableBytes;
    for (NSUInteger i = 0; i < frames * channels; i++) {
        p[i] = value;
    }
    return data;
}

- (AudioFileHandle *)open:(NSURL *)url {
    NSError *error = nil;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(file, @"%@", error);
    return file;
}

#pragma mark - The bus and the render

- (void)makeBusAtRate:(double)rate channels:(NSUInteger)channels {
    [self makeBusAtRate:rate channels:channels inlineDecoding:YES];
}

// With a real decode queue, for the race tests: the fills are the bus's own.
- (void)makeBusAtRate:(double)rate channels:(NSUInteger)channels inlineDecoding:(BOOL)inlineDecoding {
    [self makeBusWithFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:(AVAudioChannelCount)channels]
             inlineDecoding:inlineDecoding];
}

- (void)makeBusWithFormat:(AVAudioFormat *)format inlineDecoding:(BOOL)inlineDecoding {
    [self releaseOutput];
    NSUInteger channels = format.channelCount;
    _bus = [[AudioVoiceBus alloc] initWithFormat:format queue:_queue inlineDecoding:inlineDecoding];
    XCTAssertNotNil(_bus);
    _output = calloc(1, sizeof(AudioBufferList) + (channels - 1) * sizeof(AudioBuffer));
    _output->mNumberBuffers = (UInt32)channels;
    for (NSUInteger c = 0; c < channels; c++) {
        _outputData[c] = calloc(4096, sizeof(float));
        _output->mBuffers[c].mNumberChannels = 1;
        _output->mBuffers[c].mData = _outputData[c];
    }
    _sampleTime = 0;
    [_events removeAllObjects];
    [_endedSnapshots removeAllObjects];
    [_endedErrors removeAllObjects];
}

- (void)releaseOutput {
    if (_output) {
        for (UInt32 c = 0; c < _output->mNumberBuffers; c++) {
            free(_outputData[c]);
            _outputData[c] = NULL;
        }
        free(_output);
        _output = NULL;
    }
}

- (VibeVoiceRamp)unity {
    return VibeVoiceRampMake(1, 0, VibeFadeCurveLinear, VibeVoiceActionNone);
}

- (VibeVoiceID)startFile:(AudioFileHandle *)file gain:(float)gain ramp:(VibeVoiceRamp)ramp paused:(BOOL)paused {
    return [_bus startVoiceWithFile:file atFrame:0 endFrame:0 gain:gain ramp:ramp paused:paused];
}

// One render of `frames`, appended to `capture` interleaved, with the fill
// before and the drain after, exactly as the pump does around a slice.
- (BOOL)render:(uint32_t)frames into:(NSMutableData *)capture {
    [_bus fillInline];
    BOOL silence = [self renderWithoutFilling:frames into:capture];
    [self drain];
    return silence;
}

- (BOOL)renderWithoutFilling:(uint32_t)frames into:(NSMutableData *)capture {
    UInt32 channels = _output->mNumberBuffers;
    for (UInt32 c = 0; c < channels; c++) {
        _output->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    AudioTimeStamp stamp = {0};
    stamp.mSampleTime = _sampleTime;
    stamp.mFlags = kAudioTimeStampSampleTimeValid;
    BOOL silence = NO;
    OSStatus status = VibeVoiceBusRender(_bus.mix, &silence, &stamp, frames, _output);
    XCTAssertEqual(status, noErr);
    _sampleTime += frames;
    if (capture) {
        NSUInteger start = capture.length;
        [capture increaseLengthBy:frames * channels * sizeof(float)];
        float *p = (float *)((uint8_t *)capture.mutableBytes + start);
        for (uint32_t f = 0; f < frames; f++) {
            for (UInt32 c = 0; c < channels; c++) {
                p[f * channels + c] = _outputData[c][f];
            }
        }
    }
    return silence;
}

- (void)drain {
    [_bus drainWithOutputRunning:YES handler:^(VibeVoiceID voice, VibeVoiceEvent event) {
        [self->_events addObject:@{@"voice": @(voice), @"event": @(event)}];
        if (event == VibeVoiceEventEnded) {
            NSError *error = [self->_bus errorOfVoice:voice failedFile:NULL];
            if (error) self->_endedErrors[@(voice)] = error;
            VibeVoiceSnapshot snapshot = [self->_bus snapshotOfVoice:voice];
            self->_endedSnapshots[@(voice)] = [NSValue valueWithBytes:&snapshot objCType:@encode(VibeVoiceSnapshot)];
        }
    }];
}

- (BOOL)hasEnded:(VibeVoiceID)voice {
    return _endedSnapshots[@(voice)] != nil;
}

- (VibeVoiceSnapshot)endedSnapshot:(VibeVoiceID)voice {
    VibeVoiceSnapshot snapshot = {0};
    XCTAssertNotNil(_endedSnapshots[@(voice)], @"voice %llu never ended", voice);
    [_endedSnapshots[@(voice)] getValue:&snapshot];
    return snapshot;
}

- (NSData *)renderUntilEnded:(VibeVoiceID)voice blockSize:(uint32_t)block limit:(NSUInteger)limit {
    NSMutableData *capture = [NSMutableData data];
    while (![self hasEnded:voice] && capture.length / sizeof(float) < limit) {
        [self render:block into:capture];
    }
    XCTAssertTrue([self hasEnded:voice], @"voice %llu did not end within the limit", voice);
    return capture;
}

- (NSArray<NSNumber *> *)eventsForVoice:(VibeVoiceID)voice {
    NSMutableArray *events = [NSMutableArray array];
    for (NSDictionary *entry in _events) {
        if ([entry[@"voice"] unsignedLongLongValue] == voice) {
            [events addObject:entry[@"event"]];
        }
    }
    return events;
}

- (void)assertCapture:(NSData *)capture equalsSource:(NSData *)source {
    XCTAssertEqual(capture.length, source.length);
    XCTAssertEqual(memcmp(capture.bytes, source.bytes, MIN(capture.length, source.length)), 0,
                   @"first differing sample at %lu", (unsigned long)[self firstDifference:capture from:source]);
}

- (NSUInteger)firstDifference:(NSData *)a from:(NSData *)b {
    const float *x = a.bytes, *y = b.bytes;
    NSUInteger count = MIN(a.length, b.length) / sizeof(float);
    for (NSUInteger i = 0; i < count; i++) {
        if (x[i] != y[i]) {
            return i;
        }
    }
    return NSNotFound;
}

- (void)assertSilent:(NSData *)capture from:(NSUInteger)sample {
    const float *p = capture.bytes;
    for (NSUInteger i = sample; i < capture.length / sizeof(float); i++) {
        XCTAssertEqual(p[i], 0.0f, @"sound at sample %lu", (unsigned long)i);
    }
}

@end
