//
//  AudioFileHandleStreamingTests.m
//
//  AudioFileHandle over a file still being written: a part file grown from
//  byte 0 behind a CloudFileAvailability, the reader waiting at its edge and
//  the test writing in step with it, so nothing here sleeps to synchronize.
//  Each decoder's PCM is compared exactly with its own decode of the whole
//  file, through every wait, failure and interruption.
//

#import "AudioFileHandleStreamingTestCase.h"

#pragma mark - A file written in step with its reader

// Reports each wait as it is about to block, once, with the end it waits
// for, and the furthest range asked.
@interface VibeSteppedAvailability : CloudFileAvailability
@property (atomic, copy, nullable) void (^willBlock)(uint64_t end);
@property (atomic, readonly) uint64_t furthestOffsetAsked;
@end

@implementation VibeSteppedAvailability {
    os_unfair_lock _lock;
    uint64_t _furthestOffsetAsked;
}

- (uint64_t)furthestOffsetAsked {
    os_unfair_lock_lock(&_lock);
    uint64_t offset = _furthestOffsetAsked;
    os_unfair_lock_unlock(&_lock);
    return offset;
}

- (CloudFileAvailabilityWait)waitForBytesAt:(uint64_t)offset
                                     length:(uint64_t)length
                                 windowInto:(void *)buffer
                                   capacity:(uint64_t)capacity
                                     copied:(uint64_t *)copied
                                interrupted:(BOOL (NS_NOESCAPE ^)(void))interrupted
                                   deadline:(NSDate *)deadline
                                      error:(NSError *__autoreleasing *)error {
    uint64_t end = offset >= self.size || length == 0 ? 0 : offset + MIN(length, self.size - offset);
    os_unfair_lock_lock(&_lock);
    _furthestOffsetAsked = MAX(_furthestOffsetAsked, offset);
    os_unfair_lock_unlock(&_lock);
    void (^willBlock)(uint64_t) = self.willBlock;
    __block BOOL reported = NO;
    // The interrupt is asked exactly when the wait would block.
    return [super waitForBytesAt:offset length:length windowInto:buffer capacity:capacity copied:copied
                     interrupted:^BOOL{
        if (interrupted && interrupted()) {
            return YES;
        }
        if (!reported && willBlock) {
            reported = YES;
            willBlock(end);
        }
        return NO;
    } deadline:deadline error:error];
}

@end

// A download's part file: `bytes` appended to it from byte 0 as the test
// says, renamed over `url` when complete; with a window, the file's last
// `window` bytes installed as the tail window at the start, as the mirror's
// tail read does.
@interface VibeGrowingFile : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) NSData *bytes;
@property (nonatomic, readonly) VibeSteppedAvailability *availability;
@property (atomic, readonly) uint64_t written;
// Where the window starts; the size when there is none.
@property (nonatomic, readonly) uint64_t windowOffset;
// Signalled each time the reader is about to wait, and once it is done.
@property (nonatomic, readonly) dispatch_semaphore_t event;
@property (atomic) uint64_t blockedEnd;
@property (atomic) BOOL readerDone;
@end

@implementation VibeGrowingFile

- (instancetype)initWithBytes:(NSData *)bytes url:(NSURL *)url prefix:(uint64_t)prefix window:(uint64_t)window {
    self = [super init];
    if (self) {
        _bytes = bytes;
        _url = url;
        _event = dispatch_semaphore_create(0);
        NSURL *part = [url.URLByDeletingLastPathComponent
                URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.part", url.lastPathComponent]];
        [NSData.data writeToURL:part atomically:NO];
        _availability = [[VibeSteppedAvailability alloc] initWithPartURL:part size:bytes.length];
        __weak VibeGrowingFile *weakSelf = self;
        _availability.willBlock = ^(uint64_t end) {
            VibeGrowingFile *file = weakSelf;
            file.blockedEnd = end;
            dispatch_semaphore_signal(file.event);
        };
        [self writeTo:prefix];
        _windowOffset = bytes.length - MIN(window, (uint64_t)bytes.length);
        if (window) {
            [_availability installWindow:[bytes subdataWithRange:NSMakeRange((NSUInteger)_windowOffset,
                                                                             (NSUInteger)(bytes.length - _windowOffset))]
                                atOffset:_windowOffset];
        }
    }
    return self;
}

- (void)writeTo:(uint64_t)end {
    end = MIN(end, (uint64_t)_bytes.length);
    uint64_t written = self.written;
    if (end <= written) {
        return;
    }
    NSFileHandle *part = [NSFileHandle fileHandleForWritingToURL:_availability.partURL error:NULL];
    [part seekToEndOfFile];
    [part writeData:[_bytes subdataWithRange:NSMakeRange((NSUInteger)written, (NSUInteger)(end - written))]];
    [part closeFile];
    _written = end;
    [_availability noteWrittenBytes:end];
}

// What the mirror's install does: the last bytes, the rename, then the finish.
- (void)complete {
    [self writeTo:_bytes.length];
    rename(_availability.partURL.fileSystemRepresentation, _url.fileSystemRepresentation);
    [_availability finishWithError:nil];
}

@end

// What a test's remote fetch was told, once.
enum { VibeFetchRunning = 0, VibeFetchCompleted, VibeFetchFailed, VibeFetchCancelled };

@interface AudioFileHandleStreamingTests : AudioFileHandleStreamingTestCase
@end

@implementation AudioFileHandleStreamingTests {
    // Through the coordinator: what the test decided.
    dispatch_semaphore_t _fetchVerdict;
    _Atomic int _fetchOutcome;
    _Atomic NSUInteger _fetchCancels;
    NSError *_fetchFailure;
    VibeGrowingFile *_remote;
    AudioFileMaterializationCoordinator *_coordinator;
}

- (void)tearDown {
    if (_coordinator) {
        [self finishRemote:VibeFetchCancelled];
        [self assertCoordinatorSettles];
    }
    [super tearDown];
}

// The source's bytes, streaming under a name of their own with `prefix` of
// them written.
- (VibeGrowingFile *)stream:(NSURL *)source prefix:(uint64_t)prefix {
    return [self stream:source prefix:prefix window:0];
}

- (VibeGrowingFile *)stream:(NSURL *)source prefix:(uint64_t)prefix window:(uint64_t)window {
    NSURL *url = [_directory URLByAppendingPathComponent:source.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    VibeGrowingFile *file = [[VibeGrowingFile alloc] initWithBytes:[NSData dataWithContentsOfURL:source] url:url
                                                            prefix:prefix window:window];
    os_unfair_lock_lock(&_streamsLock);
    _streams[url.path] = file.availability;
    os_unfair_lock_unlock(&_streamsLock);
    return file;
}

// Runs `reader` on a worker, the file's event signalled once it is done.
- (void)start:(VibeGrowingFile *)file reader:(dispatch_block_t)reader {
    file.readerDone = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        reader();
        file.readerDone = YES;
        dispatch_semaphore_signal(file.event);
    });
}

// Runs `reader` on a worker while this thread writes `file` on in step with
// it: each time the reader is about to wait, up to the end it waits for and
// `step` bytes past it. Answers how many times it waited.
- (NSUInteger)drive:(VibeGrowingFile *)file step:(uint64_t)step reader:(dispatch_block_t)reader {
    [self start:file reader:reader];
    NSUInteger waits = 0;
    for (;;) {
        if (dispatch_semaphore_wait(file.event, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) != 0) {
            XCTFail(@"%@: the reader neither waited nor finished; written %llu of %lu", file.url.lastPathComponent,
                    file.written, (unsigned long)file.bytes.length);
            [file complete];
            return waits;
        }
        if (file.readerDone) {
            return waits;
        }
        waits++;
        [file writeTo:file.blockedEnd + step];
    }
}

