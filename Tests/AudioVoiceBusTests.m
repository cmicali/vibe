//
//  AudioVoiceBusTests.m
//  VibeTests
//
//  The voice bus with no engine: the tests own the output buffers and call
//  the render block themselves, so every frame the audio thread would produce
//  is compared against the file it came from. Inline decoding keeps the whole
//  thing on this thread — fills before renders, deterministically.
//
//  A voice's snapshot is readable until the drain reports it ended, and the
//  same drain recycles the slot; so the harness captures the snapshot inside
//  that handler, exactly as the player must.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioVoiceBusInternal.h"
#import <objc/runtime.h>

static const double kRate = 48000;

@interface AudioVoiceBusTests : XCTestCase
@end

@implementation AudioVoiceBusTests {
    NSURL *_temporary;
    AudioVoiceBus *_bus;
    dispatch_queue_t _queue;
    AudioBufferList *_output;
    float *_outputData[8];
    double _sampleTime;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableDictionary<NSNumber *, NSValue *> *_endedSnapshots;
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    _queue = dispatch_queue_create("bus-tests", DISPATCH_QUEUE_SERIAL);
    _events = [NSMutableArray array];
    _endedSnapshots = [NSMutableDictionary dictionary];
}

- (void)tearDown {
    [self releaseOutput];
    _bus = nil;
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
}

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
    NSMutableDictionary *settings = [buffer.format.settings mutableCopy];
    settings[AVLinearPCMIsNonInterleaved] = @NO;
    NSURL *url = [_temporary URLByAppendingPathComponent:name];
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertTrue([file writeFromBuffer:buffer error:&error], @"%@", error);
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

- (AVAudioFile *)open:(NSURL *)url {
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
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

- (VibeVoiceID)startFile:(AVAudioFile *)file gain:(float)gain ramp:(VibeVoiceRamp)ramp paused:(BOOL)paused {
    return [_bus startVoiceWithFile:file atFrame:0 decodeFormat:file.processingFormat gain:gain ramp:ramp paused:paused];
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

#pragma mark - Passthrough and ends

- (void)testPassthroughIsExactAtEveryBlockSizeAndEndsOnce {
    NSData *source = [self noiseFrames:20000 channels:2 seed:1];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"noise.wav"];
    for (NSNumber *block in @[@63, @256, @1024, @4096]) {
        [self makeBusAtRate:kRate channels:2];
        VibeVoiceID voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
        NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:200000];
        [self assertCapture:[capture subdataWithRange:NSMakeRange(0, source.length)] equalsSource:source];
        [self assertSilent:capture from:source.length / sizeof(float)];
        VibeVoiceSnapshot snapshot = [self endedSnapshot:voice];
        XCTAssertEqual(snapshot.ended, VibeVoiceEndOfStream, @"block %@", block);
        XCTAssertEqual(snapshot.consumed, 20000u, @"block %@", block);
        XCTAssertEqual(snapshot.endOfStream, 20000u, @"block %@", block);
        XCTAssertEqual(snapshot.underrunFrames, 0u, @"block %@", block);
        XCTAssertEqualObjects([self eventsForVoice:voice], (@[@(VibeVoiceEventLive), @(VibeVoiceEventEnded)]), @"block %@", block);
        // The slot is back, and a render after the end is silence.
        XCTAssertEqual([_bus occupiedSlotCount], 0u, @"block %@", block);
        XCTAssertEqual([_bus snapshotOfVoice:voice].state, VibeVoiceStateNone);
        XCTAssertTrue([self render:256 into:nil]);
    }
}

- (void)testATruncatedFileEndsInsteadOfWaitingForItsHeaderLength {
    NSData *source = [self noiseFrames:30000 channels:2 seed:2];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"truncated.wav"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:NULL];
    [handle truncateAtOffset:44 + 10000 * 2 * sizeof(float) error:NULL];
    [handle closeFile];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:100000];
    VibeVoiceSnapshot snapshot = [self endedSnapshot:voice];
    XCTAssertEqual(snapshot.ended, VibeVoiceEndOfStream);
    XCTAssertLessThanOrEqual(snapshot.consumed, 10000u);
    XCTAssertGreaterThan(snapshot.consumed, 9000u);
    XCTAssertLessThan(capture.length / sizeof(float) / 2, 12000u);
}

- (void)testAStartFromAFrameBeginsThere {
    NSData *source = [self noiseFrames:20000 channels:2 seed:13];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"offset.wav"];
    [self makeBusAtRate:kRate channels:2];
    AVAudioFile *file = [self open:url];
    VibeVoiceID voice = [_bus startVoiceWithFile:file atFrame:12345 decodeFormat:file.processingFormat gain:1
                                            ramp:[self unity] paused:NO];
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:100000];
    NSData *tail = [source subdataWithRange:NSMakeRange(12345 * 8, source.length - 12345 * 8)];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, tail.length)] equalsSource:tail];
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 20000u - 12345u);
}

#pragma mark - Ramps

- (void)testAFadeInLandsExactlyOnUnityAndAZeroFadeIsACut {
    NSData *source = [self noiseFrames:8192 channels:2 seed:3];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"fade.wav"];
    [self makeBusAtRate:kRate channels:2];
    const uint32_t frames = 480;
    VibeVoiceID voice = [self startFile:[self open:url] gain:0 ramp:VibeVoiceRampMake(1, frames, VibeFadeCurveLinear, VibeVoiceActionNone) paused:NO];
    NSMutableData *capture = [NSMutableData data];
    [self render:1024 into:capture];
    const float *out = capture.bytes, *in = source.bytes;
    for (uint32_t f = 0; f < 1024; f++) {
        float gain = VibeFadeGainAtFrame(VibeFadeCurveLinear, 0, 1, f, frames);
        XCTAssertEqual(out[f * 2], gain * in[f * 2], @"frame %u", f);
        if (f >= frames) {
            XCTAssertEqual(out[f * 2 + 1], in[f * 2 + 1], @"frame %u should be unity", f);
        }
    }
    // A cut to silence lands before the next mixed frame, and the voice dies.
    [_bus setRamp:VibeVoiceRampMake(0, 0, VibeFadeCurveLinear, VibeVoiceActionRetire) forVoice:voice];
    [capture setLength:0];
    BOOL silence = [self render:256 into:capture];
    XCTAssertTrue(silence);
    [self assertSilent:capture from:0];
    XCTAssertEqual([self endedSnapshot:voice].ended, VibeVoiceEndRetired);
    XCTAssertEqual([self endedSnapshot:voice].consumed, 1024u);
}

