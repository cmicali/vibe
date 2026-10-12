//
//  DropboxMirrorStreamingTests.m
//
//  The fetch's part file read while it streams: readable before the end, a
//  handle opened mid-fetch, the tail window, and the row's loading bar.
//

#import "DropboxMirrorTestCase.h"

// RemotePlaceholderStore's kStreamReadableBytes, which DropboxMirror inherits.
static const uint64_t kReadableBytes = 256 * 1024;

// Every availability's notes and finish pass through these while they are
// set, so a test sees each as the mirror makes it, before it lands.
static os_unfair_lock sObserverLock = OS_UNFAIR_LOCK_INIT;
static void (^sNoteObserver)(CloudFileAvailability *availability, uint64_t bytes);
static void (^sFinishObserver)(CloudFileAvailability *availability, NSError *error);
static IMP sNoteIMP;
static IMP sFinishIMP;

static void ObservedNote(id availability, SEL selector, uint64_t bytes) {
    os_unfair_lock_lock(&sObserverLock);
    void (^observer)(CloudFileAvailability *, uint64_t) = sNoteObserver;
    os_unfair_lock_unlock(&sObserverLock);
    if (observer) {
        observer(availability, bytes);
    }
    ((void (*)(id, SEL, uint64_t))sNoteIMP)(availability, selector, bytes);
}

static void ObservedFinish(id availability, SEL selector, NSError *error) {
    os_unfair_lock_lock(&sObserverLock);
    void (^observer)(CloudFileAvailability *, NSError *) = sFinishObserver;
    os_unfair_lock_unlock(&sObserverLock);
    if (observer) {
        observer(availability, error);
    }
    ((void (*)(id, SEL, NSError *))sFinishIMP)(availability, selector, error);
}

static void ObserveAvailabilities(void (^_Nullable note)(CloudFileAvailability *, uint64_t),
                                  void (^_Nullable finish)(CloudFileAvailability *, NSError *)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = CloudFileAvailability.class;
        sNoteIMP = method_setImplementation(class_getInstanceMethod(cls, @selector(noteWrittenBytes:)),
                                            (IMP)ObservedNote);
        sFinishIMP = method_setImplementation(class_getInstanceMethod(cls, @selector(finishWithError:)),
                                              (IMP)ObservedFinish);
    });
    os_unfair_lock_lock(&sObserverLock);
    sNoteObserver = [note copy];
    sFinishObserver = [finish copy];
    os_unfair_lock_unlock(&sObserverLock);
}

// Interleaved float32 from the cursor to the end; nil when a read answers NO.
static NSData *DecodeAll(AudioFileHandle *handle, NSError **error) {
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
    NSMutableData *pcm = [NSMutableData data];
    for (;;) {
        if (![handle readIntoBuffer:buffer frameCount:4096 error:error]) {
            return nil;
        }
        if (buffer.frameLength == 0) {
            return pcm;
        }
        VibeAppendPCM(pcm, buffer);
    }
}

@interface DropboxMirrorStreamingTests : DropboxMirrorTestCase <CloudTransferRegistryObserver>
@end

@implementation DropboxMirrorStreamingTests {
    // The gate each held chunk waits on, the notes and finishes observed,
    // and the fetch's track and its outcome.
    dispatch_semaphore_t _chunkGate;
    dispatch_semaphore_t _noteSignal;
    NSMutableArray<NSArray *> *_notes;
    NSMutableArray<NSDictionary *> *_finishes;
    NSURL *_streamTrack;
    BOOL _fetched;
    NSError *_fetchError;
    // The row's loading bar: the open, and the movements observed.
    AudioFileMaterializationCoordinator *_coordinator;
    AudioFileOpenToken *_openToken;
    AudioFileHandle *_delivered;
    NSMutableArray<NSString *> *_moves;
}

- (void)setUp {
    [super setUp];
    _chunkGate = dispatch_semaphore_create(0);
    _noteSignal = dispatch_semaphore_create(0);
}

- (void)tearDown {
    os_unfair_lock_lock(&sObserverLock);
    sNoteObserver = nil;
    sFinishObserver = nil;
    os_unfair_lock_unlock(&sObserverLock);
    // A held chunk's stub, cancelled under it, goes on to find its load stopped.
    [self releaseChunks:1000];
    [super tearDown];
}

#pragma mark Streaming

// One mirrored track whose download is held back a chunk at a time, every
// chunk waiting on _chunkGate; chunk 0 delivers it whole.
- (NSURL *)streamingTrack:(NSData *)bytes name:(NSString *)name chunk:(NSUInteger)chunk {
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", name, (long long)bytes.length, kStamp)];
    _contents[[@"/music/" stringByAppendingString:name.lowercaseString]] = bytes;
    NSURL *track = [[self refresh:@"/Music"] URLByAppendingPathComponent:name];
    [self installMirrorFetch];
    dispatch_semaphore_t gate = _chunkGate;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        DropboxStubResponse answer = [self answer:request];
        answer.chunk = chunk;
        answer.beforeChunk = ^(NSUInteger chunkIndex) {
            dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        };
        return answer;
    }];
    _streamTrack = track;
    return track;
}

- (void)releaseChunks:(NSUInteger)count {
    for (NSUInteger i = 0; i < count; i++) {
        dispatch_semaphore_signal(_chunkGate);
    }
}

