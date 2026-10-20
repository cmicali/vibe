//
//  AudioFileHandleReadAheadTests.m
//
//  AudioFileHandle reading ahead on a network mount: the mount rule forced
//  for the test's own directory and each read scripted (VibeReadAheadScript).
//  Each decode is compared exactly with the file's direct open, through every
//  stall, failure, interruption and orphaned thread.
//

#include <fcntl.h>
#include <sys/stat.h>

#import "AudioFileHandleStreamingTestCase.h"

@interface AudioFileHandleReadAheadTests : AudioFileHandleStreamingTestCase
@end

@implementation AudioFileHandleReadAheadTests

// An open that can be interrupted, as the coordinator's and the waveform
// loader's are; only such an open reads ahead.
static AudioFileHandle *VibeOpenInterruptibly(NSURL *url, NSError **error) {
    return [[AudioFileHandle alloc] initForReading:url interleaved:NO interrupted:^BOOL { return NO; } error:error];
}

- (NSURL *)noiseWAVNamed:(NSString *)name frames:(uint32_t)frames {
    return VibeWriteWAV([self sourceNamed:name], VibeNoiseSamples(frames, 2), 44100, 2, 16, frames * 4);
}

// 16 s at 192 kHz, 12.3 MB in blocks 0 to 46. The 8 MB floor ahead of a
// reader at the head ends in block 31. A play's span holds the whole file.
- (NSURL *)hiresWAVNamed:(NSString *)name {
    const uint32_t frames = 192000 * 16;
    return VibeWriteWAV([self sourceNamed:name], VibeNoiseSamples(frames, 2), 192000, 2, 16, frames * 4);
}

// A handle on a network copy, its read-ahead fetched to the floor.
- (AudioFileHandle *)openAtTheFloor:(NSURL *)source {
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], NULL);
    XCTAssertNotNil(handle);
    NSString *name = source.lastPathComponent;
    XCTAssertTrue([self eventually:^BOOL { return [self->_script readsOf:name at:31 * kReadAheadBlock] == 1; }], @"%@", name);
    XCTAssertEqual([_script readsOf:name at:32 * kReadAheadBlock], 0u, @"%@: never past the floor", name);
    return handle;
}

// A play's handle whose read-ahead is busy: its reads stall past the floor.
- (AudioFileHandle *)busyPlayNamed:(NSString *)name {
    [_script stallReadsOf:name from:32 * kReadAheadBlock];
    AudioFileHandle *handle = [self openAtTheFloor:[self hiresWAVNamed:name]];
    [handle holdStream];
    XCTAssertTrue([self await:_script.stalled], @"%@ fetches past its floor", name);
    return handle;
}

// A frame a little into block `index` of a 16-bit stereo WAV, past its
// 44-byte header.
static AVAudioFramePosition VibeFrameInBlock(uint64_t index) {
    return (AVAudioFramePosition)(index * kReadAheadBlock - 44) / 4 + 100;
}

// Seeks to `frame` and decodes 4096 frames off the test's thread, as the
// decoder does. `done` gets the PCM, nil when the seek fails.
- (dispatch_semaphore_t)decode:(AudioFileHandle *)handle
                          from:(AVAudioFramePosition)frame
                          then:(void (^)(NSData *pcm))done {
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSData *pcm = [handle seekToFrame:frame error:&error] ? VibeDecode(handle, 4096, 4096, &error) : nil;
        if (done) {
            done(pcm);
        }
        dispatch_semaphore_signal(finished);
    });
    return finished;
}

// Every fixture, its reads throttled so they wait at the read-ahead's edge,
// decodes as its direct open does, to the read that finds the end, with the
// same decoder and the same length, and its handle holds no descriptor of
// its own: the read-ahead's thread is the only reader of the file.
- (void)testEveryFormatReadingAheadDecodesAsItsDirectOpen {
    NSMutableDictionary<NSURL *, NSString *> *fixtures = [[self fixtures] mutableCopy];
    [fixtures addEntriesFromDictionary:[self tailFixtures]];
    fixtures[[self noiseWAVNamed:@"long.wav" frames:400000]] = @"dr_wav";
    [self readAhead].throttle = 2000;
    for (NSURL *source in fixtures) {
        NSString *name = source.lastPathComponent;
        NSURL *url = [self networkCopyOf:source];
        AudioFileHandle *whole = [self openWhole:source];
        for (NSNumber *chunk in @[@333, @4096]) {
            NSString *context = [NSString stringWithFormat:@"%@, chunk %@", name, chunk];
            NSError *error = nil;
            AudioFileHandle *handle = VibeOpenInterruptibly(url, &error);
            XCTAssertNotNil(handle, @"%@: %@", context, error);
            XCTAssertTrue(handle.waitsForBytes, @"%@ reads ahead", context);
            XCTAssertEqualObjects(handle.decoderName, fixtures[source], @"%@", context);
            XCTAssertEqualObjects(handle.decoderName, whole.decoderName, @"%@", context);
            XCTAssertEqual(handle.length, whole.length, @"%@", context);
            XCTAssertEqual(handle.lengthIsEstimated, whole.lengthIsEstimated, @"%@", context);
            NSData *pcm = VibeDecode(handle, chunk.unsignedIntValue, INT64_MAX, &error);
            XCTAssertNotNil(pcm, @"%@: %@", context, error);
            [self assertPCM:pcm equals:[self referenceOf:source from:0 frames:INT64_MAX] context:context];
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:64];
            XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@: the end again: %@", context, error);
            XCTAssertEqual(buffer.frameLength, 0u, @"%@", context);
            XCTAssertGreaterThanOrEqual(handle.bytesWritten, [NSData dataWithContentsOfURL:source].length,
                                        @"%@: progress counts every byte fetched", context);
        }
    }
}