- (void)testEqualPowerCrossfadeHoldsLevelAndRetiresTheOutgoingVoiceOnTime {
    NSURL *left = [self writePCM:[self constant:0.25f frames:96000 channels:1] rate:kRate channels:1 name:@"left.wav"];
    NSURL *right = [self writePCM:[self constant:0.25f frames:96000 channels:1] rate:kRate channels:1 name:@"right.wav"];
    [self makeBusAtRate:kRate channels:1];
    const uint32_t frames = 24000;
    VibeVoiceID outgoing = [self startFile:[self open:left] gain:1 ramp:VibeVoiceRampMake(0, frames, VibeFadeCurveEqualPower, VibeVoiceActionRetire) paused:NO];
    VibeVoiceID incoming = [self startFile:[self open:right] gain:0 ramp:VibeVoiceRampMake(1, frames, VibeFadeCurveEqualPower, VibeVoiceActionNone) paused:NO];
    NSMutableData *capture = [NSMutableData data];
    while (capture.length / sizeof(float) < frames + 4096) {
        [self render:512 into:capture];
    }
    const float *mix = capture.bytes;
    for (uint32_t f = 0; f < frames; f += 97) {
        float outGain = VibeFadeGainAtFrame(VibeFadeCurveEqualPower, 1, 0, f, frames);
        float inGain = VibeFadeGainAtFrame(VibeFadeCurveEqualPower, 0, 1, f, frames);
        XCTAssertEqualWithAccuracy(mix[f], 0.25f * (outGain + inGain), 1e-6, @"frame %u", f);
        XCTAssertEqualWithAccuracy(outGain * outGain + inGain * inGain, 1.0f, 1e-5);
    }
    XCTAssertEqualWithAccuracy(mix[frames / 2], 0.25f * 2 * sqrtf(0.5f), 1e-5);
    XCTAssertEqual(mix[frames], 0.25f, @"the incoming voice alone, at unity, from the landing frame");
    XCTAssertEqual([self endedSnapshot:outgoing].ended, VibeVoiceEndRetired);
    XCTAssertEqual([self endedSnapshot:outgoing].consumed, (uint64_t)frames);
    XCTAssertEqual([_bus snapshotOfVoice:incoming].state, VibeVoiceStateLive);
    XCTAssertEqual([_bus snapshotOfVoice:incoming].ended, VibeVoiceEndNone);
}

- (void)testAPauseLandsOnTheExactFrameAndAnyNewerRampResumesInPlace {
    NSData *source = [self noiseFrames:40000 channels:2 seed:4];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"pause.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    [self render:1000 into:nil];
    [_bus setRamp:VibeVoiceRampMake(0, 480, VibeFadeCurveLinear, VibeVoiceActionPause) forVoice:voice];
    NSMutableData *capture = [NSMutableData data];
    [self render:4096 into:capture];
    VibeVoiceSnapshot snapshot = [_bus snapshotOfVoice:voice];
    XCTAssertTrue(snapshot.paused);
    XCTAssertEqual(snapshot.consumed, 1480u);
    [self assertSilent:capture from:480 * 2];
    XCTAssertTrue([self render:512 into:nil], @"a paused voice renders silence");
    XCTAssertEqual([_bus snapshotOfVoice:voice].consumed, 1480u, @"and holds its position");
    // Any newer ramp un-pauses: the next frame is the one after the pause.
    [_bus setRamp:VibeVoiceRampMake(1, 480, VibeFadeCurveLinear, VibeVoiceActionNone) forVoice:voice];
    [capture setLength:0];
    [self render:1024 into:capture];
    const float *out = capture.bytes, *in = source.bytes;
    for (uint32_t f = 0; f < 1024; f++) {
        float gain = VibeFadeGainAtFrame(VibeFadeCurveLinear, 0, 1, f, 480);
        XCTAssertEqual(out[f * 2], gain * in[(1480 + f) * 2], @"frame %u after resume", f);
    }
    XCTAssertFalse([_bus snapshotOfVoice:voice].paused);
}

- (void)testAVoiceCreatedPausedRendersNothingUntilRamped {
    NSData *source = [self noiseFrames:8192 channels:2 seed:5];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"parked.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:url] gain:0 ramp:[self unity] paused:YES];
    XCTAssertTrue([self render:1024 into:nil]);
    XCTAssertEqual([_bus snapshotOfVoice:voice].consumed, 0u);
    XCTAssertEqual([_bus snapshotOfVoice:voice].state, VibeVoiceStateLive);
    XCTAssertTrue([_bus snapshotOfVoice:voice].paused);
    [_bus setRamp:VibeVoiceRampMake(1, 480, VibeFadeCurveLinear, VibeVoiceActionNone) forVoice:voice];
    NSMutableData *capture = [NSMutableData data];
    [self render:512 into:capture];
    XCTAssertEqual([_bus snapshotOfVoice:voice].consumed, 512u);
    XCTAssertEqual(((const float *)capture.bytes)[2 * 500], ((const float *)source.bytes)[2 * 500]);
}

#pragma mark - Successors

- (void)testASuccessorContinuesExactlyAtTheBoundaryAtEveryBlockSize {
    NSData *whole = [self noiseFrames:48001 channels:2 seed:6];
    NSUInteger split = 20003;
    NSURL *first = [self writePCM:[whole subdataWithRange:NSMakeRange(0, split * 8)] rate:kRate channels:2 name:@"first.wav"];
    NSURL *second = [self writePCM:[whole subdataWithRange:NSMakeRange(split * 8, whole.length - split * 8)] rate:kRate channels:2 name:@"second.wav"];
    for (NSNumber *block in @[@63, @256, @1024, @4096]) {
        [self makeBusAtRate:kRate channels:2];
        AVAudioFile *successor = [self open:second];
        VibeVoiceID voice = [self startFile:[self open:first] gain:1 ramp:[self unity] paused:NO];
        XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
        NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:200000];
        [self assertCapture:[capture subdataWithRange:NSMakeRange(0, whole.length)] equalsSource:whole];
        VibeVoiceSnapshot snapshot = [self endedSnapshot:voice];
        XCTAssertEqual(snapshot.boundary, (uint64_t)split, @"block %@", block);
        XCTAssertEqual(snapshot.endOfStream, 48001u, @"block %@", block);
        XCTAssertEqualObjects([self eventsForVoice:voice],
                              (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]), @"block %@", block);
    }
}

- (void)testAOneFrameSuccessorReportsItsBoundaryBeforeTheEnd {
    NSData *whole = [self noiseFrames:5000 channels:2 seed:7];
    NSURL *first = [self writePCM:[whole subdataWithRange:NSMakeRange(0, 4999 * 8)] rate:kRate channels:2 name:@"long.wav"];
    NSURL *second = [self writePCM:[whole subdataWithRange:NSMakeRange(4999 * 8, 8)] rate:kRate channels:2 name:@"one.wav"];
    [self makeBusAtRate:kRate channels:2];
    AVAudioFile *successor = [self open:second];
    VibeVoiceID voice = [self startFile:[self open:first] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
    NSData *capture = [self renderUntilEnded:voice blockSize:4096 limit:20000];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, whole.length)] equalsSource:whole];
    XCTAssertEqualObjects([self eventsForVoice:voice],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    XCTAssertEqual([self endedSnapshot:voice].boundary, 4999u);
}