// Each note with the part file's size and the window held as it was made,
// and each finish with what the install and the lookup looked like then.
- (void)recordAvailabilities {
    @synchronized (self) {
        _notes = [NSMutableArray array];
        _finishes = [NSMutableArray array];
    }
    __weak DropboxMirrorStreamingTests *weakSelf = self;
    ObserveAvailabilities(^(CloudFileAvailability *availability, uint64_t bytes) {
        DropboxMirrorStreamingTests *test = weakSelf;
        if (!test) {
            return;
        }
        struct stat st = {0};
        stat(availability.partURL.fileSystemRepresentation, &st);
        // Outside the test's lock: XCTest takes it to report a runtime issue,
        // which can fire inside the availability's.
        uint64_t window = availability.windowLength;
        @synchronized (test) {
            [test->_notes addObject:@[availability, @(bytes), @(st.st_size), @(window)]];
        }
        dispatch_semaphore_signal(test->_noteSignal);
    }, ^(CloudFileAvailability *availability, NSError *error) {
        DropboxMirrorStreamingTests *test = weakSelf;
        if (!test) {
            return;
        }
        NSURL *track = test->_streamTrack;
        NSDictionary *finish = @{
            @"availability": availability,
            @"error": error ?: NSNull.null,
            @"partExists": @([NSFileManager.defaultManager fileExistsAtPath:availability.partURL.path]),
            @"installed": @((StatOf(track).st_mode & 0777) == 0644),
            @"registered": @([test->_mirror availabilityForURL:track] == availability),
        };
        @synchronized (test) {
            [test->_finishes addObject:finish];
        }
    });
}

- (NSArray<NSArray *> *)notes {
    @synchronized (self) {
        return [_notes copy];
    }
}

- (NSArray<NSDictionary *> *)finishes {
    @synchronized (self) {
        return [_finishes copy];
    }
}

- (uint64_t)mostNoted {
    uint64_t most = 0;
    for (NSArray *note in [self notes]) {
        most = MAX(most, [note[1] unsignedLongLongValue]);
    }
    return most;
}

// Until a note has reached `bytes`, or `count` notes were made.
- (void)awaitNoted:(uint64_t)bytes count:(NSUInteger)count {
    while ([self mostNoted] < bytes || [self notes].count < count) {
        if (dispatch_semaphore_wait(_noteSignal, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) != 0) {
            XCTFail(@"noted %llu of %llu in %lu notes", [self mostNoted], bytes, (unsigned long)[self notes].count);
            return;
        }
    }
}

// The fetch's availability, once its first response made the part file.
- (CloudFileAvailability *)awaitAvailability {
    [self awaitNoted:0 count:1];
    return [self notes].firstObject[0];
}

// Materializes the track on a worker; _fetched and _fetchError once fulfilled.
- (XCTestExpectation *)fetch:(NSURL *)track materializer:(CloudFileMaterializer *)materializer
                  onReadable:(dispatch_block_t)onReadable {
    XCTestExpectation *returned = [self expectationWithDescription:@"fetched"];
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        self->_fetched = [materializer materializeURL:track token:token onReadable:onReadable error:&error];
        self->_fetchError = error;
        [returned fulfill];
    });
    return returned;
}

// A wait for [offset, offset + length) on a worker: `blocked` is signalled
// once it is about to block, and the returned semaphore when it returns.
- (dispatch_semaphore_t)read:(CloudFileAvailability *)availability at:(uint64_t)offset length:(uint64_t)length
                     blocked:(dispatch_semaphore_t)blocked result:(CloudFileAvailabilityWait *)result
                       error:(NSError *__strong *)error {
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block BOOL signalled = NO;
        NSError *waitError = nil;
        *result = [availability waitForBytesAt:offset length:length windowInto:NULL capacity:0 copied:NULL interrupted:^BOOL{
            if (!signalled) {
                signalled = YES;
                dispatch_semaphore_signal(blocked);
            }
            return NO;
        } deadline:nil error:&waitError];
        if (error) {
            *error = waitError;
        }
        dispatch_semaphore_signal(returned);
    });
    return returned;
}

- (BOOL)await:(dispatch_semaphore_t)semaphore {
    BOOL signalled = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
    XCTAssertTrue(signalled);
    return signalled;
}

// The finish came after the install, or the failure, and before the lookup
// let go; then it lets go.
- (void)assertFinishedOnce:(CloudFileAvailability *)availability error:(NSError *)error {
    NSArray<NSDictionary *> *finishes = [self finishes];
    XCTAssertEqual(finishes.count, 1u);
    NSDictionary *finish = finishes.firstObject;
    XCTAssertEqual(finish[@"availability"], availability);
    XCTAssertEqualObjects(finish[@"error"], error ?: NSNull.null);
    // Installed, or deleted; kept only when the link ended the transfer.
    XCTAssertEqualObjects(finish[@"partExists"], @([_client keepsPartAfterError:error]));
    XCTAssertEqualObjects(finish[@"installed"], @(error == nil));
    XCTAssertEqualObjects(finish[@"registered"], @YES, @"the lookup let go before the finish");
    XCTAssertNil([_mirror availabilityForURL:_streamTrack]);
    XCTAssertNil([CloudFileMaterializer availabilityForURL:_streamTrack]);
}