// The next event from the reader on `file`: a wait, or its end.
- (BOOL)awaitEvent:(VibeGrowingFile *)file {
    BOOL signalled = dispatch_semaphore_wait(file.event, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
    XCTAssertTrue(signalled, @"%@: the reader neither waited nor finished", file.url.lastPathComponent);
    return signalled;
}

// The next event, which must be a wait rather than the reader's end.
- (BOOL)awaitBlock:(VibeGrowingFile *)file {
    BOOL blocked = [self awaitEvent:file] && !file.readerDone;
    XCTAssertTrue(blocked, @"%@: the reader was to wait", file.url.lastPathComponent);
    return blocked;
}

#pragma mark - Decoding while the bytes arrive

// The open and every read wait at the edge, the fills come up short of their
// blocks there, and the PCM is the whole file's. A one-byte step ends every
// fill just past what it was asked for, the block cache's worst case. An MP3
// open reads its last bytes, so a tail window serves them here (the next
// test is the open without one), and the download reaching it drops it.
- (void)testAGrowingFileDecodesExactlyAsTheWholeFile {
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        NSData *reference = [self referenceOf:source from:0 frames:INT64_MAX];
        for (NSNumber *step in @[@1, @7919]) {
            for (NSNumber *chunk in @[@333, @4096]) {
                NSString *context = [NSString stringWithFormat:@"%@, step %@, chunk %@", source.lastPathComponent, step, chunk];
                VibeGrowingFile *file = [self stream:source prefix:100
                                              window:[source.pathExtension isEqualToString:@"mp3"] ? 128 : 0];
                __block NSData *pcm = nil;
                __block NSString *decoder = nil;
                __block NSError *error = nil;
                NSUInteger waits = [self drive:file step:step.unsignedLongLongValue reader:^{
                    NSError *readError = nil;
                    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:file.url error:&readError];
                    decoder = handle.decoderName;
                    pcm = handle ? VibeDecode(handle, chunk.unsignedIntValue, INT64_MAX, &readError) : nil;
                    error = readError;
                }];
                XCTAssertNotNil(pcm, @"%@: %@", context, error);
                XCTAssertEqualObjects(decoder, fixtures[source], @"%@", context);
                XCTAssertGreaterThan(waits, 3u, @"%@: the reader waited at the edge", context);
                [self assertPCM:pcm equals:reference context:context];
            }
        }
    }
}

// The head-only formats open on their head alone. AIFF also reads at exactly
// the file's size, which is the end, never a wait. A hang here is a
// wait the open should not have made.
- (void)testAHeadOnlyFormatOpensOnItsHeadAlone {
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        if ([source.pathExtension isEqualToString:@"mp3"]) {
            continue;
        }
        VibeGrowingFile *file = [self stream:source prefix:64 * 1024];
        __block AudioFileHandle *handle = nil;
        NSUInteger waits = [self drive:file step:0 reader:^{
            handle = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
        }];
        XCTAssertEqual(waits, 0u, @"%@ waited to open", source.lastPathComponent);
        XCTAssertNotNil(handle, @"%@", source.lastPathComponent);
        if ([source.pathExtension isEqualToString:@"aif"]) {
            XCTAssertGreaterThanOrEqual(file.availability.furthestOffsetAsked, (uint64_t)file.bytes.length,
                                        @"the AIFF open read at its end without waiting");
        }
        XCTAssertEqual(handle.length, [self openWhole:source].length, @"%@", source.lastPathComponent);
    }
}

// Every MP3 open reads its last bytes (an ID3v1 check), so on a prefix with no
// tail window it waits for the tail, and opens once the file is complete.
- (void)testAnMP3OpenWaitsForTheTailThenOpensWhenTheFileCompletes {
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        if (![source.pathExtension isEqualToString:@"mp3"]) {
            continue;
        }
        VibeGrowingFile *file = [self stream:source prefix:(uint64_t)([NSData dataWithContentsOfURL:source].length * 9 / 10)];
        XCTestExpectation *opened = [self expectationWithDescription:@"opened"];
        __block AudioFileHandle *handle = nil;
        __block NSError *error = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *openError = nil;
            handle = [[AudioFileHandle alloc] initForReading:file.url error:&openError];
            error = openError;
            [opened fulfill];
        });
        if (![self awaitBlock:file]) {
            [file complete];
            [self waitForExpectations:@[opened] timeout:VIBE_TEST_HANG_TIMEOUT];
            continue;
        }
        XCTAssertGreaterThan(file.blockedEnd, (uint64_t)file.bytes.length - 128, @"%@: the open's wait is for the tail",
                             source.lastPathComponent);
        XCTAssertNil(handle, @"%@ opened before its tail arrived", source.lastPathComponent);
        [file complete];
        [self waitForExpectations:@[opened] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertNotNil(handle, @"%@: %@", source.lastPathComponent, error);
        NSData *pcm = VibeDecode(handle, 4096, INT64_MAX, &error);
        [self assertPCM:pcm equals:[self referenceOf:source from:0 frames:INT64_MAX] context:source.lastPathComponent];
    }
}

#pragma mark - The tail window

// With the tail window, every open that reads past its head opens on its head
// and the window, never waiting for the download. Those are an MP3 (its ID3v1
// check), an M4A with its moov last and a FLAC with no length. Each one's
// first second decodes with the download still short of the end. The whole
// decode is the whole file's. The download reaching the window drops it. The
// WAV's open never asks the window. An MP3 with no VBR header opens on them
// too, on an estimate from its head's frames, which for a constant rate is the
// length that rate gives, and which reading to its end settles.
- (void)testATailReadingOpenOpensOnItsHeadAndTheWindow {
    const uint64_t head = 64 * 1024, window = 80 * 1024;
    NSDictionary<NSURL *, NSString *> *fixtures = [self tailFixtures];
    for (NSURL *source in fixtures) {
        NSString *name = source.lastPathComponent;
        VibeGrowingFile *file = [self stream:source prefix:head window:window];
        XCTAssertGreaterThan(file.windowOffset, head, @"%@: bytes between the head and the window", name);
        XCTAssertEqual(file.availability.windowLength, window, @"%@", name);
        __block AudioFileHandle *opened = nil;
        __block NSError *error = nil;
        NSUInteger waits = [self drive:file step:0 reader:^{
            NSError *openError = nil;
            opened = [[AudioFileHandle alloc] initForReading:file.url error:&openError];
            error = openError;
        }];
        AudioFileHandle *handle = opened;
        XCTAssertNotNil(handle, @"%@: %@", name, error);
        XCTAssertEqualObjects(handle.decoderName, fixtures[source], @"%@", name);
        XCTAssertEqual(waits, 0u, @"%@ waited to open", name);
        if ([name hasSuffix:@"wav"]) {
            XCTAssertLessThan(file.availability.furthestOffsetAsked, file.windowOffset, @"%@ read its tail", name);
        }
        else {
            XCTAssertGreaterThanOrEqual(file.availability.furthestOffsetAsked, file.windowOffset,
                                        @"%@: the open read the window", name);
        }
        if (!handle) {
            continue;
        }
        AVAudioFramePosition length = [self openWhole:source].length;
        BOOL variable = [name hasPrefix:@"unheadered-"] && [name containsString:@"vbr"];
        XCTAssertEqual(handle.lengthIsEstimated, [name hasPrefix:@"unheadered"], @"%@", name);
        if (variable) {
            XCTAssertEqualWithAccuracy((double)handle.length, (double)length, length * 0.1, @"%@", name);
        }
        else {
            XCTAssertEqual(handle.length, length, @"%@", name);
        }

        __block NSData *first = nil;
        __block NSError *readError = nil;
        [self drive:file step:4096 reader:^{
            NSError *failure = nil;
            first = VibeDecode(handle, 4096, 44100, &failure);
            readError = failure;
        }];
        XCTAssertNotNil(first, @"%@: %@", name, readError);
        XCTAssertLessThan(file.written, (uint64_t)file.bytes.length, @"%@: a second decoded before the download ended", name);
        [self assertPCM:first equals:[self referenceOf:source from:0 frames:44100]
                context:[name stringByAppendingString:@", first second"]];

        __block NSData *rest = nil;
        [self drive:file step:7919 reader:^{
            NSError *failure = nil;
            rest = VibeDecode(handle, 4096, INT64_MAX, &failure);
            readError = failure;
        }];
        XCTAssertNotNil(rest, @"%@: %@", name, readError);
        XCTAssertEqual(file.availability.windowLength, 0u, @"%@: the download reached the window and dropped it", name);
        NSMutableData *whole = [first mutableCopy];
        [whole appendData:rest ?: NSData.data];
        [self assertPCM:whole equals:[self referenceOf:source from:0 frames:INT64_MAX] context:name];
        XCTAssertFalse(handle.lengthIsEstimated, @"%@", name);
        XCTAssertEqual(handle.length, length, @"%@", name);
    }
}