- (void)testUnqueueingBeforeTheSwitchEndsAtTheFileAndAfterItReportsTheSwitch {
    NSData *whole = [self noiseFrames:60000 channels:2 seed:8];
    NSURL *first = [self writePCM:[whole subdataWithRange:NSMakeRange(0, 30000 * 8)] rate:kRate channels:2 name:@"a.wav"];
    NSURL *second = [self writePCM:[whole subdataWithRange:NSMakeRange(30000 * 8, 30000 * 8)] rate:kRate channels:2 name:@"b.wav"];
    // Before: the decoder has not reached the end; the voice ends at its own file.
    [self makeBusAtRate:kRate channels:2];
    AVAudioFile *successor = [self open:second];
    VibeVoiceID voice = [self startFile:[self open:first] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
    XCTAssertTrue([_bus unqueueSuccessorForVoice:voice]);
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:200000];
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 30000u);
    XCTAssertEqual([self endedSnapshot:voice].boundary, UINT64_MAX);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 30000 * 8)] equalsSource:[whole subdataWithRange:NSMakeRange(0, 30000 * 8)]];
    // After: a short first file is fully decoded — successor frames included —
    // before the unqueue, which must say so.
    NSURL *shortFirst = [self writePCM:[whole subdataWithRange:NSMakeRange(0, 2000 * 8)] rate:kRate channels:2 name:@"short.wav"];
    [self makeBusAtRate:kRate channels:2];
    successor = [self open:second];
    voice = [self startFile:[self open:shortFirst] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
    [_bus fillInline];
    XCTAssertFalse([_bus unqueueSuccessorForVoice:voice]);
    XCTAssertEqual([_bus snapshotOfVoice:voice].boundary, 2000u);
    // And a live voice whose stream has ended still takes one: the decoder
    // reopens the stream at the old end, so the continuation is exact.
    [self makeBusAtRate:kRate channels:2];
    successor = [self open:second];
    voice = [self startFile:[self open:shortFirst] gain:1 ramp:[self unity] paused:NO];
    [_bus fillInline];
    XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, 2000u);
    XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
    capture = [self renderUntilEnded:voice blockSize:1024 limit:200000];
    XCTAssertEqual([self endedSnapshot:voice].boundary, 2000u);
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 32000u);
    NSMutableData *reopened = [[whole subdataWithRange:NSMakeRange(0, 2000 * 8)] mutableCopy];
    [reopened appendData:[whole subdataWithRange:NSMakeRange(30000 * 8, 30000 * 8)]];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 32000 * 8)] equalsSource:reopened];
    XCTAssertEqualObjects([self eventsForVoice:voice],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    // A dead voice takes none.
    XCTAssertFalse([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
}

// A gapless album is one voice: each successor is queued only after the
// previous boundary was reported, and every boundary is reported by value.
- (void)testOneVoiceChainsSuccessorsAndReportsEachBoundary {
    NSData *whole = [self noiseFrames:9000 channels:2 seed:12];
    NSURL *a = [self writePCM:[whole subdataWithRange:NSMakeRange(0, 2000 * 8)] rate:kRate channels:2 name:@"a.wav"];
    NSURL *b = [self writePCM:[whole subdataWithRange:NSMakeRange(2000 * 8, 3000 * 8)] rate:kRate channels:2 name:@"b.wav"];
    NSURL *c = [self writePCM:[whole subdataWithRange:NSMakeRange(5000 * 8, 4000 * 8)] rate:kRate channels:2 name:@"c.wav"];
    [self makeBusAtRate:kRate channels:2];
    AVAudioFile *second = [self open:b], *third = [self open:c];
    VibeVoiceID voice = [self startFile:[self open:a] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:second decodeFormat:second.processingFormat forVoice:voice]);
    NSMutableData *capture = [NSMutableData data];
    // a and b decode whole before the first render, so b's end is known when
    // the first boundary is reported; queuing c then reopens the stream.
    while ([self eventsForVoice:voice].count < 2 && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqualObjects([self eventsForVoice:voice], (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary)]));
    XCTAssertEqual([_bus snapshotOfVoice:voice].boundary, 2000u);
    XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, 5000u);
    XCTAssertTrue([_bus queueSuccessor:third decodeFormat:third.processingFormat forVoice:voice]);
    while (![self hasEnded:voice] && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqualObjects([self eventsForVoice:voice],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    XCTAssertEqual([self endedSnapshot:voice].boundary, 5000u);
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 9000u);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 9000 * 8)] equalsSource:whole];
}

#pragma mark - Starvation, kills and the pool

- (void)testAnUnderrunHoldsThePositionAndCountsThenContinuesExactly {
    NSData *source = [self noiseFrames:100000 channels:2 seed:9];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"long.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    [_bus fillInline];
    uint64_t buffered = [_bus snapshotOfVoice:voice].written;
    XCTAssertGreaterThan(buffered, 40000u);
    // Render past what is buffered without feeding it.
    uint32_t rendered = 0;
    while (rendered < buffered + 2048) {
        [self renderWithoutFilling:1024 into:nil];
        rendered += 1024;
    }
    VibeVoiceSnapshot snapshot = [_bus snapshotOfVoice:voice];
    XCTAssertEqual(snapshot.consumed, buffered);
    XCTAssertEqual(snapshot.underrunFrames, rendered - buffered);
    XCTAssertEqual(snapshot.ended, VibeVoiceEndNone);
    // Fed again, the next frame is the one after the last consumed.
    NSMutableData *capture = [NSMutableData data];
    [self render:1024 into:capture];
    XCTAssertEqual(((const float *)capture.bytes)[0], ((const float *)source.bytes)[buffered * 2]);
    XCTAssertEqual([_bus snapshotOfVoice:voice].consumed, buffered + 1024);
}

- (void)testAKilledVoiceIsSilentAtTheNextRenderAndItsSlotFreesAfterIt {
    NSData *source = [self noiseFrames:20000 channels:2 seed:10];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"kill.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    [self render:512 into:nil];
    [_bus killVoice:voice];
    XCTAssertEqual([_bus occupiedSlotCount], 1u, @"a live voice needs a render to die");
    XCTAssertEqual([_bus snapshotOfVoice:voice].state, VibeVoiceStateLive);
    XCTAssertTrue([self render:512 into:nil]);
    XCTAssertEqual([self endedSnapshot:voice].ended, VibeVoiceEndRetired);
    XCTAssertEqual([self endedSnapshot:voice].consumed, 512u);
    XCTAssertEqual([_bus occupiedSlotCount], 0u, @"the render that killed it is the last to touch it");
    XCTAssertEqual([_bus snapshotOfVoice:voice].state, VibeVoiceStateNone);
    // An armed voice — never rendered — dies without one.
    voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    XCTAssertEqual([_bus snapshotOfVoice:voice].state, VibeVoiceStateArmed);
    [_bus killVoice:voice];
    [_bus drainWithOutputRunning:NO handler:^(VibeVoiceID v, VibeVoiceEvent e) {}];
    XCTAssertEqual([_bus occupiedSlotCount], 0u);
}