// Registered at the first response, before any byte; noted after each write
// with no more than is on disk; readable once, past 256 KB; a reader waiting
// ahead released by the download alone.
- (void)testAStreamingFetchIsReadableThroughTheLookupAsItsBytesArrive {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = PatternBytes(16 * chunk);
    NSURL *track = [self streamingTrack:bytes name:@"stream.flac" chunk:chunk];
    NSURL *part = [PlaceholderFiles remotePlaceholderPartURL:track];
    [self recordAvailabilities];
    DropboxMirror *mirror = _mirror;
    __block _Atomic int readables = 0;
    __block uint64_t readableOnDisk = 0;
    __block CloudFileAvailability *readableRegistered = nil;
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        readableOnDisk = (uint64_t)StatOf(part).st_size;
        readableRegistered = [mirror availabilityForURL:track];
        atomic_fetch_add(&readables, 1);
    }];

    CloudFileAvailability *availability = [self awaitAvailability];
    XCTAssertEqual([_mirror availabilityForURL:track], availability);
    XCTAssertEqual([CloudFileMaterializer availabilityForURL:track], availability);
    XCTAssertEqualObjects(availability.partURL.path, part.path);
    XCTAssertEqual(availability.size, (uint64_t)bytes.length);
    XCTAssertEqual(StatOf(part).st_size, (off_t)0, @"registered before any byte");

    dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
    CloudFileAvailabilityWait waited = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:9 * chunk + 100 length:1000
                                       blocked:blocked result:&waited error:NULL];
    [self await:blocked];
    for (NSUInteger i = 1; i <= 16; i++) {
        [self releaseChunks:1];
        [self awaitNoted:i * chunk count:0];
        if (i * chunk < kReadableBytes) {
            XCTAssertEqual(atomic_load(&readables), 0, @"chunk %lu", (unsigned long)i);
        }
        else if (i * chunk > kReadableBytes) {
            XCTAssertEqual(atomic_load(&readables), 1, @"chunk %lu", (unsigned long)i);
        }
        if (i < 10) {
            XCTAssertNotEqual(dispatch_semaphore_wait(returned, DISPATCH_TIME_NOW), 0, @"chunk %lu", (unsigned long)i);
        }
        else if (i == 10) {
            [self await:returned];
            XCTAssertEqual(waited, CloudFileAvailabilityReady);
        }
    }

    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertEqual(atomic_load(&readables), 1);
    XCTAssertGreaterThanOrEqual(readableOnDisk, kReadableBytes);
    XCTAssertEqual(readableRegistered, availability);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);

    NSArray<NSArray *> *notes = [self notes];
    XCTAssertGreaterThan(notes.count, 16u);
    uint64_t previous = 0;
    for (NSArray *note in notes) {
        XCTAssertEqual(note[0], availability);
        uint64_t noted = [note[1] unsignedLongLongValue];
        XCTAssertGreaterThanOrEqual([note[2] unsignedLongLongValue], noted, @"noted before it was written");
        XCTAssertGreaterThanOrEqual(noted, previous);
        previous = noted;
    }
    XCTAssertEqual(previous, (uint64_t)bytes.length);
    [self assertFinishedOnce:availability error:nil];
}

// Completing says ready: a file no bigger than the readable mark never
// reports readable, though it streams.
- (void)testASmallFileCompletesWithoutReportingReadable {
    NSData *bytes = PatternBytes(100 * 1024);
    NSURL *track = [self streamingTrack:bytes name:@"short.flac" chunk:16 * 1024];
    [self recordAvailabilities];
    [self releaseChunks:7];
    __block _Atomic int readables = 0;
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        atomic_fetch_add(&readables, 1);
    }];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertEqual(atomic_load(&readables), 0);
    XCTAssertEqual([self mostNoted], (uint64_t)bytes.length);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);
}

// The previous steps and this one end to end: the handle opens the part file
// while the rest of the download is held back, reads on as it arrives,
// follows the rename, and decodes exactly what the whole file decodes.
- (void)testAHandleOpenedMidFetchDecodesAsTheWholeFile {
    NSURL *sources = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"DropboxMirrorTests-sources-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:sources withIntermediateDirectories:YES attributes:nil error:NULL];
    // Four seconds of 16-bit stereo, 690 KB: past the readable mark twice over.
    const NSUInteger frames = 4 * 44100;
    NSMutableData *samples = [NSMutableData dataWithLength:frames * 2 * 2];
    int16_t *out = samples.mutableBytes;
    uint32_t state = 0x2468ace1;
    for (NSUInteger i = 0; i < frames * 2; i++) {
        state = state * 1664525u + 1013904223u;
        out[i] = (int16_t)(sin((double)i * 0.0123) * 12000.0 + (double)(int16_t)(state >> 16) * 0.5);
    }
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSURL *wav = VibeWriteWAV([sources URLByAppendingPathComponent:@"noise.wav"], samples, 44100, 2, 16,
                              (uint32_t)samples.length);
    XCTAssertNotNil(wav);
    if (wav) {
        [files addObject:wav];
    }
    // The real encode with a seek table, when the gitignored corpus is here.
    NSString *tone = [[NSString stringWithUTF8String:__FILE__].stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"../../../../Assets/test_audio_files/tone.flac"].stringByStandardizingPath;
    if ([NSFileManager.defaultManager fileExistsAtPath:tone]) {
        [files addObject:[NSURL fileURLWithPath:tone]];
    }

    const NSUInteger chunk = 32 * 1024;
    NSUInteger streamed = 0;
    for (NSURL *source in files) {
        NSData *bytes = [NSData dataWithContentsOfURL:source];
        if (bytes.length < 2 * kReadableBytes) {
            continue;
        }
        streamed++;
        NSError *error = nil;
        AudioFileHandle *whole = [[AudioFileHandle alloc] initForReading:source error:&error];
        NSData *reference = whole ? DecodeAll(whole, &error) : nil;
        XCTAssertNotNil(reference, @"%@: %@", source.lastPathComponent, error);

        _chunkGate = dispatch_semaphore_create(0);
        NSURL *track = [self streamingTrack:bytes name:source.lastPathComponent chunk:chunk];
        [self recordAvailabilities];
        dispatch_semaphore_t readable = dispatch_semaphore_create(0);
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
            dispatch_semaphore_signal(readable);
        }];
        NSUInteger chunks = (bytes.length + chunk - 1) / chunk;
        NSUInteger head = (NSUInteger)(kReadableBytes / chunk);
        [self releaseChunks:head];
        if (![self await:readable]) {
            [self releaseChunks:chunks];
            [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
            continue;
        }
        CloudFileAvailability *availability = [self awaitAvailability];

        dispatch_semaphore_t opened = dispatch_semaphore_create(0);
        dispatch_semaphore_t decoded = dispatch_semaphore_create(0);
        __block AudioFileHandle *handle = nil;
        __block NSData *pcm = nil;
        __block NSError *readError = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *failure = nil;
            handle = [[AudioFileHandle alloc] initForReading:track error:&failure];
            dispatch_semaphore_signal(opened);
            pcm = handle ? DecodeAll(handle, &failure) : nil;
            readError = failure;
            dispatch_semaphore_signal(decoded);
        });
        // Opened with most of the file still held back: from the part file.
        XCTAssertTrue([self await:opened], @"%@", source.lastPathComponent);
        XCTAssertNotNil(handle, @"%@: %@", source.lastPathComponent, readError);
        XCTAssertLessThan([self mostNoted], (uint64_t)bytes.length);
        [self releaseChunks:chunks];

        XCTAssertTrue([self await:decoded]);
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertTrue(_fetched, @"%@: %@", source.lastPathComponent, _fetchError);
        XCTAssertNotNil(pcm, @"%@: %@", source.lastPathComponent, readError);
        XCTAssertEqual(pcm.length, reference.length, @"%@", source.lastPathComponent);
        XCTAssertTrue([pcm isEqualToData:reference], @"%@: the streamed decode differs", source.lastPathComponent);
        [self assertFinishedOnce:availability error:nil];
    }
    XCTAssertGreaterThan(streamed, 0u);
    [NSFileManager.defaultManager removeItemAtURL:sources error:NULL];
}