// An AIFF of 16-bit stereo at 44.1 kHz, `le16` byte-swapped into its SSND.
static NSData *VibeAIFF(NSData *le16, uint32_t frames) {
    NSMutableData *aiff = [NSMutableData data];
    void (^be32)(uint32_t) = ^(uint32_t v) { uint32_t b = CFSwapInt32HostToBig(v); [aiff appendBytes:&b length:4]; };
    void (^be16)(uint16_t) = ^(uint16_t v) { uint16_t b = CFSwapInt16HostToBig(v); [aiff appendBytes:&b length:2]; };
    [aiff appendBytes:"FORM" length:4];
    be32(0);
    [aiff appendBytes:"AIFFCOMM" length:8];
    be32(18);
    be16(2);
    be32(frames);
    be16(16);
    const uint8_t rate[10] = {0x40, 0x0E, 0xAC, 0x44}; // 44100 as an 80-bit float
    [aiff appendBytes:rate length:10];
    [aiff appendBytes:"SSND" length:4];
    be32((uint32_t)le16.length + 8);
    be32(0);
    be32(0);
    NSMutableData *samples = [le16 mutableCopy];
    uint16_t *s = samples.mutableBytes;
    for (NSUInteger i = 0; i < samples.length / 2; i++) {
        s[i] = CFSwapInt16(s[i]);
    }
    [aiff appendData:samples];
    uint32_t form = CFSwapInt32HostToBig((uint32_t)aiff.length - 8);
    [aiff replaceBytesInRange:NSMakeRange(4, 4) withBytes:&form];
    return aiff;
}

// `file` with a tag of `length` bytes in a chunk after its audio, as a tag
// with its cover sits after an AIFF's SSND or a WAV's data, and the
// container's own size moved to count it. The tag is an ID3v2 one of padding.
static NSData *VibeWithTrailingTag(NSData *file, NSString *extension, uint32_t length) {
    NSMutableData *bytes = [file mutableCopy];
    NSMutableData *tag = [NSMutableData dataWithLength:length];
    uint8_t *t = tag.mutableBytes;
    memcpy(t, "ID3\x04\x00\x00", 6);
    uint32_t payload = length - 10;
    t[6] = (payload >> 21) & 0x7F; t[7] = (payload >> 14) & 0x7F; t[8] = (payload >> 7) & 0x7F; t[9] = payload & 0x7F;
    if ([extension isEqualToString:@"w64"]) {
        // The 'junk' GUID, a 64-bit size counting its 24-byte header, and the
        // riff's own 64-bit size at 16.
        static const uint8_t junk[16] = {'j', 'u', 'n', 'k', 0xF3, 0xAC, 0xD3, 0x11,
                                         0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A};
        [bytes increaseLengthBy:(8 - bytes.length % 8) % 8];
        [bytes appendBytes:junk length:16];
        uint64_t size = OSSwapHostToLittleInt64(24 + (uint64_t)length);
        [bytes appendBytes:&size length:8];
        [bytes appendData:tag];
        uint64_t riff = OSSwapHostToLittleInt64(bytes.length);
        [bytes replaceBytesInRange:NSMakeRange(16, 8) withBytes:&riff];
        return bytes;
    }
    if ([extension isEqualToString:@"caf"]) {
        // CAF's sizes are 64-bit and big-endian; the file counts none.
        uint64_t size = OSSwapHostToBigInt64(length);
        [bytes appendBytes:"info" length:4];
        [bytes appendBytes:&size length:8];
        [bytes appendData:tag];
        return bytes;
    }
    BOOL aiff = [extension hasPrefix:@"aif"];
    uint32_t size = aiff ? CFSwapInt32HostToBig(length) : OSSwapHostToLittleInt32(length);
    [bytes appendBytes:aiff ? "ID3 " : "id3 " length:4];
    [bytes appendBytes:&size length:4];
    [bytes appendData:tag];
    uint32_t outer = (uint32_t)bytes.length - 8;
    outer = aiff ? CFSwapInt32HostToBig(outer) : OSSwapHostToLittleInt32(outer);
    [bytes replaceBytesInRange:NSMakeRange(4, 4) withBytes:&outer];
    return bytes;
}

// A chunk after the audio, a 235 KB tag as a Dropbox AIFF carried, is past
// the small window. An AIFF's open and a CAF's walk to that chunk's header.
// On the small window they wait for the download. A WAV's and a W64's stop
// at the data chunk, so they never wait. On the window its format takes, each
// opens on its head and the window with no wait. The stream then decodes as
// the whole file.
- (void)testAChunkAfterTheAudioOpensFromTheWindow {
    const uint32_t frames = 441000, tag = 235 * 1024;
    const uint64_t head = 64 * 1024, small = 128 * 1024;
    NSData *samples = VibeNoiseSamples(frames, 2);
    NSError *error = nil;
    NSURL *wav = VibeWriteWAV([self sourceNamed:@"plain.wav"], samples, 44100, 2, 16, (uint32_t)samples.length);
    NSURL *w64 = VibeWriteFixture([self sourceNamed:@"plain.w64"], VibeNoiseBuffer(frames), &error);
    NSURL *caf = VibeWriteFixture([self sourceNamed:@"plain.caf"], VibeNoiseBuffer(frames), &error);
    XCTAssertNil(error);
    NSDictionary<NSString *, NSData *> *plain = @{
        @"aiff": VibeAIFF(samples, frames),
        @"wav": [NSData dataWithContentsOfURL:wav],
        @"w64": [NSData dataWithContentsOfURL:w64],
        @"caf": [NSData dataWithContentsOfURL:caf],
    };
    for (NSString *extension in plain) {
        NSURL *source = [self sourceNamed:[@"tagged." stringByAppendingString:extension]];
        XCTAssertTrue([VibeWithTrailingTag(plain[extension], extension, tag) writeToURL:source atomically:YES], @"%@", extension);
        uint64_t size = [NSData dataWithContentsOfURL:source].length;
        uint64_t window = VibeAudioFileTailWindowBytes(extension, size);
        XCTAssertGreaterThan(window, (uint64_t)tag + 24, @"%@", extension);
        BOOL walksToTheEnd = [@[@"aiff", @"caf"] containsObject:extension];

        VibeGrowingFile *cramped = [self stream:source prefix:head window:small];
        NSUInteger waits = [self drive:cramped step:0 reader:^{
            XCTAssertNotNil([[AudioFileHandle alloc] initForReading:cramped.url error:NULL], @"%@", extension);
        }];
        if (walksToTheEnd) {
            XCTAssertGreaterThan(waits, 0u, @"%@: the small window left the chunk's header to the download", extension);
        } else {
            XCTAssertEqual(waits, 0u, @"%@: dr_wav stops at the data chunk", extension);
        }
        [cramped complete];

        VibeGrowingFile *file = [self stream:source prefix:head window:window];
        __block AudioFileHandle *handle = nil;
        waits = [self drive:file step:0 reader:^{
            handle = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
        }];
        XCTAssertNotNil(handle, @"%@", extension);
        XCTAssertEqual(waits, 0u, @"%@ waited to open", extension);
        if (walksToTheEnd) {
            XCTAssertGreaterThanOrEqual(file.availability.furthestOffsetAsked, file.windowOffset, @"%@: the open read the window",
                                        extension);
        }
        __block NSData *pcm = nil;
        [self drive:file step:7919 reader:^{
            pcm = VibeDecode(handle, 4096, INT64_MAX, NULL);
        }];
        XCTAssertEqual(file.availability.windowLength, 0u, @"%@: the download reached the window and dropped it", extension);
        [self assertPCM:pcm equals:[self referenceOf:source from:0 frames:INT64_MAX] context:extension];
    }
}