- (void)testAReadAheadOpenFailsAsTheDirectOpenDoes {
    [self readAhead];
    NSURL *empty = [_network URLByAppendingPathComponent:@"empty.wav"];
    XCTAssertTrue([NSData.data writeToURL:empty atomically:YES]);
    NSURL *directory = [_network URLByAppendingPathComponent:@"folder.flac" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO
                                                          attributes:nil error:NULL]);
    NSURL *missing = [_network URLByAppendingPathComponent:@"missing.mp3"];
    for (NSURL *url in @[empty, directory, missing]) {
        NSString *name = url.lastPathComponent;
        NSError *direct = nil, *ahead = nil;
        XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:&direct], @"%@", name);
        XCTAssertNil(VibeOpenInterruptibly(url, &ahead), @"%@", name);
        XCTAssertNotNil(direct, @"%@", name);
        XCTAssertEqualObjects(ahead.domain, direct.domain, @"%@", name);
        XCTAssertEqual(ahead.code, direct.code, @"%@", name);
        XCTAssertEqualObjects(ahead.localizedDescription, direct.localizedDescription, @"%@", name);
        XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 0, @"%@: its thread exited before the handle went", name);
    }
    XCTAssertTrue([self eventually:^BOOL { return AudioFileHandle.debugLiveReadAheads == 0; }]);
}

// An open whose first read never returns is still the caller's to end: its
// `interrupted` answering YES returns it as an interruption, with no wake,
// and the thread, orphaned inside its read, exits once the read returns.
- (void)testAStalledOpenReturnsAsAnInterruption {
    VibeReadAheadScript *script = [self readAhead];
    [script stallFrom:0];
    NSURL *url = [self networkCopyOf:[self noiseWAVNamed:@"stalled.wav" frames:20000]];
    __block _Atomic bool cancelled = false;
    __block NSError *error = nil;
    __block BOOL opened = YES;
    XCTestExpectation *returned = [self expectationWithDescription:@"open returned"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *openError = nil;
        @autoreleasepool {
            opened = [[AudioFileHandle alloc] initForReading:url interleaved:NO interrupted:^BOOL {
                return atomic_load(&cancelled);
            } error:&openError] != nil;
        }
        error = openError;
        [returned fulfill];
    });
    XCTAssertTrue([self await:script.stalled], @"the first read stalls");
    atomic_store(&cancelled, true);
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse(opened);
    XCTAssertTrue([AudioFileHandle isInterruption:error], @"%@", error);
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 1, @"its thread is still in the read");
    [script releaseStalls];
    XCTAssertTrue([self eventually:^BOOL { return VibeReadAheadScript.threadsGone; }]);
}

// A read waiting on a stalled read-ahead returns on interruptReads, neither
// the end nor a failure. After allowReads a seek into what is held lands
// exactly, and once the server answers again the rest reads exactly too.
- (void)testAStalledReadReturnsOnInterruptReadsAndASeekLandsExactly {
    VibeReadAheadScript *script = [self readAhead];
    [script stallFrom:2 * kReadAheadBlock];
    NSURL *source = [self noiseWAVNamed:@"stall-read.wav" frames:400000];
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], NULL);
    XCTAssertNotNil(handle);
    __block NSError *error = nil;
    __block NSData *before = nil;
    XCTestExpectation *returned = [self expectationWithDescription:@"read returned"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *readError = nil;
        before = VibeDecode(handle, 4096, INT64_MAX, &readError);
        error = readError;
        [returned fulfill];
    });
    XCTAssertTrue([self await:script.stalled]);
    XCTAssertTrue([self eventually:^BOOL { return handle.waitingForBytes; }], @"the read waits at the edge");
    [handle interruptReads];
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNil(before);
    XCTAssertTrue([AudioFileHandle isInterruption:error], @"%@", error);
    XCTAssertFalse(handle.waitingForBytes);

    [handle allowReads];
    NSError *seekError = nil;
    XCTAssertTrue([handle seekToFrame:1000 error:&seekError], @"%@", seekError);
    [self assertPCM:VibeDecode(handle, 4096, 20000, &seekError) equals:[self referenceOf:source from:1000 frames:20000]
            context:@"a seek into what is held"];
    [script releaseStalls];
    XCTAssertTrue([handle seekToFrame:150000 error:&seekError], @"%@", seekError);
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, &seekError) equals:[self referenceOf:source from:150000 frames:INT64_MAX]
            context:@"the rest, once the server answers"];
}