// The pool keeps two slots in reserve by cutting the oldest retiring voice,
// and a start that still finds no slot waits, invisibly, for the first one.
- (void)testAFullPoolCutsTheOldestRetiringVoiceAndBindsAPendingStart {
    NSData *source = [self noiseFrames:20000 channels:2 seed:11];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"pool.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceRamp retiring = VibeVoiceRampMake(0, 96000, VibeFadeCurveEqualPower, VibeVoiceActionRetire);
    NSMutableArray<NSNumber *> *voices = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {
        [voices addObject:@([self startFile:[self open:url] gain:1 ramp:retiring paused:NO])];
        [self render:64 into:nil];
    }
    // Starts 7 and 8 found two free slots and cut the two oldest, which died
    // at the renders that followed; the reserve holds.
    XCTAssertEqual([_bus occupiedSlotCount], 6u);
    XCTAssertEqual([_bus snapshotOfVoice:voices[0].unsignedLongLongValue].state, VibeVoiceStateNone);
    XCTAssertEqual([_bus snapshotOfVoice:voices[1].unsignedLongLongValue].state, VibeVoiceStateNone);
    XCTAssertEqual([_bus snapshotOfVoice:voices[2].unsignedLongLongValue].state, VibeVoiceStateLive);
    XCTAssertEqual([self endedSnapshot:voices[0].unsignedLongLongValue].ended, VibeVoiceEndRetired);
    // Voices that never retire cannot be cut: eight of them fill the pool,
    // and the ninth is pending until one dies.
    [self makeBusAtRate:kRate channels:2];
    [voices removeAllObjects];
    for (int i = 0; i < 8; i++) {
        [voices addObject:@([self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO])];
    }
    [self render:64 into:nil];
    XCTAssertEqual([_bus slotCountInState:VibeVoiceStateLive], 8u);
    VibeVoiceID pending = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    XCTAssertEqual([_bus pendingVoiceCount], 1u);
    XCTAssertEqual([_bus occupiedSlotCount], 9u);
    XCTAssertEqual([_bus snapshotOfVoice:pending].state, VibeVoiceStateArmed);
    // Its requests are kept until it is bound.
    [_bus setRamp:VibeVoiceRampMake(0.5f, 0, VibeFadeCurveLinear, VibeVoiceActionNone) forVoice:pending];
    [_bus killVoice:voices[0].unsignedLongLongValue];
    [self render:64 into:nil]; // the kill lands, the drain recycles and binds
    XCTAssertEqual([_bus pendingVoiceCount], 0u);
    NSMutableData *capture = [NSMutableData data];
    [self render:64 into:capture];
    XCTAssertEqual([_bus snapshotOfVoice:pending].state, VibeVoiceStateLive);
    XCTAssertEqual([_bus snapshotOfVoice:pending].consumed, 64u);
    // Seven voices at unity, 128 frames in, plus the new one at half from its
    // first frame: the mix says the half is there.
    const float *out = capture.bytes, *in = source.bytes;
    XCTAssertEqualWithAccuracy(out[0], 7.0f * in[128 * 2] + 0.5f * in[0], 1e-5);
}

// Every started voice ends exactly once, a pending one killed before it ever
// had a slot included: the transport tracks fading voices by their end event.
- (void)testAPendingVoiceKilledBeforeItsSlotStillEnds {
    NSData *source = [self noiseFrames:20000 channels:2 seed:13];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"pending-kill.wav"];
    [self makeBusAtRate:kRate channels:2];
    for (int i = 0; i < 8; i++) {
        [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    }
    [self render:64 into:nil];
    VibeVoiceID pending = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    XCTAssertEqual([_bus pendingVoiceCount], 1u);
    [_bus killVoice:pending];
    XCTAssertEqual([_bus pendingVoiceCount], 0u);
    XCTAssertFalse([self hasEnded:pending], @"its end is the drain's to report");
    [self drain];
    XCTAssertTrue([self hasEnded:pending]);
    XCTAssertEqual([self endedSnapshot:pending].state, VibeVoiceStateNone);
    XCTAssertEqual([_bus occupiedSlotCount], 8u);
}

