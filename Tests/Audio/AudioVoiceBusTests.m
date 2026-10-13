//
//  AudioVoiceBusTests.m
//  VibeTests
//
//  The voice bus with no pipeline: the tests own the output buffers and call
//  VibeVoiceBusRender themselves, so every frame is compared against the file
//  it came from. Inline decoding fills before each render on this thread.
//

#import "AudioVoiceBusTestCase.h"

@interface AudioVoiceBusTests : AudioVoiceBusTestCase
@end

@implementation AudioVoiceBusTests

#pragma mark - Passthrough and ends

// The gain and the stamps are the render's to write, so a snapshot reads them
// through atomics and a seqlock; ThreadSanitizer reports a plain read here.
- (void)testSnapshotsWhileARenderRuns {
    [self makeBusAtRate:kRate channels:2];
    AudioFileHandle *file = [self open:[self writePCM:[self noiseFrames:64000 channels:2 seed:17]
                                             rate:kRate channels:2 name:@"concurrent.wav"]];
    VibeVoiceID voice = [self startFile:file gain:0
                                   ramp:VibeVoiceRampMake(1, 48000, VibeFadeCurveLinear, VibeVoiceActionNone)
                                 paused:NO];
    [_bus fillInline];
    dispatch_group_t renders = dispatch_group_create();
    dispatch_group_async(renders, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        for (NSUInteger i = 0; i < 1000; i++) {
            [self renderWithoutFilling:32 into:nil];
        }
    });
    for (NSUInteger i = 0; i < 10000; i++) {
        VibeVoiceSnapshot snapshot = [_bus snapshotOfVoice:voice];
        XCTAssertTrue(snapshot.gain >= 0 && snapshot.gain <= 1);
    }
    dispatch_group_wait(renders, DISPATCH_TIME_FOREVER);
}

// The origins a snapshot subtracts are the bind's to write, so they are
// atomics, and the generation is the seqlock's version around the bind;
// ThreadSanitizer reports plain fields here.
- (void)testSnapshotsWhileSlotsAreReused {
    [self makeBusAtRate:kRate channels:2];
    AudioFileHandle *file = [self open:[self writePCM:[self noiseFrames:4096 channels:2 seed:71]
                                             rate:kRate channels:2 name:@"reuse-snapshot.wav"]];
    _Atomic uint64_t *current = calloc(1, sizeof(_Atomic uint64_t));
    _Atomic int *done = calloc(1, sizeof(_Atomic int));
    dispatch_group_t readers = dispatch_group_create();
    for (int reader = 0; reader < 2; reader++) {
        dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            while (!atomic_load_explicit(done, memory_order_relaxed)) {
                VibeVoiceID voice = atomic_load_explicit(current, memory_order_acquire);
                if (voice) {
                    VibeVoiceSnapshot snapshot = [self->_bus snapshotOfVoice:voice];
                    XCTAssertTrue(snapshot.state == VibeVoiceStateNone || snapshot.written <= 4096,
                                  @"a snapshot mixed two voices: state %d, written %llu", (int)snapshot.state, snapshot.written);
                }
            }
        });
    }
    for (NSUInteger iteration = 0; iteration < 3000; iteration++) {
        VibeVoiceID voice = [self startFile:file gain:1 ramp:[self unity] paused:YES];
        atomic_store_explicit(current, voice, memory_order_release);
        [_bus killVoice:voice];
        [_bus drainWithOutputRunning:NO handler:^(VibeVoiceID identifier, VibeVoiceEvent event) {}];
    }
    atomic_store_explicit(done, 1, memory_order_relaxed);
    dispatch_group_wait(readers, DISPATCH_TIME_FOREVER);
    free(current);
    free(done);
}

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
    AudioFileHandle *file = [self open:url];
    VibeVoiceID voice = [_bus startVoiceWithFile:file atFrame:12345 endFrame:0 gain:1
                                            ramp:[self unity] paused:NO];
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:100000];
    NSData *tail = [source subdataWithRange:NSMakeRange(12345 * 8, source.length - 12345 * 8)];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, tail.length)] equalsSource:tail];
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 20000u - 12345u);
}