- (void)testProgressStaysFlatWhileReadsAreInterrupted {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    [script stallFrom:2 * block];
    NSURL *source = [self noiseWAVNamed:@"paused.wav" frames:400000];
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], NULL);
    XCTAssertNotNil(handle);
    XCTAssertTrue([self await:script.stalled]);
    [handle interruptReads];
    [script releaseStalls];
    XCTAssertTrue([self eventually:^BOOL { return handle.bytesWritten == 3 * block; }],
                  @"the read in flight lands: %llu", handle.bytesWritten);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTAssertEqual(handle.bytesWritten, 3 * block, @"nothing more while interrupted");
    [handle allowReads];
    uint64_t size = [NSData dataWithContentsOfURL:source].length;
    XCTAssertTrue([self eventually:^BOOL { return handle.bytesWritten == size; }], @"%llu of %llu", handle.bytesWritten, size);
}

- (void)testAFailedReadIsRetriedAndTheDecodeCompletesExactly {
    VibeReadAheadScript *script = [self readAhead];
    [script fail:EIO from:kReadAheadBlock always:NO];
    NSURL *source = [self noiseWAVNamed:@"retried.wav" frames:400000];
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], NULL);
    NSError *error = nil;
    NSData *pcm = VibeDecode(handle, 4096, INT64_MAX, &error);
    XCTAssertNotNil(pcm, @"%@", error);
    [self assertPCM:pcm equals:[self referenceOf:source from:0 frames:INT64_MAX] context:@"retried"];
    XCTAssertEqual([script readsAt:kReadAheadBlock], 2u, @"failed once, then read");
}

- (void)testAFileReplacedWhileAReadFailsFailsTheReads {
    VibeReadAheadScript *script = [self readAhead];
    [script fail:EIO from:kReadAheadBlock always:NO];
    [script holdFailures];
    NSURL *url = [self networkCopyOf:[self noiseWAVNamed:@"replaced.wav" frames:400000]];
    AudioFileHandle *handle = VibeOpenInterruptibly(url, NULL);
    XCTAssertNotNil(handle);
    __block NSData *pcm = nil;
    __block NSError *error = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"decode returned"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *readError = nil;
        pcm = VibeDecode(handle, 4096, INT64_MAX, &readError);
        error = readError;
        [done fulfill];
    });
    XCTAssertTrue([self await:script.failed], @"the read fails");
    NSURL *replacement = [self noiseWAVNamed:@"replacement.wav" frames:300000];
    XCTAssertEqual(rename(replacement.fileSystemRepresentation, url.fileSystemRepresentation), 0);
    [script releaseStalls];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNil(pcm, @"the decode never reads the new file's bytes");
    XCTAssertFalse([AudioFileHandle isInterruption:error], @"%@", error);
    NSError *cause = error;
    while (cause && !(cause.domain == NSPOSIXErrorDomain && cause.code == ESTALE)) {
        cause = cause.userInfo[NSUnderlyingErrorKey];
    }
    XCTAssertNotNil(cause, @"%@", error);
    XCTAssertEqual([script readsAt:kReadAheadBlock], 1u, @"failed, then never read again");
}