// An MP3 stream with no VBR header, whose frames are a byte short of its
// rate's, so its rate counts two packets fewer than it holds: an estimate,
// constant rate or not; read as the bus reads, ending at a short read or a
// cursor at the length, it plays to the end of its stream, not the estimate,
// and its length is then the whole file's, exact.
- (void)testAnUncountedMP3StreamPlaysPastAShortEstimateAndSettlesItsLength {
    NSURL *source = [self sourceNamed:@"short-estimate.mp3"];
    XCTAssertTrue([VibeWithoutVBRHeader(VibeMP3WithInfoFrame(2000, NO)) writeToURL:source atomically:YES]);
    AudioFileHandle *whole = [self openWhole:source];
    VibeGrowingFile *file = [self stream:source prefix:64 * 1024 window:80 * 1024];
    __block AudioFileHandle *handle = nil;
    __block AVAudioFramePosition estimate = 0, end = 0;
    __block BOOL estimated = NO;
    [self drive:file step:7919 reader:^{
        handle = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
        estimate = handle.length;
        estimated = handle.lengthIsEstimated;
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
        while ([handle readIntoBuffer:buffer error:NULL] && buffer.frameLength == 4096 && handle.framePosition < handle.length) {
        }
        end = handle.framePosition;
    }];
    XCTAssertEqual(estimate, whole.length - 2 * 1152, @"the estimate is short");
    XCTAssertTrue(estimated, @"a constant rate's count is an estimate too");
    XCTAssertEqual(end, whole.length, @"read to the stream's end");
    XCTAssertFalse(handle.lengthIsEstimated);
    XCTAssertEqual(handle.length, whole.length, @"settled there");
}

// A headerless MP3 whose head is one rate and the rest another, 320 kbps for
// its first 80 frames and 128 after: a stream opening inside its head walks
// one rate, whose count is far short of the file's, and is an estimate all
// the same, since a head proves nothing of the rest. awaitExactLength: waits
// for the download and counts it, and the whole stream then reads as the
// whole file, to its true end.
- (void)testAConstantRateHeadOpensOnAnEstimate {
    NSURL *source = [self sourceNamed:@"constant-head.mp3"];
    XCTAssertTrue([VibeMP3WithoutVBRHeader(2000, 44100, ^uint8_t(uint32_t frame) { return frame < 80 ? 14 : 9; })
                   writeToURL:source atomically:YES]);
    AudioFileHandle *whole = [self openWhole:source];
    NSData *reference = [self referenceOf:source from:0 frames:INT64_MAX];
    VibeGrowingFile *file = [self stream:source prefix:64 * 1024 window:80 * 1024];
    __block AudioFileHandle *handle = nil;
    NSUInteger waits = [self drive:file step:0 reader:^{
        handle = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
    }];
    XCTAssertEqual(waits, 0u, @"opened inside the head");
    XCTAssertTrue(handle.lengthIsEstimated, @"a constant head is no proof of the rest");
    XCTAssertLessThan(handle.length, whole.length / 2);
    [file complete];
    XCTAssertTrue([handle awaitExactLength:NULL]);
    XCTAssertFalse(handle.lengthIsEstimated);
    XCTAssertEqual(handle.length, whole.length);
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, NULL) equals:reference context:@"the whole stream"];
}

// An open that must never wait for a download — the metadata parse's
// fallback for a file TagLib refuses (W64, CAF, ADTS), whose facts come once
// the file is on disk, as they did when the placeholder refused the open —
// passes an `interrupted` that answers YES, and fails at once where it would
// have blocked, so no metadata worker is held for the rest of a transfer.
- (void)testAnOpenThatNeverWaitsFailsAtOnceWhereItWouldBlock {
    NSError *error = nil;
    NSURL *source = VibeWriteFixture([self sourceNamed:@"facts.w64"], VibeNoiseBuffer(88200), &error);
    XCTAssertNil(error);
    VibeGrowingFile *file = [self stream:source prefix:40];
    __block AudioFileHandle *handle = nil;
    __block NSError *openError = nil;
    NSUInteger waits = [self drive:file step:0 reader:^{
        handle = [[AudioFileHandle alloc] initParserForReading:file.url interrupted:^BOOL { return YES; } error:&openError];
    }];
    XCTAssertEqual(waits, 0u, @"refused where it would have waited");
    XCTAssertNil(handle);
    XCTAssertTrue([AudioFileHandle isInterruption:openError], @"%@", openError);
    [file complete];
    handle = [[AudioFileHandle alloc] initParserForReading:file.url interrupted:^BOOL { return YES; } error:&openError];
    XCTAssertNotNil(handle, @"on disk, nothing waits: %@", openError);
}

// A headerless MP3 whose ID3v2 tag, cover art's, reaches past the readable
// edge still opens on an estimate: the head walk waits for its frames as a
// read does, rather than finding none on disk and handing the open to the
// parser's whole-file count, which waits for the entire download.
- (void)testAHeadBehindALargeTagStillOpensOnAnEstimate {
    NSURL *source = [self sourceNamed:@"tagged-head.mp3"];
    const uint32_t tagBytes = 300 * 1024;
    NSMutableData *data = [NSMutableData dataWithLength:tagBytes];
    uint8_t *tag = data.mutableBytes;
    memcpy(tag, "ID3\x04\x00\x00", 6);
    uint32_t payload = tagBytes - 10;
    tag[6] = (payload >> 21) & 0x7F; tag[7] = (payload >> 14) & 0x7F; tag[8] = (payload >> 7) & 0x7F; tag[9] = payload & 0x7F;
    [data appendData:VibeMP3WithoutVBRHeader(2000, 44100, ^uint8_t(uint32_t frame) { return 14; })];
    XCTAssertTrue([data writeToURL:source atomically:YES]);
    AudioFileHandle *whole = [self openWhole:source];
    // The download is just past the tag when the open runs, and each wait
    // lands 8 KB more: a few frames, not the sixteen the walk needs.
    VibeGrowingFile *file = [self stream:source prefix:tagBytes + 2048 window:80 * 1024];
    __block AudioFileHandle *handle = nil;
    NSUInteger waits = [self drive:file step:8 * 1024 reader:^{
        handle = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
    }];
    XCTAssertNotNil(handle);
    XCTAssertLessThanOrEqual(waits, 8u, @"waited for the head's frames, not the whole file");
    XCTAssertLessThan(file.written, (uint64_t)data.length, @"opened before the download ended");
    XCTAssertTrue(handle.lengthIsEstimated, @"estimated from the head behind the tag");
    [file complete];
    XCTAssertTrue([handle awaitExactLength:NULL]);
    XCTAssertEqual(handle.length, whole.length);
}

// A VBR MP3 stream with no VBR header opens on its head and the tail window
// without waiting, its length estimated from its head's frames, within 2% for
// one whose rate varies evenly; a seek inside what has arrived lands exactly
// while the length is still a guess; the first read once the download is
// complete counts it from disk, with the decode parked early in the file; and
// it then reads and seeks as the whole file.
- (void)testAVBRMP3StreamOpensOnAnEstimateAndSettlesOnceDownloaded {
    NSURL *source = [self sourceNamed:@"even.mp3"];
    static const uint8_t cycle[5] = {9, 14, 11, 5, 13};
    XCTAssertTrue([VibeMP3WithoutVBRHeader(2000, 44100, ^uint8_t(uint32_t frame) { return cycle[frame % 5]; })
                   writeToURL:source atomically:YES]);
    AudioFileHandle *whole = [self openWhole:source];
    NSData *reference = [self referenceOf:source from:0 frames:INT64_MAX];
    VibeGrowingFile *file = [self stream:source prefix:64 * 1024 window:80 * 1024];
    __block AudioFileHandle *handle = nil;
    __block NSData *early = nil;
    NSUInteger waits = [self drive:file step:0 reader:^{
        handle = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
        early = [handle seekToFrame:44100 error:NULL] ? VibeDecode(handle, 4096, 4096, NULL) : nil;
    }];
    XCTAssertEqual(waits, 0u, @"opened and read inside the head");
    XCTAssertTrue(handle.lengthIsEstimated);
    XCTAssertEqualWithAccuracy((double)handle.length, (double)whole.length, whole.length * 0.02);
    [self assertPCM:early equals:[reference subdataWithRange:NSMakeRange(44100 * 8, 4096 * 8)] context:@"a seek before the settle"];
    XCTAssertTrue(handle.lengthIsEstimated, @"no read counts while the download runs");

    [file complete];
    NSData *next = VibeDecode(handle, 4096, 4096, NULL);
    [self assertPCM:next equals:[reference subdataWithRange:NSMakeRange((44100 + 4096) * 8, 4096 * 8)] context:@"after the settle"];
    XCTAssertFalse(handle.lengthIsEstimated);
    XCTAssertEqual(handle.length, whole.length);
    AVAudioFramePosition at = whole.length - 3000;
    XCTAssertTrue([handle seekToFrame:at error:NULL]);
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, NULL)
             equals:[reference subdataWithRange:NSMakeRange((NSUInteger)at * 8, 3000 * 8)] context:@"a seek after the settle"];
    XCTAssertTrue([handle seekToFrame:0 error:NULL]);
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, NULL) equals:reference context:@"the whole stream"];
}