// A transfer failing mid-way, by a changed version or an error answer to its
// resume, fails a reader waiting ahead with the fetch's own error, and is
// then forgotten.
- (void)testAFailedResumeWakesAWaitingReaderWithTheFailure {
    for (NSNumber *changed in @[@YES, @NO]) {
        NSData *bytes = PatternBytes(1024 * 1024);
        NSURL *track = [self streamingTrack:bytes name:@"fails.flac" chunk:0];
        NSURL *part = [PlaceholderFiles remotePlaceholderPartURL:track];
        [self recordAvailabilities];
        dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
        dispatch_semaphore_t resume = dispatch_semaphore_create(0);
        [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
            if (index == 0) {
                return VibeDropped([self answer:request], request, 300 * 1024, part);
            }
            // Only once the reader is waiting past what was written.
            dispatch_semaphore_wait(resume, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            return changed.boolValue
                    ? VibeDownloadAnswer(request, bytes, @{@"rev": @"0200beef", @"server_modified": kStamp})
                    : DropboxStubJSON(409, @{@"error_summary": @"path/not_found/"});
        }];
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
        CloudFileAvailability *availability = [self awaitAvailability];
        CloudFileAvailabilityWait waited = CloudFileAvailabilityReady;
        NSError *readError = nil;
        dispatch_semaphore_t returned = [self read:availability at:600 * 1024 length:1000
                                           blocked:blocked result:&waited error:&readError];
        [self await:blocked];
        dispatch_semaphore_signal(resume);

        [self await:returned];
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertFalse(_fetched);
        XCTAssertEqual(waited, CloudFileAvailabilityFailed, @"changed %@", changed);
        XCTAssertEqualObjects(readError, _fetchError);
        if (changed.boolValue) {
            XCTAssertEqual(readError.code, VibeDropboxErrorFileChanged);
        }
        XCTAssertEqual(StatOf(track).st_mode & 0777, 0);
        [self assertFinishedOnce:availability error:_fetchError];
    }
}

// The client's cancel reaches a waiting reader as the failure it is, never
// a clean end or a wait that outlives the transfer.
- (void)testCancellingAStreamingFetchWakesItsReaderAndForgetsIt {
    const NSUInteger chunk = 64 * 1024;
    NSURL *track = [self streamingTrack:PatternBytes(8 * chunk) name:@"cancel.flac" chunk:chunk];
    [self recordAvailabilities];
    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    XCTestExpectation *fetched = [self fetch:track materializer:materializer onReadable:nil];
    [self releaseChunks:1];
    [self awaitNoted:chunk count:0];
    CloudFileAvailability *availability = [self notes].firstObject[0];

    dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
    CloudFileAvailabilityWait waited = CloudFileAvailabilityReady;
    NSError *readError = nil;
    dispatch_semaphore_t returned = [self read:availability at:3 * chunk length:1000
                                       blocked:blocked result:&waited error:&readError];
    [self await:blocked];
    [materializer cancel];

    [self await:returned];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(waited, CloudFileAvailabilityFailed);
    XCTAssertEqualObjects(readError.domain, VibeDropboxErrorDomain);
    XCTAssertEqual(readError.code, VibeDropboxErrorCancelled);
    XCTAssertFalse(_fetched);
    XCTAssertEqual(_fetchError.code, NSUserCancelledError);
    XCTAssertEqual(StatOf(track).st_mode & 0777, 0);
    [self assertFinishedOnce:availability error:readError];
}

// A resume continues the transfer, so it continues its availability: one
// object from the first byte to the last, a reader across the gap included
// (short of the tail window, which would answer it from memory).
- (void)testAResumedFetchKeepsItsAvailability {
    NSData *bytes = PatternBytes(1024 * 1024);
    NSURL *track = [self streamingTrack:bytes name:@"resumed.flac" chunk:0];
    NSURL *part = [PlaceholderFiles remotePlaceholderPartURL:track];
    [self recordAvailabilities];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return VibeDropped([self answer:request], request, 300 * 1024, part);
        }
        dispatch_semaphore_wait(resume, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        return [self answer:request];
    }];
    __block _Atomic int readables = 0;
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        atomic_fetch_add(&readables, 1);
    }];
    CloudFileAvailability *availability = [self awaitAvailability];
    dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
    CloudFileAvailabilityWait waited = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:700 * 1024 length:1000
                                       blocked:blocked result:&waited error:NULL];
    [self await:blocked];
    dispatch_semaphore_signal(resume);

    [self await:returned];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertEqual(waited, CloudFileAvailabilityReady);
    XCTAssertEqual(atomic_load(&readables), 1);
    XCTAssertEqualObjects([[self requestsToPath:@"/2/files/download"].lastObject valueForHTTPHeaderField:@"Range"],
                          @"bytes=307200-");
    for (NSArray *note in [self notes]) {
        XCTAssertEqual(note[0], availability);
    }
    XCTAssertEqual([self mostNoted], (uint64_t)bytes.length);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);
    [self assertFinishedOnce:availability error:nil];
}

