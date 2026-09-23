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
    NSMutableDictionary *settings = [format.settings mutableCopy];
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
    [self releaseOutput];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:(AVAudioChannelCount)channels];
    _bus = [[AudioVoiceBus alloc] initWithFormat:format queue:_queue inlineDecoding:YES];
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
    OSStatus status = _bus.renderBlock(&silence, &stamp, frames, _output);
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
    [_bus drainWithEngineRunning:YES handler:^(VibeVoiceID voice, VibeVoiceEvent event) {
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
    [_bus drainWithEngineRunning:NO handler:^(VibeVoiceID v, VibeVoiceEvent e) {}];
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

#pragma mark - Conversion

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