#pragma mark - Windows

- (void)testAnEndFrameEndsTheStreamThere {
    NSData *source = [self noiseFrames:20000 channels:2 seed:131];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"window.wav"];
    for (NSNumber *block in @[@63, @1024, @4096]) {
        [self makeBusAtRate:kRate channels:2];
        VibeVoiceID voice = [_bus startVoiceWithFile:[self open:url] atFrame:3000 endFrame:11000 gain:1
                                                ramp:[self unity] paused:NO];
        NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:100000];
        [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 8000 * 8)]
               equalsSource:[source subdataWithRange:NSMakeRange(3000 * 8, 8000 * 8)]];
        [self assertSilent:capture from:8000 * 2];
        XCTAssertEqual([self endedSnapshot:voice].endOfStream, 8000u, @"block %@", block);
        XCTAssertEqual([self endedSnapshot:voice].ended, VibeVoiceEndOfStream);
    }
}

// An end frame past where the stream really ends is that end: the bus reads
// to the file's end and stops, as for 0, never consulting the length, which
// a lossy or streaming file only estimates.
- (void)testAnEndFramePastTheStreamsEndReadsToItsEnd {
    NSData *source = [self noiseFrames:20000 channels:2 seed:137];
    NSURL *url = [self writePCM:source rate:kRate channels:2 name:@"short-of-its-end.wav"];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID voice = [_bus startVoiceWithFile:[self open:url] atFrame:3000 endFrame:30000 gain:1
                                            ramp:[self unity] paused:NO];
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:100000];
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 17000u);
    XCTAssertEqual([self endedSnapshot:voice].ended, VibeVoiceEndOfStream);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 17000 * 8)]
           equalsSource:[source subdataWithRange:NSMakeRange(3000 * 8, 17000 * 8)]];
}

- (void)testWindowsOfOneFileContinueExactlyAtEveryBlockSize {
    NSData *whole = [self noiseFrames:48001 channels:2 seed:132];
    NSURL *url = [self writePCM:whole rate:kRate channels:2 name:@"image.wav"];
    for (NSNumber *block in @[@63, @256, @1024, @4096]) {
        [self makeBusAtRate:kRate channels:2];
        AudioFileHandle *successor = [self open:url];
        VibeVoiceID voice = [_bus startVoiceWithFile:[self open:url] atFrame:0 endFrame:20003 gain:1
                                                ramp:[self unity] paused:NO];
        XCTAssertTrue([_bus queueSuccessor:successor startFrame:20003 endFrame:0 forVoice:voice]);
        NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:200000];
        [self assertCapture:[capture subdataWithRange:NSMakeRange(0, whole.length)] equalsSource:whole];
        XCTAssertEqual([self endedSnapshot:voice].boundary, 20003u, @"block %@", block);
        XCTAssertEqual([self endedSnapshot:voice].endOfStream, 48001u, @"block %@", block);
    }
}

- (void)testThreeChainedWindowsOfOneFileReportEachBoundary {
    NSData *whole = [self noiseFrames:9000 channels:2 seed:133];
    NSURL *url = [self writePCM:whole rate:kRate channels:2 name:@"chained.wav"];
    [self makeBusAtRate:kRate channels:2];
    AudioFileHandle *second = [self open:url], *third = [self open:url];
    VibeVoiceID voice = [_bus startVoiceWithFile:[self open:url] atFrame:0 endFrame:2000 gain:1
                                            ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:second startFrame:2000 endFrame:5000 forVoice:voice]);
    NSMutableData *capture = [NSMutableData data];
    while ([self eventsForVoice:voice].count < 2 && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertTrue([_bus queueSuccessor:third startFrame:5000 endFrame:0 forVoice:voice]);
    while (![self hasEnded:voice] && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqualObjects([self eventsForVoice:voice],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    XCTAssertEqual([self endedSnapshot:voice].boundary, 5000u);
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 9000u);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 9000 * 8)] equalsSource:whole];
}