// A file cut short after its open ends there cleanly, with no error and no
// wait, as the direct open of the cut file does. The read-ahead's thread has
// opened it when its first read stalls, and the file is cut then.
- (void)testAFileCutShortAfterItsOpenEndsCleanly {
    const uint64_t cut = kReadAheadBlock;
    AudioStreamBasicDescription flac = {.mSampleRate = 44100, .mFormatID = kAudioFormatFLAC,
                                        .mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData, .mChannelsPerFrame = 2};
    NSError *error = nil;
    NSArray<NSURL *> *sources = @[[self noiseWAVNamed:@"cut.wav" frames:400000],
                                  VibeWriteEncoded([self sourceNamed:@"cut.flac"], kAudioFileFLACType, flac, &error)];
    VibeReadAheadScript *script = [self readAhead];
    for (NSURL *source in sources) {
        NSString *name = source.lastPathComponent;
        NSData *bytes = [NSData dataWithContentsOfURL:source];
        XCTAssertGreaterThan(bytes.length, cut, @"%@", name);
        NSURL *shortened = [self sourceNamed:[@"short-" stringByAppendingString:name]];
        XCTAssertTrue([[bytes subdataWithRange:NSMakeRange(0, cut)] writeToURL:shortened atomically:YES]);
        NSData *reference = VibeDecode([self openWhole:shortened], 4096, INT64_MAX, &error);
        XCTAssertNotNil(reference, @"%@: %@", name, error);

        [script stallFrom:0];
        __block NSData *pcm = nil;
        __block NSError *readError = nil;
        XCTestExpectation *done = [self expectationWithDescription:name];
        NSURL *url = [self networkCopyOf:source];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *failure = nil;
            AudioFileHandle *handle = VibeOpenInterruptibly(url, &failure);
            pcm = handle ? VibeDecode(handle, 4096, INT64_MAX, &failure) : nil;
            readError = failure;
            [done fulfill];
        });
        XCTAssertTrue([self await:script.stalled], @"%@", name);
        XCTAssertEqual(truncate(url.fileSystemRepresentation, (off_t)cut), 0, @"%@", name);
        [script releaseStalls];
        [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertNotNil(pcm, @"%@: %@", name, readError);
        [self assertPCM:pcm equals:reference context:name];
    }
}

// A read that finds nothing short of the size while the file is whole, as a
// share's can while it reconnects, is a failed read. It is retried, and the
// decode completes exactly, never ending early.
- (void)testANothingReadShortOfTheSizeIsRetriedWhenTheFileIsWhole {
    VibeReadAheadScript *script = [self readAhead];
    [script cutOnceAt:kReadAheadBlock];
    NSURL *source = [self noiseWAVNamed:@"reconnect.wav" frames:400000];
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], NULL);
    NSError *error = nil;
    NSData *pcm = VibeDecode(handle, 4096, INT64_MAX, &error);
    XCTAssertNotNil(pcm, @"%@", error);
    [self assertPCM:pcm equals:[self referenceOf:source from:0 frames:INT64_MAX] context:@"read on"];
    XCTAssertEqual([script readsAt:kReadAheadBlock], 2u, @"read nothing once, then read");
}

// Eight handles gone while their threads are stuck in a read make a ninth
// read-ahead open wait, with no thread made, until one of them exits. A ninth
// whose `interrupted` answers YES returns as an interruption. Live handles
// never count: more than eight open fine, and the direct road never waits.
- (void)testEightOrphansMakeTheNinthReadAheadWaitWhileLiveHandlesOpenFine {
    VibeReadAheadScript *script = [self readAhead];
    NSURL *url = [self networkCopyOf:[self noiseWAVNamed:@"orphans.wav" frames:100000]];
    @autoreleasepool {
        NSMutableArray<AudioFileHandle *> *live = [NSMutableArray array];
        for (int i = 0; i < 10; i++) {
            NSError *error = nil;
            AudioFileHandle *handle = VibeOpenInterruptibly(url, &error);
            XCTAssertNotNil(handle, @"live %d: %@", i, error);
            [live addObject:handle ?: (id)NSNull.null];
        }
        XCTAssertEqual(AudioFileHandle.debugLiveReadAheads, 10);
        XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 0);
    }
    XCTAssertTrue([self eventually:^BOOL { return AudioFileHandle.debugLiveReadAheads == 0; }]);
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 0, @"idle threads exit with their handles");

    [script stallFrom:kReadAheadBlock];
    @autoreleasepool {
        NSMutableArray<AudioFileHandle *> *stuck = [NSMutableArray array];
        for (int i = 0; i < 8; i++) {
            AudioFileHandle *handle = VibeOpenInterruptibly(url, NULL);
            XCTAssertNotNil(handle, @"%d", i);
            [stuck addObject:handle ?: (id)NSNull.null];
            XCTAssertTrue([self await:script.stalled], @"%d: its read-ahead is stuck", i);
        }
    }
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 8);
    XCTAssertEqual(AudioFileHandle.debugLiveReadAheads, 8);

    __block _Atomic bool cancelled = false;
    __block AudioFileHandle *interrupted = nil, *waited = nil;
    __block NSError *interruption = nil, *waitError = nil;
    dispatch_semaphore_t interruptedReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t waitedReturned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *openError = nil;
        interrupted = [[AudioFileHandle alloc] initForReading:url interleaved:NO interrupted:^BOOL {
            return atomic_load(&cancelled);
        } error:&openError];
        interruption = openError;
        dispatch_semaphore_signal(interruptedReturned);
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *openError = nil;
        waited = VibeOpenInterruptibly(url, &openError);
        waitError = openError;
        dispatch_semaphore_signal(waitedReturned);
    });
    XCTAssertNotEqual(dispatch_semaphore_wait(waitedReturned, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC))), 0,
                      @"the ninth waits");
    XCTAssertEqual(AudioFileHandle.debugLiveReadAheads, 8, @"no thread made while it waits");
    XCTAssertNotNil([[AudioFileHandle alloc] initForReading:url error:NULL], @"the direct road never waits");

    atomic_store(&cancelled, true);
    XCTAssertTrue([self await:interruptedReturned]);
    XCTAssertNil(interrupted);
    XCTAssertTrue([AudioFileHandle isInterruption:interruption], @"%@", interruption);
    XCTAssertEqual(AudioFileHandle.debugLiveReadAheads, 8, @"no thread made");

    [script releaseOneStall];
    XCTAssertTrue([self await:waitedReturned], @"one orphan exited");
    XCTAssertNotNil(waited, @"%@", waitError);
    XCTAssertTrue(waited.waitsForBytes);
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 7);
}