// A VBR stream whose head is denser than the rest, so an estimate short of
// its length, and one whose head is sparser, long of it, each read as the bus
// reads, ending at a short read or a cursor at the length, while its download
// proceeds: each reads to its stream's true end, past the short estimate and
// short of the long one, its PCM the whole file's, and its length settles there.
- (void)testAnEstimatedMP3StreamReadsToItsTrueEndShortOrLongOfTheEstimate {
    NSDictionary<NSString *, uint8_t (^)(uint32_t)> *heads = @{
        @"dense-head.mp3": ^uint8_t(uint32_t frame) { return frame < 60 ? 13 + frame % 2 : 1 + frame % 2; },
        @"sparse-head.mp3": ^uint8_t(uint32_t frame) { return frame < 600 ? 1 + frame % 2 : 13 + frame % 2; },
    };
    for (NSString *name in heads) {
        NSURL *source = [self sourceNamed:name];
        XCTAssertTrue([VibeMP3WithoutVBRHeader(2000, 44100, heads[name]) writeToURL:source atomically:YES]);
        AudioFileHandle *whole = [self openWhole:source];
        VibeGrowingFile *file = [self stream:source prefix:64 * 1024 window:80 * 1024];
        __block AudioFileHandle *handle = nil;
        __block AVAudioFramePosition estimate = 0;
        __block NSMutableData *pcm = [NSMutableData data];
        [self drive:file step:7919 reader:^{
            handle = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
            estimate = handle.length;
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
            while ([handle readIntoBuffer:buffer error:NULL] && buffer.frameLength > 0) {
                VibeAppendPCM(pcm, buffer);
                if (buffer.frameLength < 4096 || handle.framePosition >= handle.length) {
                    break;
                }
            }
        }];
        BOOL dense = [name hasPrefix:@"dense"];
        XCTAssertTrue(dense ? estimate < whole.length / 2 : estimate > whole.length * 2, @"%@: %lld of %lld", name,
                      estimate, whole.length);
        [self assertPCM:pcm equals:[self referenceOf:source from:0 frames:INT64_MAX] context:name];
        XCTAssertFalse(handle.lengthIsEstimated, @"%@", name);
        XCTAssertEqual(handle.length, whole.length, @"%@ settled at its end", name);
    }
}

#pragma mark - Failure

- (void)testAFailedTransferFailsTheBlockedReadWithItsError {
    NSError *transferError = [NSError errorWithDomain:@"com.vibe.test-transfer" code:7 userInfo:nil];
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        NSString *name = source.lastPathComponent;
        VibeGrowingFile *file = [self stream:source prefix:100 window:[name hasSuffix:@"mp3"] ? 128 : 0];
        __block AudioFileHandle *handle = nil;
        __block BOOL failed = NO;
        __block NSError *error = nil;
        XCTestExpectation *returned = [self expectationWithDescription:@"read returned"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *readError = nil;
            AudioFileHandle *opened = [[AudioFileHandle alloc] initForReading:file.url error:&readError];
            failed = opened && !VibeDecode(opened, 4096, INT64_MAX, &readError);
            handle = opened;
            error = readError;
            [returned fulfill];
        });
        // Let the open and some reads through, then fail the transfer under
        // a blocked read.
        BOOL blocked = YES;
        while (blocked && file.written < file.bytes.length / 2) {
            blocked = [self awaitBlock:file];
            [file writeTo:file.blockedEnd + 4000];
        }
        if (blocked) {
            blocked = [self awaitBlock:file];
        }
        [file.availability finishWithError:transferError];
        [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertTrue(failed, @"%@: the read failed", name);
        XCTAssertEqualObjects(error, transferError, @"%@", name);
        XCTAssertFalse([AudioFileHandle isInterruption:error], @"%@", name);
        if (handle) {
            NSError *again = nil;
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
            XCTAssertFalse([handle readIntoBuffer:buffer error:&again], @"%@: still failed, not ended", name);
            XCTAssertEqualObjects(again, transferError, @"%@", name);
        }
    }
}

#pragma mark - Interruption

// An interrupted read is neither the end nor a failure. After allowReads, a
// seek puts every decoder where it says, whatever state the lost read left
// it in: a seek to where the decoder says it was left (which dr_flac would
// skip), one back inside the frame it held (which dr_flac moves in without
// reading), one ahead, and the start, each after a lost read of its own. The
// file keeps growing all the while.
- (void)testAnInterruptedReadNeitherEndsNorFailsAndASeekRecoversExactly {
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        NSString *name = source.lastPathComponent;
        // An MP3's open reads its last bytes, which only a tail window
        // serves before the download reaches them.
        VibeGrowingFile *file = [self stream:source prefix:100 window:[name hasSuffix:@"mp3"] ? 128 : 0];
        __block AudioFileHandle *opened = nil;
        [self drive:file step:1000 reader:^{
            opened = [[AudioFileHandle alloc] initForReading:file.url error:NULL];
        }];
        AudioFileHandle *handle = opened;
        XCTAssertNotNil(handle, @"%@", name);
        if (!handle) {
            continue;
        }
        __block NSData *before = nil;
        __block NSError *error = nil;
        [self start:file reader:^{
            NSError *readError = nil;
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:1000];
            NSMutableData *pcm = [NSMutableData data];
            while ([handle readIntoBuffer:buffer frameCount:1000 error:&readError] && buffer.frameLength > 0) {
                VibeAppendPCM(pcm, buffer);
            }
            before = pcm;
            error = readError;
        }];
        // Three waits served, the fourth interrupted. A file whose open
        // read it all (a CBR MP3 is scanned to its end) has none to give.
        NSUInteger waits = 0;
        while ([self awaitEvent:file] && !file.readerDone && ++waits < 4) {
            [file writeTo:file.blockedEnd + 3001];
        }
        if (file.readerDone) {
            XCTAssertNil(error, @"%@", name);
            [self assertPCM:before equals:[self referenceOf:source from:0 frames:INT64_MAX] context:name];
            continue;
        }
        [handle interruptReads];
        XCTAssertTrue([self awaitEvent:file] && file.readerDone, @"%@: the interrupted read returned", name);
        XCTAssertTrue([AudioFileHandle isInterruption:error], @"%@: %@", name, error);
        AVAudioFramePosition reached = (AVAudioFramePosition)(before.length / sizeof(float) / handle.processingFormat.channelCount);
        AVAudioFramePosition left = handle.framePosition;
        [self assertPCM:before equals:[self referenceOf:source from:0 frames:reached] context:[name stringByAppendingString:@", before"]];

        // Still interrupted, and a read before the seek is refused rather
        // than served from wherever the decoder was left.
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:1000];
        NSError *refused = nil;
        XCTAssertFalse([handle readIntoBuffer:buffer error:&refused], @"%@", name);
        XCTAssertTrue([AudioFileHandle isInterruption:refused], @"%@: %@", name, refused);
        [handle allowReads];
        XCTAssertFalse([handle readIntoBuffer:buffer error:&refused], @"%@: a read after allowReads still needs a seek", name);

        AVAudioFramePosition targets[] = {left, MAX(0, reached - 100), reached + 5000, 0};
        for (size_t t = 0; t < sizeof(targets) / sizeof(targets[0]); t++) {
            AVAudioFramePosition target = MIN(targets[t], handle.length);
            NSString *context = [NSString stringWithFormat:@"%@ from %lld of %lld", name, target, handle.length];
            __block NSData *after = nil;
            __block NSError *afterError = nil;
            [self drive:file step:3001 reader:^{
                NSError *seekError = nil;
                if ([handle seekToFrame:target error:&seekError]) {
                    after = VibeDecode(handle, 1000, 20000, &seekError);
                }
                afterError = seekError;
            }];
            XCTAssertNotNil(after, @"%@: %@", context, afterError);
            [self assertPCM:after equals:[self referenceOf:source from:target frames:20000] context:context];
            if (t == 0) {
                // Interrupt again, mid-seek-read this time, before the next
                // target: each recovery starts from a lost read.
                __block NSError *againError = nil;
                [self start:file reader:^{
                    NSError *readError = nil;
                    (void)VibeDecode(handle, 1000, INT64_MAX, &readError);
                    againError = readError;
                }];
                if ([self awaitEvent:file] && !file.readerDone) {
                    [handle interruptReads];
                    XCTAssertTrue([self awaitEvent:file] && file.readerDone, @"%@", context);
                    XCTAssertTrue([AudioFileHandle isInterruption:againError], @"%@: %@", context, againError);
                    [handle allowReads];
                }
            }
        }
    }
}