#pragma mark The tail window

// A small format's window (AudioFileOpenRules.h).
static const uint64_t kWindowBytes = 128 * 1024;

// Every ranged read that completes calls this after its completion returns,
// while it is set: when a tail read's answer has reached the mirror.
static os_unfair_lock sReadLock = OS_UNFAIR_LOCK_INIT;
static dispatch_block_t sReadObserver;
static IMP sReadIMP;

static dispatch_block_t ObservedReadTarget(id client, SEL selector, id target, uint64_t offset, uint64_t length,
                                           void (^completion)(NSData *, NSDictionary *, NSError *)) {
    void (^observed)(NSData *, NSDictionary *, NSError *) = ^(NSData *data, NSDictionary *metadata, NSError *error) {
        completion(data, metadata, error);
        os_unfair_lock_lock(&sReadLock);
        dispatch_block_t observer = sReadObserver;
        os_unfair_lock_unlock(&sReadLock);
        if (observer) {
            observer();
        }
    };
    return ((dispatch_block_t (*)(id, SEL, id, uint64_t, uint64_t, id))sReadIMP)(client, selector, target, offset,
                                                                                 length, observed);
}

static void ObserveRangedReads(dispatch_block_t _Nullable observer) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Added on the subclass, so other clients' reads are not observed.
        Method read = class_getInstanceMethod(HTTPTransferClient.class, @selector(readTarget:offset:length:completion:));
        sReadIMP = method_getImplementation(read);
        class_addMethod(DropboxClient.class, method_getName(read), (IMP)ObservedReadTarget,
                        method_getTypeEncoding(read));
    });
    os_unfair_lock_lock(&sReadLock);
    sReadObserver = [observer copy];
    os_unfair_lock_unlock(&sReadLock);
}

- (NSArray<NSURLRequest *> *)tailReads {
    return [[self requestsToPath:@"/2/files/download"] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        return VibeIsClosedRange(request);
    }]];
}

// A stream whose download is held a chunk at a time, its tail read answered
// by `tail` (nil: the file's bytes by range, held until `tailGate`).
- (NSURL *)tailedTrack:(NSData *)bytes name:(NSString *)name chunk:(NSUInteger)chunk
                  tail:(DropboxStubResponse (^_Nullable)(NSURLRequest *request))tail
              tailGate:(dispatch_semaphore_t)tailGate {
    NSURL *track = [self streamingTrack:bytes name:name chunk:chunk];
    NSDictionary *metadata = @{@"server_modified": kStamp, @"size": @(bytes.length), @"rev": kRev};
    @synchronized (self) {
        _rangeScript = tail ?: ^DropboxStubResponse(NSURLRequest *request) {
            DropboxStubResponse answer = VibeDownloadAnswer(request, bytes, metadata);
            answer.chunk = answer.body.length;
            answer.beforeChunk = ^(NSUInteger index) {
                dispatch_semaphore_wait(tailGate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            };
            return answer;
        };
    }
    return track;
}

// A stream past twice the window reads its last 128 KB once, by id, as it
// starts; readable does not wait for it; the window holds it, so an MP3,
// whose open reads its last bytes, opens on the part file with only its head
// downloaded; the download reaching the window drops it; and the decode is
// the whole file's.
- (void)testAStreamReadsItsTailOnceAndAnMP3OpensOnTheHeadAndTheWindow {
    NSData *bytes = VibeMP3WithInfoFrame(4200, YES);
    XCTAssertGreaterThan(bytes.length, 2 * kWindowBytes);
    NSURL *sources = [_root URLByAppendingPathComponent:@"sources" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:sources withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *local = [sources URLByAppendingPathComponent:@"long.mp3"];
    XCTAssertTrue([bytes writeToURL:local atomically:YES]);
    NSError *error = nil;
    AudioFileHandle *whole = [[AudioFileHandle alloc] initForReading:local error:&error];
    NSData *reference = whole ? DecodeAll(whole, &error) : nil;
    XCTAssertNotNil(reference, @"%@", error);

    const NSUInteger chunk = 64 * 1024;
    dispatch_semaphore_t tailGate = dispatch_semaphore_create(0);
    NSURL *track = [self tailedTrack:bytes name:@"long.mp3" chunk:chunk tail:nil tailGate:tailGate];
    [self recordAvailabilities];
    dispatch_semaphore_t readable = dispatch_semaphore_create(0);
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        dispatch_semaphore_signal(readable);
    }];
    CloudFileAvailability *availability = [self awaitAvailability];
    XCTAssertTrue([self eventually:^BOOL { return [self tailReads].count == 1; }]);
    NSURLRequest *tailRead = [self tailReads].firstObject;
    uint64_t windowOffset = bytes.length - kWindowBytes;
    XCTAssertEqualObjects([tailRead valueForHTTPHeaderField:@"Range"],
                          ([NSString stringWithFormat:@"bytes=%llu-%llu", windowOffset, (uint64_t)bytes.length - 1]));
    XCTAssertTrue([[tailRead valueForHTTPHeaderField:@"Dropbox-API-Arg"] containsString:@"id:/music/long.mp3"]);

    // Readable at the mark, the tail read still held.
    [self releaseChunks:(NSUInteger)(kReadableBytes / chunk)];
    XCTAssertTrue([self await:readable]);
    XCTAssertEqual(availability.windowLength, 0u);
    dispatch_semaphore_signal(tailGate);
    XCTAssertTrue([self eventually:^BOOL { return availability.windowLength == kWindowBytes; }]);

    // Opened on the head and the window, nothing more released.
    dispatch_semaphore_t opened = dispatch_semaphore_create(0);
    dispatch_semaphore_t decoded = dispatch_semaphore_create(0);
    __block AudioFileHandle *handle = nil;
    __block NSData *pcm = nil;
    __block NSError *readError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *failure = nil;
        handle = [[AudioFileHandle alloc] initForReading:track error:&failure];
        dispatch_semaphore_signal(opened);
        pcm = handle ? DecodeAll(handle, &failure) : nil;
        readError = failure;
        dispatch_semaphore_signal(decoded);
    });
    XCTAssertTrue([self await:opened]);
    XCTAssertNotNil(handle, @"%@", readError);
    XCTAssertEqual([self mostNoted], kReadableBytes, @"opened without another byte of the download");
    XCTAssertEqual(handle.length, whole.length);

    // Up to the window's start: dropped, the rest still downloading.
    [self releaseChunks:(NSUInteger)((windowOffset + chunk - 1) / chunk - kReadableBytes / chunk)];
    [self awaitNoted:windowOffset count:0];
    // Polled: the observer sees a note before it lands, and the window goes as it lands.
    XCTAssertTrue([self eventually:^BOOL { return availability.windowLength == 0; }], @"the download reached the window");
    XCTAssertLessThan([self mostNoted], (uint64_t)bytes.length);
    [self releaseChunks:bytes.length / chunk + 1];

    XCTAssertTrue([self await:decoded]);
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertNotNil(pcm, @"%@", readError);
    XCTAssertTrue([pcm isEqualToData:reference], @"the streamed decode differs");
    XCTAssertEqual([self tailReads].count, 1u);
    [self assertFinishedOnce:availability error:nil];
}