// The metadata parse's never-wait open and an open with no `interrupted`
// block both take the direct road on a network file: no thread, no waits.
- (void)testAnOpenThatCannotBeInterruptedNeverReadsAhead {
    NSURL *url = [self networkCopyOf:[self noiseWAVNamed:@"direct.wav" frames:20000]];
    NSInteger live = AudioFileHandle.debugLiveReadAheads;
    AudioFileHandle *never = [[AudioFileHandle alloc] initForReading:url interleaved:NO
                                                         interrupted:VibeNeverWaitsForAStream error:NULL];
    AudioFileHandle *none = [[AudioFileHandle alloc] initForReading:url error:NULL];
    AudioFileHandle *parser = [[AudioFileHandle alloc] initParserForReading:url interrupted:VibeNeverWaitsForAStream
                                                                      error:NULL];
    XCTAssertNotNil(never);
    XCTAssertNotNil(none);
    XCTAssertNotNil(parser);
    XCTAssertFalse(never.waitsForBytes);
    XCTAssertFalse(none.waitsForBytes);
    XCTAssertFalse(parser.waitsForBytes);
    XCTAssertEqual(AudioFileHandle.debugLiveReadAheads, live);
    XCTAssertEqual([_script readsAt:0], 0u, @"nothing read ahead");
    XCTAssertTrue(VibeOpenInterruptibly(url, NULL).waitsForBytes, @"an interruptible open does");
}

// A headerless MP3 read ahead is counted at its open, as a local file is,
// its frame headers read through the waits: its length is exact, never an
// estimate.
- (void)testAHeaderlessMP3ReadingAheadOpensOnAnExactCount {
    NSURL *source = [self sourceNamed:@"headerless.mp3"];
    XCTAssertTrue([VibeMP3WithoutVBRHeader(3000, 44100, ^uint8_t(uint32_t frame) { return (uint8_t)(9 + frame % 6); })
                   writeToURL:source atomically:YES]);
    [self readAhead].throttle = 2000;
    AudioFileHandle *whole = [self openWhole:source];
    NSError *error = nil;
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], &error);
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertTrue(handle.waitsForBytes);
    XCTAssertFalse(handle.lengthIsEstimated);
    XCTAssertEqual(handle.length, whole.length);
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, &error) equals:[self referenceOf:source from:0 frames:INT64_MAX]
            context:@"headerless"];
}