// A successor queued while the start was still pending rides into the slot
// the drain binds it to: the voice continues into it at its boundary.
- (void)testASuccessorQueuedOnAPendingVoiceSurvivesItsBind {
    NSData *filler = [self noiseFrames:20000 channels:2 seed:14];
    NSURL *fillerURL = [self writePCM:filler rate:kRate channels:2 name:@"filler.wav"];
    NSData *whole = [self noiseFrames:5000 channels:2 seed:15];
    NSURL *a = [self writePCM:[whole subdataWithRange:NSMakeRange(0, 2000 * 8)] rate:kRate channels:2 name:@"pending-a.wav"];
    NSURL *b = [self writePCM:[whole subdataWithRange:NSMakeRange(2000 * 8, 3000 * 8)] rate:kRate channels:2 name:@"pending-b.wav"];
    [self makeBusAtRate:kRate channels:2];
    NSMutableArray<NSNumber *> *voices = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {
        [voices addObject:@([self startFile:[self open:fillerURL] gain:1 ramp:[self unity] paused:NO])];
    }
    [self render:64 into:nil];
    AVAudioFile *successor = [self open:b];
    VibeVoiceID pending = [self startFile:[self open:a] gain:1 ramp:[self unity] paused:NO];
    XCTAssertEqual([_bus pendingVoiceCount], 1u);
    XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:pending]);
    [_bus killVoice:voices[0].unsignedLongLongValue];
    [self render:64 into:nil]; // the kill lands, the drain recycles and binds
    XCTAssertEqual([_bus pendingVoiceCount], 0u);
    NSMutableData *capture = [NSMutableData data];
    while (![self hasEnded:pending] && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqualObjects([self eventsForVoice:pending],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    XCTAssertEqual([self endedSnapshot:pending].boundary, 2000u);
    XCTAssertEqual([self endedSnapshot:pending].endOfStream, 5000u);
    XCTAssertEqual([self endedSnapshot:pending].consumed, 5000u);
    XCTAssertEqual([self endedSnapshot:pending].ended, VibeVoiceEndOfStream);
}

- (void)testAPendingPausedVoiceResumesBeforeItBinds {
    NSURL *url = [self writePCM:[self noiseFrames:20000 channels:2 seed:42] rate:kRate channels:2 name:@"pending-resume.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID first = 0;
    for (int i = 0; i < 8; i++) {
        VibeVoiceID v = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
        if (i == 0) first = v;
    }
    [self render:64 into:nil];
    VibeVoiceID pending = [self startFile:[self open:url] gain:0 ramp:[self unity] paused:YES];
    XCTAssertEqual([_bus pendingVoiceCount], 1u);
    [_bus setRamp:[self unity] forVoice:pending];
    [_bus killVoice:first];
    [self render:64 into:nil];
    [self render:64 into:nil];
    XCTAssertFalse([_bus snapshotOfVoice:pending].paused);
    XCTAssertEqual([_bus snapshotOfVoice:pending].consumed, 64u);
}

- (void)testAQueuedRecycleCannotEraseAReusedSlot {
    self.continueAfterFailure = YES;
    NSURL *url = [self writePCM:[self noiseFrames:20000 channels:2 seed:43] rate:kRate channels:2 name:@"recycle.wav"];
    [self makeBusAtRate:kRate channels:2 inlineDecoding:NO];
    [self renderWithoutFilling:64 into:nil];
    dispatch_queue_t decoder = _bus.decodeQueue;
    dispatch_semaphore_t initial = dispatch_semaphore_create(0);
    dispatch_semaphore_t initialEntered = dispatch_semaphore_create(0);
    dispatch_semaphore_t between = dispatch_semaphore_create(0);
    dispatch_semaphore_t betweenEntered = dispatch_semaphore_create(0);
    dispatch_async(decoder, ^{
        dispatch_semaphore_signal(initialEntered);
        dispatch_semaphore_wait(initial, DISPATCH_TIME_FOREVER);
    });
    dispatch_semaphore_wait(initialEntered, DISPATCH_TIME_FOREVER);
    VibeVoiceID old = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    [_bus killVoice:old];
    [_bus drainWithOutputRunning:YES handler:^(VibeVoiceID voice, VibeVoiceEvent event) {}];
    dispatch_async(decoder, ^{
        dispatch_semaphore_signal(betweenEntered);
        dispatch_semaphore_wait(between, DISPATCH_TIME_FOREVER);
    });
    // A second poll while recycling is still waiting behind decoder work.
    [_bus drainWithOutputRunning:YES handler:^(VibeVoiceID voice, VibeVoiceEvent event) {}];
    dispatch_semaphore_signal(initial);
    dispatch_semaphore_wait(betweenEntered, DISPATCH_TIME_FOREVER);
    XCTAssertEqual([_bus occupiedSlotCount], 0u);
    VibeVoiceID fresh = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    XCTAssertEqual([_bus snapshotOfVoice:fresh].state, VibeVoiceStateArmed);
    dispatch_semaphore_signal(between);
    dispatch_sync(decoder, ^{});
    XCTAssertNotEqual([_bus snapshotOfVoice:fresh].state, VibeVoiceStateNone,
                      @"The second recycle must not erase the new allocation");
    XCTAssertEqual([_bus occupiedSlotCount], 1u);
}

// A live voice whose stream ended takes a late successor through the reopen,
// on a real decode queue held inside the successor's preparation: the window
// after the decoder's claim and before its boundary. `ending` renders the
// voice to its end inside that window.
- (void)holdASuccessorPreparationWhileTheVoiceEnds:(BOOL)ending {
    self.continueAfterFailure = YES;
    NSURL *first = [self writePCM:[self noiseFrames:2000 channels:2 seed:81] rate:kRate channels:2 name:@"first.wav"];
    NSURL *second = [self writePCM:[self noiseFrames:10000 channels:2 seed:82] rate:kRate channels:2 name:@"second.wav"];
    [self makeBusAtRate:kRate channels:2 inlineDecoding:NO];
    VibeVoiceID voice = [self startFile:[self open:first] gain:1 ramp:[self unity] paused:NO];
    dispatch_sync(_bus.decodeQueue, ^{});
    XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, 2000u);
    AVAudioFile *successor = [self open:second];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    Method method = class_getInstanceMethod(AudioVoiceBus.class, @selector(prepareRecord:file:decodeFormat:));
    __block IMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^BOOL(id bus, id record, AVAudioFile *file, AVAudioFormat *format) {
        if (file == successor) {
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        }
        return ((BOOL (*)(id, SEL, id, AVAudioFile *, AVAudioFormat *))original)(bus, @selector(prepareRecord:file:decodeFormat:),
                                                                                  record, file, format);
    });
    original = method_setImplementation(method, replacement);
    @try {
        XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        if (ending) {
            [self renderWithoutFilling:2000 into:nil];
            XCTAssertEqual([_bus snapshotOfVoice:voice].state, VibeVoiceStateDead);
        }
        else {
            XCTAssertFalse([_bus unqueueSuccessorForVoice:voice], @"the claim commits the voice before its boundary is published");
        }
    }
    @finally {
        dispatch_semaphore_signal(release);
        dispatch_sync(_bus.decodeQueue, ^{});
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
    [self drain];
    if (ending) {
        XCTAssertEqualObjects([self eventsForVoice:voice], (@[@(VibeVoiceEventLive), @(VibeVoiceEventEnded)]),
                              @"a successor that rendered no frame must not be promoted, then at once finished");
        XCTAssertEqual([self endedSnapshot:voice].endOfStream, 2000u);
        XCTAssertEqual([self endedSnapshot:voice].boundary, UINT64_MAX);
    }
    else {
        XCTAssertEqual([_bus snapshotOfVoice:voice].boundary, 2000u);
    }
}

- (void)testAnUnqueueAgainstTheDecodersClaimReportsTheSwitch {
    [self holdASuccessorPreparationWhileTheVoiceEnds:NO];
}

- (void)testAVoiceThatReachedItsEndDuringTheReopenEndsWithoutABoundary {
    [self holdASuccessorPreparationWhileTheVoiceEnds:YES];
}

// A continuous signal split across two files at another rate: the resampler
// carries across the boundary, so the output matches the unsplit file's,
// whether the successor is named while the first file is decoding or after
// it was decoded whole.
- (void)assertASplitAtAnotherRateContinuesWithALateSuccessor:(BOOL)late {
    NSData *whole = [self noiseFrames:44100 channels:2 seed:927];
    NSURL *full = [self writePCM:whole rate:44100 channels:2 name:@"whole441.wav"];
    NSURL *a = [self writePCM:[whole subdataWithRange:NSMakeRange(0, 22050 * 8)] rate:44100 channels:2 name:@"first441.wav"];
    NSURL *b = [self writePCM:[whole subdataWithRange:NSMakeRange(22050 * 8, 22050 * 8)] rate:44100 channels:2 name:@"second441.wav"];
    [self makeBusAtRate:48000 channels:2];
    VibeVoiceID voice = [self startFile:[self open:full] gain:1 ramp:[self unity] paused:NO];
    NSData *reference = [self renderUntilEnded:voice blockSize:256 limit:200000];
    [self makeBusAtRate:48000 channels:2];
    voice = [self startFile:[self open:a] gain:1 ramp:[self unity] paused:NO];
    if (late) {
        // The whole file is decoded, and the stream is still open for a successor.
        [_bus fillInline];
        XCTAssertEqualWithAccuracy((double)[_bus snapshotOfVoice:voice].written, 24000, 64);
        XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, UINT64_MAX);
    }
    AVAudioFile *next = [self open:b];
    XCTAssertTrue([_bus queueSuccessor:next decodeFormat:next.processingFormat forVoice:voice]);
    NSData *capture = [self renderUntilEnded:voice blockSize:256 limit:200000];
    XCTAssertEqualWithAccuracy((double)[self endedSnapshot:voice].boundary, 24000, 64);
    XCTAssertEqualWithAccuracy((double)[self endedSnapshot:voice].endOfStream, 48000, 2);
    XCTAssertGreaterThanOrEqual(capture.length, 48000u * 8);
    const float *expected = reference.bytes, *actual = capture.bytes;
    double peak = 0;
    NSUInteger peakFrame = 0;
    for (NSUInteger i = 0; i < 48000 * 2; i++) {
        double error = fabs(actual[i] - expected[i]);
        if (error > peak) { peak = error; peakFrame = i / 2; }
    }
    XCTAssertLessThan(peak, 0.0001, @"the resampler restarted: error at frame %lu, late %d", (unsigned long)peakFrame, late);
}