- (void)testAReopenedStreamReadsItsSuccessorsWindow {
    NSData *first = [self noiseFrames:2000 channels:2 seed:134];
    NSData *second = [self noiseFrames:30000 channels:2 seed:135];
    NSURL *a = [self writePCM:first rate:kRate channels:2 name:@"reopen-a.wav"];
    NSURL *b = [self writePCM:second rate:kRate channels:2 name:@"reopen-b.wav"];
    [self makeBusAtRate:kRate channels:2];
    AudioFileHandle *successor = [self open:b];
    VibeVoiceID voice = [self startFile:[self open:a] gain:1 ramp:[self unity] paused:NO];
    [_bus fillInline];
    XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, 2000u);
    XCTAssertTrue([_bus queueSuccessor:successor startFrame:10000 endFrame:14000 forVoice:voice]);
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:200000];
    NSMutableData *expected = [first mutableCopy];
    [expected appendData:[second subdataWithRange:NSMakeRange(10000 * 8, 4000 * 8)]];
    XCTAssertEqual([self endedSnapshot:voice].boundary, 2000u);
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 6000u);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, expected.length)] equalsSource:expected];
}

- (void)testAPendingStartKeepsItsWindowAndItsSuccessorsThroughTheBind {
    NSURL *fillerURL = [self writePCM:[self noiseFrames:20000 channels:2 seed:136] rate:kRate channels:2 name:@"filler.wav"];
    NSData *whole = [self noiseFrames:12000 channels:2 seed:137];
    NSURL *url = [self writePCM:whole rate:kRate channels:2 name:@"pending-image.wav"];
    [self makeBusAtRate:kRate channels:2];
    NSMutableArray<NSNumber *> *voices = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {
        [voices addObject:@([self startFile:[self open:fillerURL] gain:1 ramp:[self unity] paused:YES])];
    }
    [self render:64 into:nil];
    AudioFileHandle *successor = [self open:url];
    VibeVoiceID pending = [_bus startVoiceWithFile:[self open:url] atFrame:1000 endFrame:3000 gain:1
                                              ramp:[self unity] paused:NO];
    XCTAssertEqual([_bus pendingVoiceCount], 1u);
    XCTAssertTrue([_bus queueSuccessor:successor startFrame:3000 endFrame:7000 forVoice:pending]);
    [_bus killVoice:voices[0].unsignedLongLongValue];
    [self render:64 into:nil];
    XCTAssertEqual([_bus pendingVoiceCount], 0u);
    NSMutableData *capture = [NSMutableData data];
    while (![self hasEnded:pending] && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqual([self endedSnapshot:pending].boundary, 2000u);
    XCTAssertEqual([self endedSnapshot:pending].endOfStream, 6000u);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 6000 * 8)]
           equalsSource:[whole subdataWithRange:NSMakeRange(1000 * 8, 6000 * 8)]];
}