// A QuickTime container has no callback open, so it takes the URL road, and
// the read-ahead it began is finished: its thread exits, and the file reads
// as its direct open does. AVAudioFile cannot write one, hence the asset
// writer.
- (void)testTheQuickTimeRoadEndsItsReadAhead {
    NSURL *source = [self sourceNamed:@"memo.qta"];
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:source fileType:AVFileTypeQuickTimeMovie error:&error];
    XCTAssertNotNil(writer, @"%@", error);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
            outputSettings:@{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @44100, AVNumberOfChannelsKey: @2}];
    [writer addInput:input];
    XCTAssertTrue([writer startWriting], @"%@", writer.error);
    [writer startSessionAtSourceTime:kCMTimeZero];
    AVAudioPCMBuffer *noise = VibeNoiseBuffer(44100);
    AVAudioFormat *interleaved = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100
                                                                    channels:2 interleaved:YES];
    AVAudioPCMBuffer *samples = [[AVAudioPCMBuffer alloc] initWithPCMFormat:interleaved frameCapacity:noise.frameLength];
    samples.frameLength = noise.frameLength;
    for (AVAudioFrameCount f = 0; f < noise.frameLength; f++) {
        samples.floatChannelData[0][2 * f] = noise.floatChannelData[0][f];
        samples.floatChannelData[0][2 * f + 1] = noise.floatChannelData[1][f];
    }
    CMFormatDescriptionRef description = NULL;
    XCTAssertEqual(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, interleaved.streamDescription, 0, NULL, 0, NULL,
                                                  NULL, &description), noErr);
    CMSampleBufferRef sample = NULL;
    XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault, NULL, false, NULL, NULL, description,
                                                                   samples.frameLength, kCMTimeZero, NULL, &sample), noErr);
    XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample, kCFAllocatorDefault, kCFAllocatorDefault, 0,
                                                                  samples.audioBufferList), noErr);
    while (!input.readyForMoreMediaData) {
        [NSThread sleepForTimeInterval:0.001];
    }
    XCTAssertTrue([input appendSampleBuffer:sample], @"%@", writer.error);
    CFRelease(sample);
    CFRelease(description);
    [input markAsFinished];
    XCTestExpectation *finished = [self expectationWithDescription:@"written"];
    [writer finishWritingWithCompletionHandler:^{ [finished fulfill]; }];
    [self waitForExpectations:@[finished] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(writer.status, AVAssetWriterStatusCompleted, @"%@", writer.error);

    NSURL *url = [self networkCopyOf:source];
    AudioFileHandle *handle = VibeOpenInterruptibly(url, &error);
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertFalse(handle.waitsForBytes, @"the URL road reads the file itself");
    XCTAssertGreaterThan([_script readsAt:0], 0u, @"it began reading ahead");
    XCTAssertTrue([self eventually:^BOOL { return AudioFileHandle.debugLiveReadAheads == 0; }], @"and that thread ended");
    AudioFileHandle *whole = [self openWhole:source];
    XCTAssertGreaterThan(handle.length, 0);
    XCTAssertEqual(handle.length, whole.length);
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, &error) equals:[self referenceOf:source from:0 frames:INT64_MAX]
            context:@"memo.qta, aac"];
}

// The read-ahead keeps one block behind the reader's and drops what lies
// further back: a seek back into the block before the reader's, as an MP3
// seek's preroll or dr_flac's bisection reads back, costs no second read of
// it, and one far behind reads its block again.
- (void)testTheReadAheadKeepsOneBlockBehindTheReader {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    // 10.8 MB: more than the span ahead of a reader in block 6.
    NSURL *source = [self noiseWAVNamed:@"evicted.wav" frames:2700000];
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], NULL);
    NSError *error = nil;
    // 80 KB into block 6, so the last read began inside it.
    AVAudioFramePosition reached = (AVAudioFramePosition)(6 * block - 44) / 4 + 20000;
    XCTAssertNotNil(VibeDecode(handle, 4096, reached, &error), @"%@", error);
    // The span ahead of a reader in block 6 ends in block 38. Its install
    // dropped what lies behind block 5.
    XCTAssertTrue([self eventually:^BOOL { return [script readsAt:38 * block] == 1; }]);
    XCTAssertEqual([script readsAt:39 * block], 0u, @"never past the span");

    AVAudioFramePosition behind = (AVAudioFramePosition)(5 * block - 44) / 4 + 100;
    XCTAssertTrue([handle seekToFrame:behind error:&error], @"%@", error);
    [self assertPCM:VibeDecode(handle, 4096, 8192, &error) equals:[self referenceOf:source from:behind frames:8192]
            context:@"one block behind"];
    XCTAssertEqual([script readsAt:5 * block], 1u, @"the block behind the reader's was kept");

    XCTAssertEqual([script readsAt:2 * block], 1u);
    AVAudioFramePosition far = (AVAudioFramePosition)(2 * block - 44) / 4 + 100;
    XCTAssertTrue([handle seekToFrame:far error:&error], @"%@", error);
    [self assertPCM:VibeDecode(handle, 4096, 8192, &error) equals:[self referenceOf:source from:far frames:8192]
            context:@"far behind"];
    XCTAssertEqual([script readsAt:2 * block], 2u, @"a block far behind was dropped and read again");
}

// The coordinator sends holdStream to a play's handle, and its read-ahead
// then fetches about 30 s ahead. A 192 kHz WAV's 8 MB floor lasts 10.9 s. Its
// 16 s fit inside the raised span. The waveform's handle is never sent it,
// and stops at the floor.
- (void)testHoldStreamRaisesTheSpanToAboutThirtySeconds {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    AudioFileHandle *handle = [self openAtTheFloor:[self hiresWAVNamed:@"hires.wav"]];
    [handle holdStream];
    XCTAssertTrue([self eventually:^BOOL { return [script readsAt:40 * block] == 1; }], @"past the floor");
    XCTAssertEqual([script readsAt:32 * block], 1u);
}