- (void)testTheResamplerContinuesAcrossAGaplessBoundary {
    [self assertASplitAtAnotherRateContinuesWithALateSuccessor:NO];
}

- (void)testTheResamplerContinuesIntoASuccessorNamedAfterTheFileWasDecoded {
    [self assertASplitAtAnotherRateContinuesWithALateSuccessor:YES];
}

// With no successor named, a converter's stream stays open past its file
// while the render is far from the end, and is ended — the tail flushed,
// the end declared — once the render is within two chunks of it.
- (void)testAConverterStaysOpenPastItsFileUntilTheRenderNears {
    NSURL *url = [self writePCM:[self noiseFrames:22050 channels:2 seed:928] rate:44100 channels:2 name:@"short441.wav"];
    [self makeBusAtRate:48000 channels:2];
    VibeVoiceID voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    [_bus fillInline];
    XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, UINT64_MAX);
    for (NSUInteger rendered = 0; rendered < 15000; rendered += 1000) {
        [self render:1000 into:nil]; // about 9000 frames left buffered: still open
    }
    XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, UINT64_MAX);
    [self render:1024 into:nil];     // under two chunks: the next fill ends it
    [_bus fillInline];
    XCTAssertEqualWithAccuracy((double)[_bus snapshotOfVoice:voice].endOfStream, 24000, 2);
    [self renderUntilEnded:voice blockSize:1024 limit:100000];
    XCTAssertEqualWithAccuracy((double)[self endedSnapshot:voice].endOfStream, 24000, 2);
}

// A successor in another format takes a converter of its own after the first
// one's tail, and the boundary is exact either way round: a resampled file
// into one read direct, and a direct one into a resampled one.
- (void)testASuccessorInAnotherFormatGetsItsOwnConverter {
    NSData *direct = [self noiseFrames:12000 channels:2 seed:91];
    NSURL *directURL = [self writePCM:direct rate:kRate channels:2 name:@"direct.wav"];
    NSURL *resampledURL = [self writePCM:[self constant:0.25 frames:11025 channels:2] rate:44100 channels:2 name:@"resampled.wav"];
    // Resampled, then direct: the direct frames begin exactly at the boundary.
    [self makeBusAtRate:kRate channels:2];
    AVAudioFile *successor = [self open:directURL];
    VibeVoiceID voice = [self startFile:[self open:resampledURL] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:200000];
    VibeVoiceSnapshot snapshot = [self endedSnapshot:voice];
    XCTAssertEqualWithAccuracy((double)snapshot.boundary, 12000, 2);
    XCTAssertEqual(snapshot.endOfStream, snapshot.boundary + 12000);
    XCTAssertEqualObjects([self eventsForVoice:voice],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    const float *out = capture.bytes;
    XCTAssertEqualWithAccuracy(out[(snapshot.boundary - 1000) * 2], 0.25f, 0.001f);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(snapshot.boundary * 8, direct.length)] equalsSource:direct];
    // Direct, then resampled: the resampled frames begin at the boundary.
    [self makeBusAtRate:kRate channels:2];
    successor = [self open:resampledURL];
    voice = [self startFile:[self open:directURL] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:successor decodeFormat:successor.processingFormat forVoice:voice]);
    capture = [self renderUntilEnded:voice blockSize:1024 limit:200000];
    snapshot = [self endedSnapshot:voice];
    XCTAssertEqual(snapshot.boundary, 12000u);
    XCTAssertEqualWithAccuracy((double)snapshot.endOfStream, 24000, 2);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, direct.length)] equalsSource:direct];
    out = capture.bytes;
    XCTAssertEqualWithAccuracy(out[(snapshot.boundary + 1000) * 2], 0.25f, 0.001f);
}

// A rebuilt source segment hands the current file to a new bus while the old
// bus's decoder may be inside a read of it. stopReading returns once that
// read is over and no later turn reads, so the file's position is the new
// voice's alone; without it the two decoders shared the position and the
// new voice ended early.
- (void)testAReplacedBusStopsReadingBeforeItsFileIsReused {
    NSURL *url = [self writePCM:[self noiseFrames:96000 channels:2 seed:83] rate:kRate channels:2 name:@"rebuild.wav"];
    AVAudioFile *file = [self open:url];
    [self makeBusAtRate:kRate channels:2];
    AudioVoiceBus *old = [[AudioVoiceBus alloc] initWithFormat:_bus.format queue:_queue inlineDecoding:NO];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    Method method = class_getInstanceMethod(AudioVoiceBus.class, @selector(produceChunkForSlot:final:));
    __block IMP original = NULL;
    __block BOOL held = NO;
    IMP replacement = imp_implementationWithBlock(^uint32_t(id bus, NSUInteger slot, BOOL *final) {
        if (bus == old && !held) {
            held = YES;
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        }
        return ((uint32_t (*)(id, SEL, NSUInteger, BOOL *))original)(bus, @selector(produceChunkForSlot:final:), slot, final);
    });
    original = method_setImplementation(method, replacement);
    @try {
        [old startVoiceWithFile:file atFrame:0 decodeFormat:file.processingFormat gain:1 ramp:[self unity] paused:NO];
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        // The rebuild: the old bus is told to stop while its decoder is inside
        // the first read, which finishes a moment later.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            dispatch_semaphore_signal(release);
        });
        [old stopReading];
        XCTAssertEqual(file.framePosition, 4096); // the read that was in flight, and no more
    }
    @finally {
        dispatch_semaphore_signal(release);
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
    VibeVoiceID current = [self startFile:file gain:1 ramp:[self unity] paused:NO];
    [self renderUntilEnded:current blockSize:256 limit:300000];
    XCTAssertEqual([self endedSnapshot:current].endOfStream, 96000u);
    XCTAssertEqual(file.framePosition, 96000);
}

// The standard fold of 5.1 to stereo, as the mixer applies it: the center and
// each surround at -3 dB into their side, the LFE dropped — through the
// resampler, since the file is at another rate.
- (void)testAWiderFileMixesDownByLayout {
    const float level[6] = { 0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f };
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100 interleaved:NO
            channelLayout:[AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_MPEG_5_1_A]];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:16384];
    buffer.frameLength = 16384;
    for (NSUInteger c = 0; c < 6; c++) {
        for (NSUInteger f = 0; f < 16384; f++) {
            buffer.floatChannelData[c][f] = level[c];
        }
    }
    NSURL *url = [self writeBuffer:buffer name:@"surround.wav"];
    [self makeBusAtRate:kRate channels:2];
    [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    NSMutableData *capture = [NSMutableData data];
    [self render:4096 into:capture];
    const float *out = capture.bytes;
    float left = level[0] + 0.707f * level[2] + 0.707f * level[4];
    float right = level[1] + 0.707f * level[2] + 0.707f * level[5];
    for (NSUInteger f = 256; f < 4096; f++) {
        XCTAssertEqualWithAccuracy(out[f * 2], left, 0.001f, @"frame %lu left", (unsigned long)f);
        XCTAssertEqualWithAccuracy(out[f * 2 + 1], right, 0.001f, @"frame %lu right", (unsigned long)f);
    }
}