// Through the resampler, contiguous windows of one file match the reference
// conversion of the whole file, the successor named early or late: the
// converter's filter carries across as it does across two files.
- (void)testWindowsOfOneFileContinueThroughTheResampler {
    NSUInteger count = 44100, split = 22057;
    NSData *whole = [self noiseFrames:count channels:2 seed:138];
    NSURL *url = [self writePCM:whole rate:44100 channels:2 name:@"image441.wav"];
    NSData *reference = [self referenceConversionOfURL:url toRate:48000];
    uint64_t end = reference.length / (2 * sizeof(float));
    const float *expected = reference.bytes;
    for (NSNumber *late in @[@NO, @YES]) {
        for (NSNumber *block in @[@63, @1024, @4096]) {
            [self makeBusAtRate:48000 channels:2];
            VibeVoiceID voice = [_bus startVoiceWithFile:[self open:url] atFrame:0 endFrame:(AVAudioFramePosition)split
                                                    gain:1 ramp:[self unity] paused:NO];
            if (late.boolValue) {
                [_bus fillInline];
            }
            XCTAssertTrue([_bus queueSuccessor:[self open:url] startFrame:(AVAudioFramePosition)split endFrame:0
                                      forVoice:voice]);
            NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:500000];
            XCTAssertEqual([self endedSnapshot:voice].endOfStream, end, @"late %@ block %@", late, block);
            XCTAssertGreaterThanOrEqual(capture.length, end * 8);
            double peak = 0;
            const float *joined = capture.bytes;
            for (NSUInteger i = 0; i < end * 2; i++) {
                peak = MAX(peak, fabs(joined[i] - expected[i]));
            }
            XCTAssertLessThan(peak, 0.0001, @"late %@ block %@", late, block);
        }
    }
}

- (void)testAResampledWindowIsTheConversionOfItsExcerpt {
    NSData *whole = [self noiseFrames:44100 channels:2 seed:139];
    NSURL *url = [self writePCM:whole rate:44100 channels:2 name:@"whole441.wav"];
    NSURL *excerpt = [self writePCM:[whole subdataWithRange:NSMakeRange(12345 * 8, 20000 * 8)] rate:44100
                           channels:2 name:@"excerpt441.wav"];
    NSData *reference = [self referenceConversionOfURL:excerpt toRate:48000];
    [self makeBusAtRate:48000 channels:2];
    VibeVoiceID voice = [_bus startVoiceWithFile:[self open:url] atFrame:12345 endFrame:32345 gain:1
                                            ramp:[self unity] paused:NO];
    NSData *capture = [self renderUntilEnded:voice blockSize:1024 limit:500000];
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, reference.length / (2 * sizeof(float)));
    XCTAssertTrue(capture.length >= reference.length && memcmp(capture.bytes, reference.bytes, reference.length) == 0);
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
        // The render's ramp is the per-frame curve in ramp form, equal to a
        // rounding; the landing below is exact.
        XCTAssertEqualWithAccuracy(out[f * 2], gain * in[f * 2], 1e-6, @"frame %u", f);
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
        XCTAssertEqualWithAccuracy(out[f * 2], gain * in[(1480 + f) * 2], 1e-6, @"frame %u after resume", f);
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
        AudioFileHandle *successor = [self open:second];
        VibeVoiceID voice = [self startFile:[self open:first] gain:1 ramp:[self unity] paused:NO];
        XCTAssertTrue([_bus queueSuccessor:successor startFrame:0 endFrame:0 forVoice:voice]);
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
    AudioFileHandle *successor = [self open:second];
    VibeVoiceID voice = [self startFile:[self open:first] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:successor startFrame:0 endFrame:0 forVoice:voice]);
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
    AudioFileHandle *successor = [self open:second];
    VibeVoiceID voice = [self startFile:[self open:first] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:successor startFrame:0 endFrame:0 forVoice:voice]);
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
    XCTAssertTrue([_bus queueSuccessor:successor startFrame:0 endFrame:0 forVoice:voice]);
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
    XCTAssertTrue([_bus queueSuccessor:successor startFrame:0 endFrame:0 forVoice:voice]);
    capture = [self renderUntilEnded:voice blockSize:1024 limit:200000];
    XCTAssertEqual([self endedSnapshot:voice].boundary, 2000u);
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 32000u);
    NSMutableData *reopened = [[whole subdataWithRange:NSMakeRange(0, 2000 * 8)] mutableCopy];
    [reopened appendData:[whole subdataWithRange:NSMakeRange(30000 * 8, 30000 * 8)]];
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 32000 * 8)] equalsSource:reopened];
    XCTAssertEqualObjects([self eventsForVoice:voice],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    // A dead voice takes none.
    XCTAssertFalse([_bus queueSuccessor:successor startFrame:0 endFrame:0 forVoice:voice]);
}