// The open waits too, and its caller can end it from another thread: the
// init fails with an interruption instead of holding its worker until the
// download arrives. The coordinator's cancel takes this road.
- (void)testInterruptingABlockedOpenFailsItWithAnInterruption {
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        NSString *name = source.lastPathComponent;
        VibeGrowingFile *file = [self stream:source prefix:16];
        __block _Atomic bool cancelled = false;
        __block AudioFileHandle *handle = nil;
        __block NSError *error = nil;
        XCTestExpectation *returned = [self expectationWithDescription:@"open returned"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *openError = nil;
            handle = [[AudioFileHandle alloc] initForReading:file.url interleaved:NO interrupted:^BOOL{
                return atomic_load(&cancelled);
            } error:&openError];
            error = openError;
            [returned fulfill];
        });
        XCTAssertTrue([self awaitBlock:file], @"%@", name);
        atomic_store(&cancelled, true);
        [[CloudFileMaterializer availabilityForURL:file.url] wakeWaiters];
        [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertNil(handle, @"%@", name);
        XCTAssertTrue([AudioFileHandle isInterruption:error], @"%@: %@", name, error);
    }
}

#pragma mark - The part file and the whole one

- (void)testAPartRenamedBeforeTheOpenOpensTheFinishedFile {
    NSURL *source = VibeWriteWAV([self sourceNamed:@"renamed.wav"], VibeNoiseSamples(20000, 2), 44100, 2, 16, 20000 * 4);
    VibeGrowingFile *file = [self stream:source prefix:100];
    _lookupOverride = ^CloudFileAvailability *(NSURL *url) {
        [file complete];
        return file.availability;
    };
    AudioFileHandle *handle = [self openWhole:file.url];
    _lookupOverride = nil;
    NSError *error = nil;
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, &error) equals:[self referenceOf:source from:0 frames:INT64_MAX]
            context:@"renamed"];
}

// A part already gone: renamed with every byte written, the open reads the
// file it became; deleted by a failed transfer, the open fails with the
// transfer's error; missing while the transfer runs, the open waits for its
// finish and then reads the file.
- (void)testAPartGoneBeforeTheOpenWaitsForTheTransfersVerdict {
    NSURL *source = VibeWriteWAV([self sourceNamed:@"gone.wav"], VibeNoiseSamples(20000, 2), 44100, 2, 16, 20000 * 4);
    NSData *reference = [self referenceOf:source from:0 frames:INT64_MAX];
    NSError *error = nil;

    VibeGrowingFile *renamed = [self stream:source prefix:100];
    [renamed writeTo:renamed.bytes.length];
    rename(renamed.availability.partURL.fileSystemRepresentation, renamed.url.fileSystemRepresentation);
    [self assertPCM:VibeDecode([self openWhole:renamed.url], 4096, INT64_MAX, &error) equals:reference context:@"renamed"];

    NSError *transferError = [NSError errorWithDomain:@"com.vibe.test-transfer" code:9 userInfo:nil];
    VibeGrowingFile *failed = [self stream:source prefix:100];
    [NSFileManager.defaultManager removeItemAtURL:failed.availability.partURL error:NULL];
    [failed.availability finishWithError:transferError];
    XCTAssertNil([[AudioFileHandle alloc] initForReading:failed.url error:&error]);
    XCTAssertEqualObjects(error, transferError);

    VibeGrowingFile *missing = [self stream:source prefix:100];
    [NSFileManager.defaultManager removeItemAtURL:missing.availability.partURL error:NULL];
    __block AudioFileHandle *handle = nil;
    XCTestExpectation *returned = [self expectationWithDescription:@"open returned"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        handle = [[AudioFileHandle alloc] initForReading:missing.url error:NULL];
        [returned fulfill];
    });
    XCTAssertTrue([self awaitBlock:missing]);
    XCTAssertEqual(missing.blockedEnd, (uint64_t)missing.bytes.length, @"the wait is for the whole file");
    XCTAssertTrue([missing.bytes writeToURL:missing.url atomically:YES]);
    [missing.availability finishWithError:nil];
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, &error) equals:reference context:@"missing"];
}

- (void)testAFileNothingStreamsOpensAsAWholeFile {
    NSURL *source = VibeWriteWAV([self sourceNamed:@"local.wav"], VibeNoiseSamples(20000, 2), 44100, 2, 16, 20000 * 4);
    AudioFileHandle *handle = [self openWhole:source];
    XCTAssertEqualObjects(_lookups, @[source.path]);
    NSError *error = nil;
    NSData *pcm = VibeDecode(handle, 4096, INT64_MAX, &error);
    XCTAssertEqual(pcm.length, (NSUInteger)20000 * 2 * sizeof(float), @"%@", error);
    [handle interruptReads];
    XCTAssertTrue([handle seekToFrame:0 error:&error], @"a whole file has nothing to interrupt: %@", error);
    XCTAssertEqualObjects(VibeDecode(handle, 4096, INT64_MAX, &error), pcm);
}

#pragma mark - Through the coordinator