// The tail read failing, or stalling until the download's end cancels it, is
// not the transfer's failure: the window stays absent, a read inside it waits
// for the download, and the fetch completes with every byte.
- (void)testAFailedOrStalledTailReadLeavesTheTransferWhole {
    for (NSNumber *stall in @[@NO, @YES]) {
        NSData *bytes = PatternBytes((NSUInteger)(2 * kWindowBytes + 1));
        _chunkGate = dispatch_semaphore_create(0);
        NSURL *track = [self tailedTrack:bytes name:stall.boolValue ? @"stalled.flac" : @"failed.flac" chunk:256 * 1024
                                    tail:^DropboxStubResponse(NSURLRequest *request) {
            if (stall.boolValue) {
                return (DropboxStubResponse){.hang = YES};
            }
            return DropboxStubJSON(500, @{@"error_summary": @"internal/"});
        } tailGate:nil];
        [self recordAvailabilities];
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
        CloudFileAvailability *availability = [self awaitAvailability];
        XCTAssertTrue([self eventually:^BOOL { return [self tailReads].count == 1; }], @"stall %@", stall);

        dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
        __block CloudFileAvailabilityWait waited = CloudFileAvailabilityFailed;
        __block uint64_t copied = 0;
        uint8_t *buffer = malloc(4096);
        dispatch_semaphore_t returned = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __block BOOL signalled = NO;
            uint64_t got = 0;
            waited = [availability waitForBytesAt:bytes.length - 128 length:128 windowInto:buffer capacity:4096
                                           copied:&got interrupted:^BOOL{
                if (!signalled) {
                    signalled = YES;
                    dispatch_semaphore_signal(blocked);
                }
                return NO;
            } deadline:nil error:NULL];
            copied = got;
            dispatch_semaphore_signal(returned);
        });
        XCTAssertTrue([self await:blocked]);
        XCTAssertNotEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5)), 0,
                          @"stall %@: the tail waits for the download", stall);
        XCTAssertEqual(availability.windowLength, 0u);
        [self releaseChunks:bytes.length / (256 * 1024) + 1];

        XCTAssertTrue([self await:returned]);
        XCTAssertEqual(waited, CloudFileAvailabilityReady);
        XCTAssertEqual(copied, 0u, @"read from the disk");
        free(buffer);
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertTrue(_fetched, @"stall %@: %@", stall, _fetchError);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);
        XCTAssertEqual([self tailReads].count, 1u, @"stall %@: one read, never retried", stall);
        [self assertFinishedOnce:availability error:nil];
        [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
            return [self defaultResponseFor:request json:json];
        }];
        os_unfair_lock_lock(&sStubLock);
        [sStubRequests removeAllObjects];
        os_unfair_lock_unlock(&sStubLock);
    }
}