// A gapless album is one voice: each successor is queued only after the
// previous boundary was reported, and every boundary is reported by value.
- (void)testOneVoiceChainsSuccessorsAndReportsEachBoundary {
    NSData *whole = [self noiseFrames:9000 channels:2 seed:12];
    NSURL *a = [self writePCM:[whole subdataWithRange:NSMakeRange(0, 2000 * 8)] rate:kRate channels:2 name:@"a.wav"];
    NSURL *b = [self writePCM:[whole subdataWithRange:NSMakeRange(2000 * 8, 3000 * 8)] rate:kRate channels:2 name:@"b.wav"];
    NSURL *c = [self writePCM:[whole subdataWithRange:NSMakeRange(5000 * 8, 4000 * 8)] rate:kRate channels:2 name:@"c.wav"];
    [self makeBusAtRate:kRate channels:2];
    AudioFileHandle *second = [self open:b], *third = [self open:c];
    VibeVoiceID voice = [self startFile:[self open:a] gain:1 ramp:[self unity] paused:NO];
    XCTAssertTrue([_bus queueSuccessor:second startFrame:0 endFrame:0 forVoice:voice]);
    NSMutableData *capture = [NSMutableData data];
    // a and b decode whole before the first render, so b's end is known when
    // the first boundary is reported; queuing c then reopens the stream.
    while ([self eventsForVoice:voice].count < 2 && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqualObjects([self eventsForVoice:voice], (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary)]));
    XCTAssertEqual([_bus snapshotOfVoice:voice].boundary, 2000u);
    XCTAssertEqual([_bus snapshotOfVoice:voice].endOfStream, 5000u);
    XCTAssertTrue([_bus queueSuccessor:third startFrame:0 endFrame:0 forVoice:voice]);
    while (![self hasEnded:voice] && capture.length < 20000 * 8) {
        [self render:256 into:capture];
    }
    XCTAssertEqualObjects([self eventsForVoice:voice],
                          (@[@(VibeVoiceEventLive), @(VibeVoiceEventBoundary), @(VibeVoiceEventBoundary), @(VibeVoiceEventEnded)]));
    XCTAssertEqual([self endedSnapshot:voice].boundary, 5000u);
    XCTAssertEqual([self endedSnapshot:voice].endOfStream, 9000u);
    [self assertCapture:[capture subdataWithRange:NSMakeRange(0, 9000 * 8)] equalsSource:whole];
}

#pragma mark - Conversion

// The reference conversion (AudioFixtures.h) of the whole file, read with
// AVAudioFile rather than the bus's AudioFileHandle, interleaved.
- (NSData *)referenceConversionOfURL:(NSURL *)url toRate:(double)rate {
    NSError *error = nil;
    AVAudioPCMBuffer *whole = VibeReadWithAVAudioFile(url, &error);
    XCTAssertNotNil(whole, @"%@", error);
    AVAudioPCMBuffer *converted = VibeReferenceResample(whole, rate);
    XCTAssertNotNil(converted, @"the reference could not convert to %g Hz", rate);
    NSMutableData *reference = [NSMutableData data];
    VibeAppendPCM(reference, converted);
    return reference;
}