// The same width in another order is a permutation into the bus's order —
// exact, as a bit-perfect delivery must be: a 5.1 file laid out
// L R Ls Rs C LFE into a bus laid out L R C LFE Ls Rs.
- (void)testAFileInAnotherChannelOrderIsRemappedIntoTheBus {
    const float level[6] = { 0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f };
    AVAudioFormat *fileFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:kRate interleaved:NO
            channelLayout:[AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_MPEG_5_1_B]];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fileFormat frameCapacity:8192];
    buffer.frameLength = 8192;
    for (NSUInteger c = 0; c < 6; c++) {
        for (NSUInteger f = 0; f < 8192; f++) {
            buffer.floatChannelData[c][f] = level[c];
        }
    }
    NSURL *url = [self writeBuffer:buffer name:@"surround-b.aif"];
    XCTAssertEqual([self open:url].processingFormat.channelLayout.layoutTag, kAudioChannelLayoutTag_MPEG_5_1_B);
    [self makeBusWithFormat:[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:kRate interleaved:NO
            channelLayout:[AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_MPEG_5_1_A]] inlineDecoding:YES];
    [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    NSMutableData *capture = [NSMutableData data];
    [self render:4096 into:capture];
    const float *out = capture.bytes;
    const float expected[6] = { level[0], level[1], level[4], level[5], level[2], level[3] }; // L R C LFE Ls Rs
    for (NSUInteger f = 0; f < 4096; f++) {
        for (NSUInteger c = 0; c < 6; c++) {
            XCTAssertEqual(out[f * 6 + c], expected[c], @"frame %lu channel %lu", (unsigned long)f, (unsigned long)c);
        }
    }
}