// The tail read goes out beside the download, before its first response, and
// whichever answer lands second installs the window, only when both name one
// rev and the download's size is the listing's: a tail of another version, a
// tail naming none, or an offset taken from a stale listing is dropped and
// the transfer goes on whole.
- (void)testTheTailIsReadBesideTheDownloadAndKeptOnlyForItsVersion {
    typedef NS_ENUM(NSInteger, Case) { TailFirst, DownloadFirst, TailFirstOtherRev, DownloadFirstOtherRev, NoRev, StaleListing };
    NSArray<NSString *> *names = @[@"tail first", @"download first", @"tail first, another rev",
                                   @"download first, another rev", @"no rev on the tail", @"listed at another size"];
    const NSUInteger chunk = 256 * 1024;
    for (Case each = TailFirst; each <= StaleListing; each++) {
        NSString *label = names[each];
        BOOL tailFirst = each == TailFirst || each == TailFirstOtherRev || each == NoRev || each == StaleListing;
        BOOL kept = each == TailFirst || each == DownloadFirst;
        NSData *bytes = PatternBytes(4 * chunk + 1);
        uint64_t listed = each == StaleListing ? bytes.length - 10 : bytes.length;
        NSString *name = [NSString stringWithFormat:@"case%ld.flac", (long)each];
        _chunkGate = dispatch_semaphore_create(0);
        os_unfair_lock_lock(&sStubLock);
        [sStubRequests removeAllObjects];
        os_unfair_lock_unlock(&sStubLock);
        NSURL *track = [self streamingTrack:bytes name:name chunk:chunk];
        if (each == StaleListing) {
            _listings[@"/music"] = @[VibeFileEntry(@"/Music", name, (long long)listed, kStamp)];
            [NSFileManager.defaultManager removeItemAtURL:track error:NULL];
            [self refresh:@"/Music"];
            XCTAssertEqual(StatOf(track).st_size, (off_t)listed);
        }
        dispatch_semaphore_t landed = dispatch_semaphore_create(0);
        ObserveRangedReads(^{
            dispatch_semaphore_signal(landed);
        });
        dispatch_semaphore_t tailGate = dispatch_semaphore_create(0);
        NSDictionary *metadata = @{@"server_modified": kStamp, @"size": @(bytes.length),
                                   @"rev": each == TailFirstOtherRev || each == DownloadFirstOtherRev ? @"0badc0de" : kRev};
        @synchronized (self) {
            _rangeScript = ^DropboxStubResponse(NSURLRequest *request) {
                DropboxStubResponse answer = VibeDownloadAnswer(request, bytes, metadata);
                if (each == NoRev) {
                    answer.headers = @{@"Content-Type": @"application/octet-stream"};
                }
                if (!tailFirst) {
                    answer.chunk = answer.body.length;
                    answer.beforeChunk = ^(NSUInteger index) {
                        dispatch_semaphore_wait(tailGate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
                    };
                }
                return answer;
            };
        }
        // Tail first: the download's response waits until the tail's answer
        // has reached the mirror.
        dispatch_semaphore_t chunkGate = _chunkGate;
        [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
            DropboxStubResponse answer = [self answer:request];
            answer.chunk = chunk;
            answer.beforeChunk = ^(NSUInteger chunkIndex) {
                dispatch_semaphore_wait(chunkGate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            };
            if (tailFirst) {
                answer.beforeResponse = ^{
                    dispatch_semaphore_wait(landed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
                };
            }
            return answer;
        }];
        [self recordAvailabilities];
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
        XCTAssertTrue([self eventually:^BOOL { return [self tailReads].count == 1; }], @"%@", label);
        NSURLRequest *tailRead = [self tailReads].firstObject;
        XCTAssertEqualObjects([tailRead valueForHTTPHeaderField:@"Range"],
                              ([NSString stringWithFormat:@"bytes=%llu-%llu", listed - kWindowBytes, listed - 1]), @"%@", label);
        XCTAssertTrue([[tailRead valueForHTTPHeaderField:@"Dropbox-API-Arg"] containsString:
                       [@"id:/music/" stringByAppendingString:name]], @"%@: by the download's id", label);
        CloudFileAvailability *availability = [self awaitAvailability];
        uint64_t windowAtFirstNote = [[self notes].firstObject[3] unsignedLongLongValue];
        if (tailFirst) {
            XCTAssertEqual(windowAtFirstNote, kept ? kWindowBytes : 0u, @"%@: settled as the stream was made", label);
        }
        else {
            XCTAssertEqual(windowAtFirstNote, 0u, @"%@", label);
            dispatch_semaphore_signal(tailGate);
            XCTAssertTrue([self await:landed], @"%@", label);
        }
        XCTAssertEqual(availability.windowLength, kept ? kWindowBytes : 0u, @"%@", label);
        if (kept) {
            uint8_t probe[16];
            uint64_t copied = 0;
            XCTAssertEqual([availability waitForBytesAt:bytes.length - 16 length:16 windowInto:probe capacity:16
                                                 copied:&copied interrupted:^BOOL { return YES; } deadline:nil error:NULL],
                           CloudFileAvailabilityReady, @"%@", label);
            XCTAssertEqual(memcmp(probe, (const uint8_t *)bytes.bytes + bytes.length - 16, 16), 0, @"%@", label);
        }
        [self releaseChunks:5];
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertTrue(_fetched, @"%@: %@", label, _fetchError);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes, @"%@", label);
        XCTAssertEqual([self tailReads].count, 1u, @"%@", label);
        [self assertFinishedOnce:availability error:nil];
        ObserveRangedReads(nil);
        @synchronized (self) {
            _rangeScript = nil;
        }
    }
}

// A tag parse of a file streaming now asks Dropbox for none of what the
// stream is about to hold: a head read waits for the download, a trailer read
// is the window's, and any other range takes what is on disk, asking only for
// the rest.
- (void)testATagReadDuringAStreamTakesWhatTheStreamHolds {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = PatternBytes(2 * 1024 * 1024);
    NSURL *track = [self streamingTrack:bytes name:@"tagged.flac" chunk:chunk];
    [self recordAvailabilities];
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
    CloudFileAvailability *availability = [self awaitAvailability];
    XCTAssertTrue([self eventually:^BOOL { return availability.windowLength == kWindowBytes; }]);
    XCTAssertEqual([self tailReads].count, 1u);

    // The parse's first read, 384 KB from the head, waits for the download.
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    __block NSData *head = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        head = [self->_mirror readPlaceholderAtURL:track offset:0 length:6 * chunk error:NULL];
        dispatch_semaphore_signal(returned);
    });
    XCTAssertNotEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5)), 0,
                      @"waiting for the head");
    [self releaseChunks:18];
    XCTAssertTrue([self await:returned]);
    XCTAssertEqualObjects(head, [bytes subdataWithRange:NSMakeRange(0, 6 * chunk)]);
    [self awaitNoted:18 * chunk count:0];
    // Polled: the observer sees a note before it lands, and the reads below take what has.
    XCTAssertTrue([self eventually:^BOOL { return availability.writtenBytes == 18 * chunk; }]);

    NSError *error = nil;
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:bytes.length - 128 length:128 error:&error],
                          [bytes subdataWithRange:NSMakeRange(bytes.length - 128, 128)], @"%@", error);
    XCTAssertEqual([self tailReads].count, 1u, @"head and trailer asked nothing of Dropbox");

    // Past the first MB and the window: the part file's prefix, one request for the rest.
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:17 * chunk length:2 * chunk error:&error],
                          [bytes subdataWithRange:NSMakeRange(17 * chunk, 2 * chunk)], @"%@", error);
    XCTAssertEqual([self tailReads].count, 2u);
    XCTAssertEqualObjects([[self tailReads].lastObject valueForHTTPHeaderField:@"Range"],
                          ([NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)(18 * chunk),
                            (unsigned long)(19 * chunk - 1)]));
    // Nothing of it held: all by range.
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:24 * chunk length:chunk error:&error],
                          [bytes subdataWithRange:NSMakeRange(24 * chunk, chunk)], @"%@", error);
    XCTAssertEqual([self tailReads].count, 3u);

    [self releaseChunks:bytes.length / chunk];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    [self assertFinishedOnce:availability error:nil];
}