// The playing track's read-ahead goes first. The next track's, sized after
// it, fetches nothing ahead while the first still has blocks to fetch. Here
// the first stalls past its floor. Once the first holds its whole span, the
// second fetches ahead too.
- (void)testAPlaysReadAheadWaitsUntilTheEarlierPlayHasItsSpan {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    __unused AudioFileHandle *first = [self busyPlayNamed:@"first.wav"];
    // Opened while the first is busy. It is no play yet, and fetches its floor.
    AudioFileHandle *second = [self openAtTheFloor:[self hiresWAVNamed:@"second.wav"]];
    [second holdStream];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTAssertEqual([script readsOf:@"second.wav" at:32 * block], 0u, @"held back while the first fetches");
    [script releaseStalls];
    XCTAssertTrue([self eventually:^BOOL { return [script readsOf:@"second.wav" at:40 * block] == 1; }]);
    XCTAssertEqual([script readsOf:@"first.wav" at:46 * block], 1u, @"the first fetched its last block first");
}

// An earlier play whose handle is gone holds nothing back, even while its
// thread is still inside a read.
- (void)testAPlaysReadAheadGoesOnceTheEarlierPlaysHandleIsGone {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    AudioFileHandle *second = nil;
    @autoreleasepool {
        __unused AudioFileHandle *first = [self busyPlayNamed:@"first.wav"];
        second = [self openAtTheFloor:[self hiresWAVNamed:@"second.wav"]];
        [second holdStream];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        XCTAssertEqual([script readsOf:@"second.wav" at:32 * block], 0u, @"held back while the first fetches");
    }
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 1, @"the first's thread is still in its read");
    XCTAssertTrue([self eventually:^BOOL { return [script readsOf:@"second.wav" at:40 * block] == 1; }]);
}

// A held-back play's read-ahead still fetches at once the range a wait
// wants, so an open or a decoder read never waits for the earlier play.
// Nothing past that range is fetched ahead.
- (void)testAHeldBackPlaysWaitIsServedAtOnce {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    __unused AudioFileHandle *first = [self busyPlayNamed:@"first.wav"];
    NSURL *source = [self hiresWAVNamed:@"second.wav"];
    AudioFileHandle *second = [self openAtTheFloor:source];
    [second holdStream];
    AVAudioFramePosition frame = VibeFrameInBlock(40);
    __block NSData *pcm = nil;
    dispatch_semaphore_t done = [self decode:second from:frame then:^(NSData *decoded) { pcm = decoded; }];
    XCTAssertTrue([self await:done], @"the read never waits for the first");
    [self assertPCM:pcm equals:[self referenceOf:source from:frame frames:4096] context:@"held back"];
    XCTAssertEqual([script readsOf:@"second.wav" at:40 * block], 1u);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTAssertEqual([script readsOf:@"second.wav" at:41 * block], 0u, @"nothing ahead of the read");
}

// The waveform loader never sends holdStream, so its read-ahead is no play.
// It fetches its floor while a play's is busy, and a busy one holds no play
// back.
- (void)testTheWaveformsReadAheadNeitherWaitsForAPlayNorHoldsOneBack {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    __unused AudioFileHandle *play = [self busyPlayNamed:@"play.wav"];
    NSURL *source = [self hiresWAVNamed:@"waveform.wav"];
    AudioFileHandle *waveform = [self openAtTheFloor:source];

    // The play fetches to its end and is idle. The waveform's read then
    // stalls far ahead, and its read-ahead is busy.
    [script stallReadsOf:@"waveform.wav" from:40 * block];
    XCTAssertTrue([self eventually:^BOOL { return [script readsOf:@"play.wav" at:46 * block] == 1; }]);
    dispatch_semaphore_t done = [self decode:waveform from:VibeFrameInBlock(40) then:nil];
    XCTAssertTrue([self await:script.stalled], @"the waveform's read stalls");
    AudioFileHandle *later = [self openAtTheFloor:[self hiresWAVNamed:@"later.wav"]];
    [later holdStream];
    XCTAssertTrue([self eventually:^BOOL { return [script readsOf:@"later.wav" at:40 * block] == 1; }]);
    [script releaseStalls];
    XCTAssertTrue([self await:done]);
}

- (void)testAHandleGoneDuringTheRetryPauseEndsItsThreadWithoutARetry {
    VibeReadAheadScript *script = [self readAhead];
    [script fail:EIO from:kReadAheadBlock always:NO];
    [script holdFailures];
    NSURL *url = [self networkCopyOf:[self noiseWAVNamed:@"pausing.wav" frames:400000]];
    @autoreleasepool {
        AudioFileHandle *handle = VibeOpenInterruptibly(url, NULL);
        XCTAssertNotNil(handle);
        XCTAssertTrue([self await:script.failed], @"a read failed");
    }
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 1, @"its thread holds the failed read");
    [script releaseStalls];
    XCTAssertTrue([self eventually:^BOOL { return VibeReadAheadScript.threadsGone; }]);
    XCTAssertEqual([script readsAt:kReadAheadBlock], 1u, @"never retried");
    XCTAssertEqual(script.reads, 2u, @"block 0, then the failed read, and nothing after");
}