// A decode turn queued for a voice can run after that voice died, its slot
// was recycled, and another voice began binding it — before the new
// generation is published. It must touch nothing: a turn that entered the
// half-bound slot read the recycled record's nil file and declared an end,
// and the new voice died at its first render.
- (void)testAStaleDecodeTurnCannotEnterARebindingSlot {
    self.continueAfterFailure = YES;
    NSURL *url = [self writePCM:[self noiseFrames:96000 channels:2 seed:1201] rate:kRate channels:2 name:@"rebind.wav"];
    AVAudioFile *oldFile = [self open:url], *newFile = [self open:url];
    [self makeBusAtRate:kRate channels:2 inlineDecoding:NO];
    AudioVoiceBus *bus = _bus;
    dispatch_queue_t decoder = bus.decodeQueue;
    dispatch_semaphore_t reading = dispatch_semaphore_create(0), letRead = dispatch_semaphore_create(0);
    dispatch_semaphore_t recycled = dispatch_semaphore_create(0), letRecycle = dispatch_semaphore_create(0);
    dispatch_semaphore_t preparing = dispatch_semaphore_create(0), letPrepare = dispatch_semaphore_create(0);
    Method produce = class_getInstanceMethod(AudioVoiceBus.class, @selector(produceChunkForSlot:final:));
    Method recycle = class_getInstanceMethod(AudioVoiceBus.class, @selector(recycleSlot:generation:));
    Method prepare = class_getInstanceMethod(AudioVoiceBus.class, @selector(prepareRecord:file:decodeFormat:));
    __block IMP originalProduce, originalRecycle, originalPrepare;
    __block BOOL heldRead = NO, heldRecycle = NO;
    // The old voice's first read is held; its recycle is held after it ran;
    // the new voice's preparation is held, with the slot armed and the old
    // generation still published.
    IMP replacementProduce = imp_implementationWithBlock(^uint32_t(id receiver, NSUInteger slot, BOOL *final) {
        if (receiver == bus && !heldRead) {
            heldRead = YES;
            dispatch_semaphore_signal(reading);
            dispatch_semaphore_wait(letRead, DISPATCH_TIME_FOREVER);
        }
        return ((uint32_t (*)(id, SEL, NSUInteger, BOOL *))originalProduce)(receiver, @selector(produceChunkForSlot:final:), slot, final);
    });
    IMP replacementRecycle = imp_implementationWithBlock(^(id receiver, NSUInteger slot, VibeVoiceID generation) {
        ((void (*)(id, SEL, NSUInteger, VibeVoiceID))originalRecycle)(receiver, @selector(recycleSlot:generation:), slot, generation);
        if (receiver == bus && !heldRecycle) {
            heldRecycle = YES;
            dispatch_semaphore_signal(recycled);
            dispatch_semaphore_wait(letRecycle, DISPATCH_TIME_FOREVER);
        }
    });
    IMP replacementPrepare = imp_implementationWithBlock(^BOOL(id receiver, id record, AVAudioFile *file, AVAudioFormat *format) {
        if (receiver == bus && file == newFile) {
            dispatch_semaphore_signal(preparing);
            dispatch_semaphore_wait(letPrepare, DISPATCH_TIME_FOREVER);
        }
        return ((BOOL (*)(id, SEL, id, AVAudioFile *, AVAudioFormat *))originalPrepare)(receiver, @selector(prepareRecord:file:decodeFormat:), record, file, format);
    });
    originalProduce = method_setImplementation(produce, replacementProduce);
    originalRecycle = method_setImplementation(recycle, replacementRecycle);
    originalPrepare = method_setImplementation(prepare, replacementPrepare);
    __block VibeVoiceID current = 0;
    @try {
        VibeVoiceID old = [self startFile:oldFile gain:1 ramp:[self unity] paused:NO];
        XCTAssertEqual(dispatch_semaphore_wait(reading, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        [bus killVoice:old];
        [bus drainWithOutputRunning:NO handler:^(VibeVoiceID voice, VibeVoiceEvent event) {}];
        dispatch_semaphore_signal(letRead); // the read finishes and re-dispatches a turn behind the recycle
        XCTAssertEqual(dispatch_semaphore_wait(recycled, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        dispatch_async(_queue, ^{ current = [self startFile:newFile gain:1 ramp:[self unity] paused:NO]; });
        XCTAssertEqual(dispatch_semaphore_wait(preparing, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        dispatch_semaphore_signal(letRecycle); // the old voice's turn runs against the half-bound slot
        dispatch_sync(decoder, ^{});
        dispatch_semaphore_signal(letPrepare);
        dispatch_sync(_queue, ^{});
        for (int turn = 0; turn < 12; turn++) dispatch_sync(decoder, ^{});
        XCTAssertEqual([bus snapshotOfVoice:current].endOfStream, UINT64_MAX, @"a stale turn wrote an end into the new voice");
        [self renderWithoutFilling:256 into:nil];
        XCTAssertEqual([bus snapshotOfVoice:current].state, VibeVoiceStateLive, @"the new voice ended after its first render");
    }
    @finally {
        dispatch_semaphore_signal(letRead);
        dispatch_semaphore_signal(letRecycle);
        dispatch_semaphore_signal(letPrepare);
        dispatch_sync(_queue, ^{});
        [bus stopReading];
        method_setImplementation(produce, originalProduce);
        method_setImplementation(recycle, originalRecycle);
        method_setImplementation(prepare, originalPrepare);
        imp_removeBlock(replacementProduce);
        imp_removeBlock(replacementRecycle);
        imp_removeBlock(replacementPrepare);
    }
}

#pragma mark - Conversion

// The resampler across a gapless boundary at every rate pair the player
// meets, the successor named early or late, at every pull size: the split's
// output is the unsplit file's, frame for frame, and ends where it ends.
- (void)testTheResamplerContinuesAtEveryRatePairAndPullSize {
    NSArray<NSArray<NSNumber *> *> *pairs = @[@[@44100, @48000], @[@96000, @44100], @[@192000, @48000], @[@32000, @44100], @[@48000, @192000]];
    for (NSArray<NSNumber *> *pair in pairs) {
        double sourceRate = pair[0].doubleValue, busRate = pair[1].doubleValue;
        NSUInteger count = (NSUInteger)sourceRate, split = count / 2 + 7;
        NSData *whole = [self noiseFrames:count channels:2 seed:1129];
        NSURL *full = [self writePCM:whole rate:sourceRate channels:2 name:@"full.wav"];
        NSURL *a = [self writePCM:[whole subdataWithRange:NSMakeRange(0, split * 8)] rate:sourceRate channels:2 name:@"a.wav"];
        NSURL *b = [self writePCM:[whole subdataWithRange:NSMakeRange(split * 8, (count - split) * 8)] rate:sourceRate channels:2 name:@"b.wav"];
        [self makeBusAtRate:busRate channels:2];
        VibeVoiceID voice = [self startFile:[self open:full] gain:1 ramp:[self unity] paused:NO];
        NSData *reference = [self renderUntilEnded:voice blockSize:256 limit:500000];
        uint64_t end = [self endedSnapshot:voice].endOfStream;
        for (NSNumber *late in @[@NO, @YES]) {
            for (NSNumber *block in @[@63, @1024, @4096]) {
                [self makeBusAtRate:busRate channels:2];
                voice = [self startFile:[self open:a] gain:1 ramp:[self unity] paused:NO];
                if (late.boolValue) {
                    [_bus fillInline];
                }
                AVAudioFile *next = [self open:b];
                XCTAssertTrue([_bus queueSuccessor:next decodeFormat:next.processingFormat forVoice:voice]);
                NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:500000];
                XCTAssertEqual([self endedSnapshot:voice].endOfStream, end, @"%@ late %@ block %@", pair, late, block);
                XCTAssertGreaterThanOrEqual(capture.length, end * 8);
                double peak = 0;
                const float *expected = reference.bytes, *actual = capture.bytes;
                for (NSUInteger i = 0; i < end * 2; i++) {
                    peak = MAX(peak, fabs(actual[i] - expected[i]));
                }
                XCTAssertLessThan(peak, 0.0001, @"%@ late %@ block %@", pair, late, block);
            }
        }
    }
}

static double ToneAmplitude(const float *interleaved, NSUInteger channels, NSUInteger channel, double rate, double frequency, NSRange frames) {
    double re = 0, im = 0;
    for (NSUInteger f = frames.location; f < NSMaxRange(frames); f++) {
        double phase = 2 * M_PI * frequency * f / rate;
        re += interleaved[f * channels + channel] * cos(phase);
        im += interleaved[f * channels + channel] * sin(phase);
    }
    return 2 * hypot(re, im) / frames.length;
}

- (void)testAFileAtAnotherRateArrivesAtFlatGainAndExactDuration {
    const NSUInteger frames = 48000;
    NSMutableData *tone = [NSMutableData dataWithLength:frames * 2 * sizeof(float)];
    float *t = tone.mutableBytes;
    for (NSUInteger f = 0; f < frames; f++) {
        t[f * 2] = t[f * 2 + 1] = 0.25f * sinf((float)(2 * M_PI * 1000 * f / 48000));
    }
    NSURL *url = [self writePCM:tone rate:48000 channels:2 name:@"tone48.wav"];
    [self makeBusAtRate:44100 channels:2];
    VibeVoiceID voice = [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:400000];
    XCTAssertEqualWithAccuracy((double)[self endedSnapshot:voice].endOfStream, 44100, 2);
    double amplitude = ToneAmplitude(capture.bytes, 2, 0, 44100, 1000, NSMakeRange(11025, 22050));
    XCTAssertLessThan(fabs(20 * log10(amplitude / 0.25)), 0.01);
}

- (void)testAMonoFileIsDuplicatedIntoBothChannels {
    NSData *source = [self noiseFrames:8192 channels:1 seed:12];
    NSURL *url = [self writePCM:source rate:kRate channels:1 name:@"mono.wav"];
    [self makeBusAtRate:kRate channels:2];
    [self startFile:[self open:url] gain:1 ramp:[self unity] paused:NO];
    NSMutableData *capture = [NSMutableData data];
    [self render:4096 into:capture];
    const float *out = capture.bytes, *in = source.bytes;
    for (NSUInteger f = 0; f < 4096; f++) {
        XCTAssertEqual(out[f * 2], in[f], @"frame %lu left", (unsigned long)f);
        XCTAssertEqual(out[f * 2 + 1], in[f], @"frame %lu right", (unsigned long)f);
    }
}

- (void)testTheSixteenBitDecodeFormatRoundsOntoTheGrid {
    NSMutableData *source = [NSMutableData dataWithLength:4096 * 2 * sizeof(float)];
    float *p = source.mutableBytes;
    for (NSUInteger i = 0; i < 4096 * 2; i++) {
        p[i] = 0.1234567f + 0.0000731f * (float)(i % 17); // nothing on the 16-bit grid
    }
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"grid.wav"];
    [self makeBusAtRate:kRate channels:2];
    AVAudioFile *file = [self open:url];
    AVAudioFormat *integer = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:kRate channels:2 interleaved:YES];
    [_bus startVoiceWithFile:file atFrame:0 decodeFormat:integer gain:1 ramp:[self unity] paused:NO];
    NSMutableData *capture = [NSMutableData data];
    [self render:2048 into:capture];
    const float *out = capture.bytes;
    for (NSUInteger i = 0; i < 2048 * 2; i++) {
        float scaled = out[i] * 32768.0f;
        XCTAssertEqual(scaled, rintf(scaled), @"sample %lu off the grid", (unsigned long)i);
        XCTAssertEqualWithAccuracy(out[i], p[i], 1.0f / 32768.0f, @"sample %lu", (unsigned long)i);
    }
}

@end