#pragma mark The row's loading bar

- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
}

- (void)cloudTransferRegistry:(CloudTransferRegistry *)registry didMoveTransferForPath:(NSString *)path {
    @synchronized (self) {
        [_moves addObject:path];
    }
}

// A playback open of a mirrored track through the real coordinator, the
// download held back a chunk at a time; the listing says `listedBytes`, the
// download answers `bytes`.
- (NSURL *)openRowTrack:(NSData *)bytes listed:(long long)listedBytes chunk:(NSUInteger)chunk {
    NSURL *track = [self streamingTrack:bytes name:@"row.wav" chunk:chunk];
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"row.wav", listedBytes, kStamp)];
    [self refresh:@"/Music"];
    _coordinator = [[AudioFileMaterializationCoordinator alloc] init];
    _openToken = [_coordinator openURL:track purpose:VibeAudioFileOpenPurposePlayback
                      completionQueue:dispatch_get_main_queue() onDataless:nil
                           completion:^(AudioFileHandle *file, NSError *error, NSTimeInterval elapsed) {
        self->_delivered = file;
    }];
    return track;
}

- (NSData *)rowWAV:(NSUInteger)length {
    NSURL *wav = VibeWriteWAV([_root URLByAppendingPathComponent:@"source.wav"], [NSMutableData dataWithLength:length],
                              44100, 2, 16, (uint32_t)length);
    NSData *bytes = [NSData dataWithContentsOfURL:wav];
    [NSFileManager.defaultManager removeItemAtURL:wav error:NULL];
    return bytes;
}

// The row's fraction is the transfer's written bytes over its size, within a
// whole percent and a poll.
- (BOOL)row:(NSURL *)track showsWritten:(uint64_t)written of:(uint64_t)size {
    float wanted = (float)written / (float)size;
    return [self eventually:^BOOL {
        return fabsf([CloudTransferRegistry.sharedRegistry progressForURL:track] - wanted) <= 0.011f;
    }];
}

// The row a stream plays from keeps following its transfer once the player
// has started on it, from the begin, through readable, to the end, and the
// transfer's movement reaches an observer under the row's own path.
- (void)testAStreamsRowFollowsItsTransferFromBeginToEnd {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = [self rowWAV:16 * chunk];
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    _moves = [NSMutableArray array];
    [registry addObserver:self];
    NSURL *track = [self openRowTrack:bytes listed:(long long)bytes.length chunk:chunk];

    XCTAssertTrue([self eventually:^BOOL { return [registry isTransferringURL:track]; }], @"begin, before any byte");
    XCTAssertEqual([registry progressForURL:track], -1);
    [self releaseChunks:2];
    XCTAssertTrue([self row:track showsWritten:2 * chunk of:bytes.length], @"%.3f", [registry progressForURL:track]);
    [self releaseChunks:6];
    XCTAssertTrue([self eventually:^BOOL { return self->_delivered != nil; }], @"readable: the player starts on it");
    XCTAssertTrue([registry isTransferringURL:track], @"and the transfer runs on");
    [self releaseChunks:6];
    XCTAssertTrue([self row:track showsWritten:14 * chunk of:bytes.length],
                  @"the row froze at %.3f after the start", [registry progressForURL:track]);
    @synchronized (self) {
        XCTAssertGreaterThan(_moves.count, 0u);
        XCTAssertEqualObjects(_moves.firstObject, VibeStandardizedAudioOpenPath(track));
    }

    [self releaseChunks:100];
    XCTAssertTrue([self eventually:^BOOL { return ![registry isTransferringURL:track]; }], @"end on complete");
    XCTAssertEqual([registry progressForURL:track], -1);
    [registry removeObserver:self];
}

// A file re-uploaded since its listing downloads at its new size; the row
// counts against that, never the placeholder's.
- (void)testARowCountsAgainstTheSizeBeingDownloaded {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = [self rowWAV:16 * chunk];
    NSURL *track = [self openRowTrack:bytes listed:8 * chunk chunk:chunk];
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    XCTAssertTrue([self eventually:^BOOL { return [registry isTransferringURL:track]; }]);
    [self releaseChunks:4];
    XCTAssertTrue([self row:track showsWritten:4 * chunk of:bytes.length],
                  @"%.3f against the listed size", [registry progressForURL:track]);
    [self releaseChunks:100];
    XCTAssertTrue([self eventually:^BOOL { return ![registry isTransferringURL:track]; }]);
}

@end