// The resampler across a gapless boundary at every rate pair the player
// meets, the successor named early or late, at every pull size: the whole
// file matches the reference conversion, and the split's output matches it
// frame for frame.
- (void)testTheResamplerContinuesAtEveryRatePairAndPullSize {
    NSArray<NSArray<NSNumber *> *> *pairs = @[@[@44100, @48000], @[@96000, @44100], @[@192000, @48000], @[@32000, @44100], @[@48000, @192000],
        @[@22050, @192000], @[@24000, @192000], @[@32000, @192000], @[@44100, @192000]];
    for (NSArray<NSNumber *> *pair in pairs) {
        double sourceRate = pair[0].doubleValue, busRate = pair[1].doubleValue;
        NSUInteger count = (NSUInteger)sourceRate, split = count / 2 + 7;
        NSData *whole = [self noiseFrames:count channels:2 seed:1129];
        NSURL *full = [self writePCM:whole rate:sourceRate channels:2 name:@"full.wav"];
        NSURL *a = [self writePCM:[whole subdataWithRange:NSMakeRange(0, split * 8)] rate:sourceRate channels:2 name:@"a.wav"];
        NSURL *b = [self writePCM:[whole subdataWithRange:NSMakeRange(split * 8, (count - split) * 8)] rate:sourceRate channels:2 name:@"b.wav"];
        NSData *reference = [self referenceConversionOfURL:full toRate:busRate];
        uint64_t end = reference.length / (2 * sizeof(float));
        const float *expected = reference.bytes;
        [self makeBusAtRate:busRate channels:2];
        VibeVoiceID voice = [self startFile:[self open:full] gain:1 ramp:[self unity] paused:NO];
        NSData *clean = [self renderUntilEnded:voice blockSize:256 limit:500000];
        XCTAssertEqual([self endedSnapshot:voice].endOfStream, end, @"%@", pair);
        XCTAssertTrue(clean.length >= reference.length && memcmp(clean.bytes, expected, reference.length) == 0,
                      @"%@ whole file against the reference", pair);
        for (NSNumber *late in @[@NO, @YES]) {
            for (NSNumber *block in @[@63, @1024, @4096]) {
                [self makeBusAtRate:busRate channels:2];
                voice = [self startFile:[self open:a] gain:1 ramp:[self unity] paused:NO];
                if (late.boolValue) {
                    [_bus fillInline];
                }
                AudioFileHandle *next = [self open:b];
                XCTAssertTrue([_bus queueSuccessor:next startFrame:0 endFrame:0 forVoice:voice]);
                NSData *capture = [self renderUntilEnded:voice blockSize:block.unsignedIntValue limit:500000];
                XCTAssertEqual([self endedSnapshot:voice].endOfStream, end, @"%@ late %@ block %@", pair, late, block);
                XCTAssertGreaterThanOrEqual(capture.length, end * 8);
                double peak = 0;
                const float *joined = capture.bytes;
                for (NSUInteger i = 0; i < end * 2; i++) {
                    peak = MAX(peak, fabs(joined[i] - expected[i]));
                }
                XCTAssertLessThan(peak, 0.0001, @"%@ late %@ block %@", pair, late, block);
            }
        }
    }
}