// An open that read the file's tail last, an M4A with its moov there, leaves
// its reader at the head. The thread then fetches the whole span ahead of the
// head with no read asked of it, as a parked prefetch needs. Throttled, the
// thread cannot reach the span's last block while the open still reads the
// head.
- (void)testAnOpenThatReadTheTailFetchesAheadOfTheHead {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock;
    AudioStreamBasicDescription alac = {.mSampleRate = 44100, .mFormatID = kAudioFormatAppleLossless,
                                        .mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData,
                                        .mFramesPerPacket = 4096, .mChannelsPerFrame = 2};
    NSURL *moovFirst = [self sourceNamed:@"long-moov-first.m4a"];
    NSError *error = nil;
    AVAudioPCMBuffer *noise = VibeNoiseBuffer(88200);
    AudioFileHandle *writer = [[AudioFileHandle alloc] initForWriting:moovFirst fileType:kAudioFileM4AType
                                                           fileFormat:[[AVAudioFormat alloc] initWithStreamDescription:&alac]
                                                     processingFormat:noise.format error:&error];
    for (int i = 0; i < 28; i++) {
        XCTAssertTrue([writer writeFromBuffer:noise error:&error], @"%@", error);
    }
    XCTAssertTrue([writer closeWithError:&error], @"%@", error);
    NSData *moovLast = VibeMoovLast([NSData dataWithContentsOfURL:moovFirst]);
    XCTAssertGreaterThan(moovLast.length, 34 * block, @"the tail's drop keeps nothing of the span");
    NSURL *source = [self sourceNamed:@"long-moov-last.m4a"];
    XCTAssertTrue([moovLast writeToURL:source atomically:YES]);
    script.throttle = 2000;
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], &error);
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertTrue([self eventually:^BOOL { return [script readsAt:31 * block] == 1; }], @"the span's last block");
}

// A read that fails after a partial result leaves a block ending inside a
// range a wait wants. The retry fetches from that end, and no byte below it
// is read twice.
- (void)testARetryAfterAPartialReadStartsAtTheHeldEnd {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = kReadAheadBlock, partial = block + 100 * 1024;
    NSURL *source = [self noiseWAVNamed:@"partial.wav" frames:400000];
    NSURL *url = [self networkCopyOf:source];
    NSData *bytes = [NSData dataWithContentsOfURL:source];
    [script stallFrom:block];
    AudioFileHandle *handle = VibeOpenInterruptibly(url, NULL);
    XCTAssertNotNil(handle);
    XCTAssertTrue([self await:script.stalled], @"block 1's read waits");
    // The file is short while that read runs: its first pread comes back
    // partial, and the next one fails. It is whole again, with its mtime, by
    // the retry's reopen, which then finds the same file.
    struct stat whole;
    XCTAssertEqual(stat(url.fileSystemRepresentation, &whole), 0);
    XCTAssertEqual(truncate(url.fileSystemRepresentation, (off_t)partial), 0);
    [script fail:EIO from:partial always:NO];
    [script holdFailures];
    [script stallFrom:UINT64_MAX];
    XCTAssertTrue([self await:script.failed]);
    XCTAssertTrue([bytes writeToURL:url atomically:NO]);
    struct timespec times[2] = {{.tv_nsec = UTIME_OMIT}, whole.st_mtimespec};
    XCTAssertEqual(utimensat(AT_FDCWD, url.fileSystemRepresentation, times, 0), 0);
    // A read straddling the partial end, asked before the failure lands.
    AVAudioFramePosition frame = (AVAudioFramePosition)(partial - 2048 - 44) / 4;
    __block NSData *pcm = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *readError = nil;
        pcm = [handle seekToFrame:frame error:&readError] ? VibeDecode(handle, 4096, 4096, &readError) : nil;
        error = readError;
        dispatch_semaphore_signal(done);
    });
    XCTAssertTrue([self eventually:^BOOL { return handle.waitingForBytes; }]);
    [script releaseStalls];
    XCTAssertTrue([self await:done]);
    [self assertPCM:pcm equals:[self referenceOf:source from:frame frames:4096] context:@"across the partial end"];
    XCTAssertEqual([script readsAt:block], 1u, @"the partial read is never repeated");
    XCTAssertEqual([script readsAt:partial], 2u, @"the failed read, then the retry from the held end");
}

@end