// The source as a remote placeholder whose fetch does what the mirror's does:
// publishes the part file with `prefix` written, reports it readable unless
// told not to, and holds until the test completes or fails it or the
// coordinator cancels it.
- (VibeGrowingFile *)remote:(NSURL *)source prefix:(uint64_t)prefix readable:(BOOL)readable {
    VibeGrowingFile *file = [self stream:source prefix:prefix];
    XCTAssertTrue([NSFileManager.defaultManager createFileAtPath:file.url.path contents:nil
                                                      attributes:@{NSFilePosixPermissions: @0}]);
    if (!_coordinator) {
        _coordinator = [[AudioFileMaterializationCoordinator alloc] init];
    }
    _remote = file;
    _fetchVerdict = dispatch_semaphore_create(0);
    atomic_store(&_fetchOutcome, VibeFetchRunning);
    atomic_store(&_fetchCancels, 0);
    _fetchFailure = nil;
    dispatch_semaphore_t verdict = _fetchVerdict;
    __weak AudioFileHandleStreamingTests *weakSelf = self;
    _fetch = ^BOOL(NSURL *url, dispatch_block_t onReadable, void (^onCancel)(dispatch_block_t), NSError **error) {
        onCancel(^{
            AudioFileHandleStreamingTests *test = weakSelf;
            if ([test finishRemote:VibeFetchCancelled]) {
                atomic_fetch_add(&test->_fetchCancels, 1);
            }
        });
        if (readable && onReadable) {
            onReadable();
        }
        dispatch_semaphore_wait(verdict, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        dispatch_semaphore_signal(verdict); // a fetch after the verdict answers at once
        AudioFileHandleStreamingTests *test = weakSelf;
        int outcome = test ? atomic_load(&test->_fetchOutcome) : VibeFetchCancelled;
        if (outcome == VibeFetchCompleted) {
            return YES;
        }
        if (error) {
            *error = outcome == VibeFetchFailed ? test->_fetchFailure
                                                : [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        }
        return NO;
    };
    return file;
}

// The fetch's verdict, once, in the mirror's order: the bytes installed then
// the finish, or the part deleted and its readers failed; then forgotten.
- (BOOL)finishRemote:(int)outcome {
    int running = VibeFetchRunning;
    if (!_remote || !atomic_compare_exchange_strong(&_fetchOutcome, &running, outcome)) {
        return NO;
    }
    VibeGrowingFile *file = _remote;
    if (outcome == VibeFetchCompleted) {
        [file complete];
    }
    else {
        [NSFileManager.defaultManager removeItemAtURL:file.availability.partURL error:NULL];
        [file.availability finishWithError:outcome == VibeFetchFailed ? _fetchFailure
                : [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    }
    os_unfair_lock_lock(&_streamsLock);
    [_streams removeObjectForKey:file.url.path];
    os_unfair_lock_unlock(&_streamsLock);
    dispatch_semaphore_signal(_fetchVerdict);
    return YES;
}

- (AudioFileOpenToken *)open:(VibeGrowingFile *)file purpose:(VibeAudioFileOpenPurpose)purpose
                  completion:(void (^)(AudioFileHandle *handle, NSError *error))completion {
    return [_coordinator openURL:file.url purpose:purpose
                 completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) onDataless:nil
                      completion:^(AudioFileHandle *handle, NSError *error, NSTimeInterval elapsed) {
        completion(handle, error);
    }];
}

// Call inside an autorelease pool when the test lets the handle go.
- (AudioFileHandle *)deliver:(VibeGrowingFile *)file purpose:(VibeAudioFileOpenPurpose)purpose {
    __block AudioFileHandle *delivered = nil;
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"delivered"];
    [self open:file purpose:purpose completion:^(AudioFileHandle *handle, NSError *error) {
        delivered = handle;
        failure = error;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNotNil(delivered, @"%@", failure);
    return delivered;
}

- (BOOL)transferring:(VibeGrowingFile *)file {
    XCTestExpectation *drained = [self expectationWithDescription:@"main drained"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [drained fulfill];
    });
    [self waitForExpectations:@[drained] timeout:VIBE_TEST_HANG_TIMEOUT];
    return [CloudTransferRegistry.sharedRegistry isTransferringURL:file.url];
}

// The streaming claim's whole life: transfer, lane, hold and runs.
- (BOOL)running:(BOOL)running {
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot = _coordinator.stateSnapshotForTesting;
    return snapshot.claimCount == (running ? 1u : 0u) && snapshot.interactiveRunningCount == (running ? 1u : 0u);
}

- (void)assertCoordinatorSettles {
    __block VibeAudioFileMaterializationCoordinatorSnapshot snapshot;
    BOOL settled = [self eventually:^BOOL {
        snapshot = self->_coordinator.stateSnapshotForTesting;
        return snapshot.claimCount == 0 && snapshot.waiterCount == 0 && snapshot.interactiveRunningCount == 0
                && snapshot.backgroundRunningCount == 0 && snapshot.handleRunCount == 0
                && !snapshot.foregroundTransferActive && snapshot.handleOpensStarted == snapshot.handleOpensCompleted;
    }];
    XCTAssertTrue(settled, @"coordinator did not settle: claims %lu, waiters %lu, lanes %lu/%lu, runs %lu, hold %d, opens %llu/%llu",
                  (unsigned long)snapshot.claimCount, (unsigned long)snapshot.waiterCount,
                  (unsigned long)snapshot.interactiveRunningCount, (unsigned long)snapshot.backgroundRunningCount,
                  (unsigned long)snapshot.handleRunCount, snapshot.foregroundTransferActive,
                  snapshot.handleOpensStarted, snapshot.handleOpensCompleted);
}

- (NSURL *)remoteSource {
    return VibeWriteWAV([self sourceNamed:@"remote.wav"], VibeNoiseSamples(88200, 2), 44100, 2, 16, 88200 * 4);
}

// Readable delivers the playback handle on the part file while the transfer
// runs on, holding its lane, its registry entry and the hold; complete then
// settles the claim with no second delivery, and the handle reads the file
// the part became.
- (void)testAReadableTransferDeliversPlaybackAndSettlesReadyWhenComplete {
    NSURL *source = [self remoteSource];
    VibeGrowingFile *file = [self remote:source prefix:64 * 1024 readable:YES];
    __block _Atomic NSUInteger deliveries = 0;
    __block AudioFileHandle *handle = nil;
    XCTestExpectation *delivered = [self expectationWithDescription:@"delivered"];
    [self open:file purpose:VibeAudioFileOpenPurposePlayback completion:^(AudioFileHandle *opened, NSError *error) {
        if (atomic_fetch_add(&deliveries, 1) == 0) {
            handle = opened;
            [delivered fulfill];
        }
    }];
    [self waitForExpectations:@[delivered] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNotNil(handle);
    XCTAssertEqual(atomic_load(&_fetchOutcome), VibeFetchRunning, @"delivered before the transfer completed");
    XCTAssertTrue([self running:YES], @"the claim runs on, holding its lane");
    XCTAssertTrue([self transferring:file], @"and its registry entry");
    XCTAssertTrue(_coordinator.isForegroundTransferActive, @"and the hold, while its handle reads");
    XCTAssertEqual(_coordinator.stateSnapshotForTesting.handleRunCount, 0u, @"the run ended when its open returned");

    XCTAssertTrue([self finishRemote:VibeFetchCompleted]);
    XCTAssertTrue([self eventually:^BOOL { return [self running:NO]; }]);
    XCTAssertFalse([self transferring:file]);
    XCTAssertFalse(_coordinator.isForegroundTransferActive);
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot = _coordinator.stateSnapshotForTesting;
    XCTAssertEqual(snapshot.requestsReady, 1u, @"readable served the one waiter; complete served none");
    XCTAssertEqual(snapshot.handleOpensStarted, 1u);
    XCTAssertEqual(atomic_load(&deliveries), 1u);
    NSError *error = nil;
    [self assertPCM:VibeDecode(handle, 4096, INT64_MAX, &error) equals:[self referenceOf:source from:0 frames:INT64_MAX]
            context:@"streamed"];
}

- (void)testAPrefetchJoiningAReadableTransferIsDeliveredAtOnce {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:64 * 1024 readable:YES];
    AudioFileHandle *playback = [self deliver:file purpose:VibeAudioFileOpenPurposePlayback];
    AudioFileHandle *prefetch = [self deliver:file purpose:VibeAudioFileOpenPurposePrefetch];
    XCTAssertNotNil(playback);
    XCTAssertNotNil(prefetch);
    XCTAssertNotEqual(playback, prefetch);
    XCTAssertEqual(atomic_load(&_fetchOutcome), VibeFetchRunning);
    XCTAssertEqual(_coordinator.stateSnapshotForTesting.handleOpensStarted, 2u);
    XCTAssertTrue([self running:YES]);
    XCTAssertTrue([self finishRemote:VibeFetchCompleted]);
}

// A run cancelled while its open waits at the download's edge ends at once,
// as a cancellation: no delivery, out of the ceiling, and the transfer it was
// the only reason for is cancelled with it.
- (void)testCancellingAnOpenParkedAtTheEdgeEndsItAsACancellation {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:16 readable:YES];
    XCTestExpectation *silent = [self expectationWithDescription:@"no delivery"];
    silent.inverted = YES;
    AudioFileOpenToken *token = [self open:file purpose:VibeAudioFileOpenPurposePlayback
                                completion:^(AudioFileHandle *handle, NSError *error) {
        [silent fulfill];
    }];
    XCTAssertTrue([self awaitBlock:file], @"the open waits for its header");
    VibeAudioFileMaterializationCoordinatorSnapshot parked = _coordinator.stateSnapshotForTesting;
    XCTAssertEqual(parked.handleRunCount, 1u);
    XCTAssertEqual(parked.handleOpensStarted, 1u);
    XCTAssertEqual(parked.handleOpensCompleted, 0u);

    [token cancel];
    XCTAssertTrue([self eventually:^BOOL {
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot = self->_coordinator.stateSnapshotForTesting;
        return snapshot.handleOpensCompleted == 1 && snapshot.handleRunCount == 0;
    }], @"the parked open returned and left the ceiling");
    XCTAssertTrue([self eventually:^BOOL { return atomic_load(&self->_fetchCancels) == 1 && [self running:NO]; }],
                  @"the transfer nobody reads was cancelled");
    XCTAssertFalse([self transferring:file]);
    [self waitForExpectations:@[silent] timeout:0.2];
}

// The hold stays raised while a delivered handle reads a running transfer,
// with no waiter left on the claim, and drops once the transfer completes,
// though the handle lives on.
- (void)testTheHoldFollowsALiveHandleOnARunningTransfer {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:64 * 1024 readable:YES];
    AudioFileHandle *handle = [self deliver:file purpose:VibeAudioFileOpenPurposePlayback];
    XCTAssertEqual(_coordinator.stateSnapshotForTesting.waiterCount, 0u, @"the playback waiter was served");
    XCTAssertTrue(_coordinator.isForegroundTransferActive);
    XCTAssertTrue([self finishRemote:VibeFetchCompleted]);
    XCTAssertTrue([self eventually:^BOOL { return !self->_coordinator.isForegroundTransferActive; }]);
    XCTAssertNotNil(handle);
}

- (void)testAnAbandonedStreamIsCancelled {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:64 * 1024 readable:YES];
    AudioFileHandle *handle = nil;
    @autoreleasepool {
        handle = [self deliver:file purpose:VibeAudioFileOpenPurposePlayback];
    }
    XCTAssertTrue([self running:YES]);
    handle = nil;
    XCTAssertTrue([self eventually:^BOOL { return atomic_load(&self->_fetchCancels) == 1 && [self running:NO]; }]);
    XCTAssertFalse([self transferring:file]);
    XCTAssertFalse(_coordinator.isForegroundTransferActive);
}