static double VibeToneAmplitude(const float *interleaved, NSUInteger channels, NSUInteger channel, double rate, double frequency, NSRange frames) {
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
    double amplitude = VibeToneAmplitude(capture.bytes, 2, 0, 44100, 1000, NSMakeRange(11025, 22050));
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

- (void)checkReadFailureAtRate:(double)rate afterReads:(NSUInteger)reads partialFrames:(UInt32)partial {
    NSData *source = [self noiseFrames:20000 channels:2 seed:176];
    AudioFileHandle *file = [self open:[self writePCM:source rate:rate channels:2 name:@"read-failure.wav"]];
    [self makeBusAtRate:kRate channels:2];
    Method method = class_getInstanceMethod(AudioFileHandle.class, @selector(readIntoBuffer:frameCount:error:));
    __block IMP original;
    __block NSUInteger calls = 0;
    IMP replacement = imp_implementationWithBlock(^BOOL(AudioFileHandle *receiver, AVAudioPCMBuffer *buffer,
                                                        AVAudioFrameCount count, NSError **error) {
        BOOL fail = receiver == file && calls++ >= reads;
        BOOL success = ((BOOL (*)(id, SEL, id, AVAudioFrameCount, NSError **))original)(receiver,
                @selector(readIntoBuffer:frameCount:error:), buffer, fail ? partial : count, error);
        if (!fail) return success;
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
        return NO;
    });
    original = method_setImplementation(method, replacement);
    @try {
        VibeVoiceID voice = [self startFile:file gain:1 ramp:[self unity] paused:NO];
        NSMutableData *capture = [NSMutableData data];
        for (int i = 0; i < 80 && ![self hasEnded:voice]; i++) [self render:256 into:capture];
        XCTAssertTrue([self hasEnded:voice]);
        VibeVoiceSnapshot snapshot;
        [_endedSnapshots[@(voice)] getValue:&snapshot];
        XCTAssertEqual(snapshot.ended, VibeVoiceEndFailed);
        XCTAssertEqual(_endedErrors[@(voice)].code, EIO);
        XCTAssertEqualObjects(_endedErrors[@(voice)].userInfo[NSURLErrorKey], file.url);
        if (rate == kRate) {
            NSUInteger frames = reads * 4096 + partial;
            XCTAssertEqual(snapshot.consumed, frames);
            XCTAssertGreaterThanOrEqual(capture.length, frames * 2 * sizeof(float));
            XCTAssertEqual(memcmp(capture.bytes, source.bytes, frames * 2 * sizeof(float)), 0);
        }
    }
    @finally {
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}

- (void)testReadFailureBeforeFirstFrameIsNotEOF {
    [self checkReadFailureAtRate:kRate afterReads:0 partialFrames:0];
}
- (void)testReadFailureAfterBufferedOutputIsNotEOF {
    [self checkReadFailureAtRate:kRate afterReads:2 partialFrames:0];
}
- (void)testFailedReadPublishesItsValidPartialBufferExactlyOnce {
    [self checkReadFailureAtRate:kRate afterReads:1 partialFrames:17];
}
- (void)testConverterInputFailureKeepsTheUnderlyingReadError {
    [self checkReadFailureAtRate:44100 afterReads:1 partialFrames:17];
}

- (void)testRefusedSeekSettlesAPausedStartWithoutReading {
    AudioFileHandle *file = [self open:[self writePCM:[self noiseFrames:1000 channels:2 seed:9]
            rate:kRate channels:2 name:@"seek-refused.wav"]];
    [self makeBusAtRate:kRate channels:2];
    VibeVoiceID previous = [self startFile:file gain:1 ramp:[self unity] paused:NO];
    [self render:1024 into:nil];
    XCTAssertTrue([self hasEnded:previous]);
    // Reuse a slot that died in the last render; the failed start needs none.
    [_bus drainWithOutputRunning:NO handler:^(VibeVoiceID voice, VibeVoiceEvent event) {}];
    Method method = class_getInstanceMethod(AudioFileHandle.class, @selector(seekToFrame:error:));
    __block IMP original;
    IMP replacement = imp_implementationWithBlock(^BOOL(AudioFileHandle *receiver, AVAudioFramePosition frame, NSError **error) {
        if (receiver != file) return ((BOOL (*)(id, SEL, AVAudioFramePosition, NSError **))original)(receiver,
                @selector(seekToFrame:error:), frame, error);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ESPIPE userInfo:nil];
        return NO;
    });
    original = method_setImplementation(method, replacement);
    @try {
        VibeVoiceID voice = [_bus startVoiceWithFile:file atFrame:300 endFrame:0 gain:1 ramp:[self unity] paused:YES];
        AVAudioFramePosition position = file.framePosition;
        [_bus fillInline];
        [self drain];
        XCTAssertTrue([self hasEnded:voice]);
        XCTAssertEqual(_endedErrors[@(voice)].code, ESPIPE);
        XCTAssertEqual(file.framePosition, position);
        XCTAssertEqual([_bus slotCountInState:VibeVoiceStateDead], 0u);
    }
    @finally { method_setImplementation(method, original); imp_removeBlock(replacement); }
}

@end