- (void)testALivePrefetchHandleKeepsTheStreamRunning {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:64 * 1024 readable:YES];
    AudioFileHandle *playback = nil, *prefetch = nil;
    @autoreleasepool {
        playback = [self deliver:file purpose:VibeAudioFileOpenPurposePlayback];
        prefetch = [self deliver:file purpose:VibeAudioFileOpenPurposePrefetch];
    }
    playback = nil;
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    XCTAssertEqual(atomic_load(&_fetchCancels), 0u);
    XCTAssertTrue([self running:YES]);
    XCTAssertTrue(_coordinator.isForegroundTransferActive);
    prefetch = nil;
    XCTAssertTrue([self eventually:^BOOL { return atomic_load(&self->_fetchCancels) == 1 && [self running:NO]; }]);
}

// A transfer that installs another version than its placeholder stood for
// (here the placeholder is empty) retires the memoized keys, so the file's
// waveform and metadata are filed under the version it now holds.
- (void)testATransferInstallingAnotherVersionRetiresTheMemoizedKeys {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:64 * 1024 readable:YES];
    AudioTrack *track = [AudioTrack withURL:file.url];
    NSString *placeholderKey = track.cacheKey;
    XCTAssertNotNil(placeholderKey);
    AudioFileHandle *handle = [self deliver:file purpose:VibeAudioFileOpenPurposePlayback];
    XCTAssertEqualObjects(track.cacheKey, placeholderKey, @"while it streams, the placeholder's");
    XCTAssertTrue([self finishRemote:VibeFetchCompleted]);
    XCTAssertTrue([self eventually:^BOOL { return [self running:NO]; }]);
    XCTAssertNotEqualObjects(track.cacheKey, placeholderKey);
    XCTAssertEqualObjects(track.cacheKey, file.url.cacheKey);
    XCTAssertNotNil(handle);
}

- (void)testATransferThatIsNeverReadableDeliversOnlyWhenComplete {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:64 * 1024 readable:NO];
    __block AudioFileHandle *handle = nil;
    XCTestExpectation *early = [self expectationWithDescription:@"no early delivery"];
    early.inverted = YES;
    XCTestExpectation *delivered = [self expectationWithDescription:@"delivered"];
    [self open:file purpose:VibeAudioFileOpenPurposePlayback completion:^(AudioFileHandle *opened, NSError *error) {
        handle = opened;
        [early fulfill];
        [delivered fulfill];
    }];
    [self waitForExpectations:@[early] timeout:0.2];
    XCTAssertEqual(_coordinator.stateSnapshotForTesting.handleOpensStarted, 0u);
    XCTAssertTrue([self finishRemote:VibeFetchCompleted]);
    [self waitForExpectations:@[delivered] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNotNil(handle);
    XCTAssertEqual(_coordinator.stateSnapshotForTesting.requestsReady, 1u);
}

// A transfer failing after readable: the claim fails, releasing its lane and
// registry entry; a waiter that joined since gets the failure; the delivered
// handle's next wait fails with the transfer's error.
- (void)testAFailureAfterReadableFailsTheClaimItsLateWaiterAndItsHandle {
    VibeGrowingFile *file = [self remote:[self remoteSource] prefix:64 * 1024 readable:YES];
    AudioFileHandle *handle = [self deliver:file purpose:VibeAudioFileOpenPurposePlayback];
    __block VibeAudioFileMaterializationResult result = VibeAudioFileMaterializationResultReady;
    __block NSError *joinedError = nil;
    XCTestExpectation *settled = [self expectationWithDescription:@"late waiter settled"];
    AudioFileMaterializationRequestToken *late = [_coordinator materializeURL:file.url
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
            completion:^(VibeAudioFileMaterializationResult settledResult, NSError *error, NSTimeInterval elapsed) {
        result = settledResult;
        joinedError = error;
        [settled fulfill];
    }];
    XCTAssertTrue([self eventually:^BOOL { return self->_coordinator.stateSnapshotForTesting.waiterCount == 1; }],
                  @"a metadata waiter joins the stream the user hears, not yielded by its hold");
    NSError *transferError = [NSError errorWithDomain:@"com.vibe.test-transfer" code:7 userInfo:nil];
    _fetchFailure = transferError;
    XCTAssertTrue([self finishRemote:VibeFetchFailed]);
    [self waitForExpectations:@[settled] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(result, VibeAudioFileMaterializationResultFailed);
    XCTAssertEqualObjects(joinedError, transferError);
    XCTAssertTrue([self eventually:^BOOL { return [self running:NO]; }]);
    XCTAssertFalse([self transferring:file]);
    NSError *error = nil;
    XCTAssertNil(VibeDecode(handle, 4096, INT64_MAX, &error));
    XCTAssertEqualObjects(error, transferError);
    (void)late;
}

// An open through the coordinator parked in a read-ahead whose first read
// never returns ends as a cancellation when its run is cancelled: no
// delivery, and its run leaves the ceiling. The read-ahead polls its open's
// `interrupted`, so the coordinator's wake is not needed.
- (void)testCancellingAnOpenParkedInAReadAheadEndsItAsACancellation {
    VibeReadAheadScript *script = [self readAhead];
    [script stallFrom:0];
    NSURL *url = [self networkCopyOf:[self remoteSource]];
    _coordinator = [[AudioFileMaterializationCoordinator alloc] init];
    XCTestExpectation *silent = [self expectationWithDescription:@"no delivery"];
    silent.inverted = YES;
    AudioFileOpenToken *token = [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
                                      completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) onDataless:nil
                                           completion:^(AudioFileHandle *handle, NSError *error, NSTimeInterval elapsed) {
        [silent fulfill];
    }];
    XCTAssertTrue([self await:script.stalled], @"the open's first read is stuck");
    VibeAudioFileMaterializationCoordinatorSnapshot parked = _coordinator.stateSnapshotForTesting;
    XCTAssertEqual(parked.handleRunCount, 1u);
    XCTAssertEqual(parked.handleOpensCompleted, 0u);

    [token cancel];
    XCTAssertTrue([self eventually:^BOOL {
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot = self->_coordinator.stateSnapshotForTesting;
        return snapshot.handleOpensCompleted == 1 && snapshot.handleRunCount == 0;
    }], @"the parked open returned and left the ceiling");
    [self waitForExpectations:@[silent] timeout:0.2];
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 1, @"its thread is still in the read");
}

@end
