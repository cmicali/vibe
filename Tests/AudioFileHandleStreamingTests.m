//
//  AudioFileHandleStreamingTests.m
//
//  AudioFileHandle over a file still being written: a part file grown from
//  byte 0 behind a CloudFileAvailability, the reader waiting at its edge and
//  the test writing in step with it, so nothing here sleeps to synchronize.
//  Each decoder's PCM is compared exactly with its own decode of the whole
//  file, through every wait, failure and interruption.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#include <os/lock.h>
#include <stdatomic.h>

#import "AudioFileHandle.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioFixtures.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistry.h"

#pragma mark - A file written in step with its reader

// Reports each wait that is about to block, with the end it waits for, and
// the furthest range asked. A range inside the last `readyTail` bytes is
// ready at once, as a later phase's tail window will be.
@interface VibeSteppedAvailability : CloudFileAvailability
@property (atomic, copy, nullable) void (^willBlock)(uint64_t end);
@property (atomic, readonly) uint64_t furthestOffsetAsked;
@property (atomic) uint64_t readyTail;
@end

@implementation VibeSteppedAvailability {
    os_unfair_lock _lock;
    uint64_t _noted;
    BOOL _finished;
    uint64_t _furthestOffsetAsked;
}

- (void)noteWrittenBytes:(uint64_t)bytes {
    [super noteWrittenBytes:bytes];
    os_unfair_lock_lock(&_lock);
    _noted = MAX(_noted, bytes);
    os_unfair_lock_unlock(&_lock);
}

- (void)finishWithError:(NSError *)error {
    [super finishWithError:error];
    os_unfair_lock_lock(&_lock);
    _finished = YES;
    os_unfair_lock_unlock(&_lock);
}

- (uint64_t)furthestOffsetAsked {
    os_unfair_lock_lock(&_lock);
    uint64_t offset = _furthestOffsetAsked;
    os_unfair_lock_unlock(&_lock);
    return offset;
}

- (CloudFileAvailabilityWait)waitForBytesAt:(uint64_t)offset
                                     length:(uint64_t)length
                                interrupted:(BOOL (NS_NOESCAPE ^)(void))interrupted
                                      error:(NSError *__autoreleasing *)error {
    uint64_t end = offset >= self.size || length == 0 ? 0 : offset + MIN(length, self.size - offset);
    os_unfair_lock_lock(&_lock);
    BOOL blocks = !_finished && end > _noted;
    _furthestOffsetAsked = MAX(_furthestOffsetAsked, offset);
    os_unfair_lock_unlock(&_lock);
    if (self.readyTail && offset + self.readyTail >= self.size) {
        return CloudFileAvailabilityReady;
    }
    void (^willBlock)(uint64_t) = self.willBlock;
    if (blocks && willBlock) {
        willBlock(end);
    }
    return [super waitForBytesAt:offset length:length interrupted:interrupted error:error];
}

@end

// A download's part file: `bytes` written into it from byte 0 as the test
// says, renamed over `url` when complete. With a ready tail every byte is on
// disk from the start and only noted as the test says, so the tail is there.
@interface VibeGrowingFile : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) NSData *bytes;
@property (nonatomic, readonly) VibeSteppedAvailability *availability;
@property (atomic, readonly) uint64_t written;
// Signalled each time the reader is about to wait, and once it is done.
@property (nonatomic, readonly) dispatch_semaphore_t event;
@property (atomic) uint64_t blockedEnd;
@property (atomic) BOOL readerDone;
@end

@implementation VibeGrowingFile

- (instancetype)initWithBytes:(NSData *)bytes url:(NSURL *)url prefix:(uint64_t)prefix readyTail:(uint64_t)readyTail {
    self = [super init];
    if (self) {
        _bytes = bytes;
        _url = url;
        _event = dispatch_semaphore_create(0);
        NSURL *part = [url.URLByDeletingLastPathComponent
                URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.part", url.lastPathComponent]];
        [(readyTail ? bytes : NSData.data) writeToURL:part atomically:NO];
        _availability = [[VibeSteppedAvailability alloc] initWithPartURL:part size:bytes.length];
        _availability.readyTail = readyTail;
        __weak VibeGrowingFile *weakSelf = self;
        _availability.willBlock = ^(uint64_t end) {
            VibeGrowingFile *file = weakSelf;
            file.blockedEnd = end;
            dispatch_semaphore_signal(file.event);
        };
        [self writeTo:prefix];
    }
    return self;
}

- (void)writeTo:(uint64_t)end {
    end = MIN(end, (uint64_t)_bytes.length);
    uint64_t written = self.written;
    if (end <= written) {
        return;
    }
    if (!_availability.readyTail) {
        NSFileHandle *part = [NSFileHandle fileHandleForWritingToURL:_availability.partURL error:NULL];
        [part seekToEndOfFile];
        [part writeData:[_bytes subdataWithRange:NSMakeRange((NSUInteger)written, (NSUInteger)(end - written))]];
        [part closeFile];
    }
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

#pragma mark - Fixtures

// Deterministic, nonperiodic and full scale, so a frame read from the wrong
// offset, a dropped one or a repeated one never matches.
static NSData *VibeNoiseSamples(uint32_t frames, uint16_t channels) {
    NSMutableData *samples = [NSMutableData dataWithLength:(NSUInteger)frames * channels * 2];
    int16_t *out = samples.mutableBytes;
    uint32_t state = 0x12345678;
    for (NSUInteger i = 0; i < (NSUInteger)frames * channels; i++) {
        state = state * 1664525u + 1013904223u;
        double tone = sin((double)i * 0.0123) * 12000.0;
        out[i] = (int16_t)(tone + (double)(int16_t)(state >> 16) * 0.5);
    }
    return samples;
}

static AVAudioPCMBuffer *VibeNoiseBuffer(uint32_t frames) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
    buffer.frameLength = frames;
    const int16_t *samples = VibeNoiseSamples(frames, 2).bytes;
    for (uint32_t f = 0; f < frames; f++) {
        buffer.floatChannelData[0][f] = samples[f * 2] / 32768.0f;
        buffer.floatChannelData[1][f] = samples[f * 2 + 1] / 32768.0f;
    }
    return buffer;
}

// A codec file through the handle's own writer, as the converter writes a
// FLAC; an M4A comes out with its moov first, as afconvert's does.
static NSURL *VibeWriteEncoded(NSURL *url, AudioFileTypeID type, AudioStreamBasicDescription file, NSError **error) {
    AVAudioPCMBuffer *buffer = VibeNoiseBuffer(88200);
    AudioFileHandle *writer = [[AudioFileHandle alloc] initForWriting:url fileType:type
                                                           fileFormat:[[AVAudioFormat alloc] initWithStreamDescription:&file]
                                                     processingFormat:buffer.format error:error];
    return [writer writeFromBuffer:buffer error:error] && [writer closeWithError:error] ? url : nil;
}

// MPEG-1 Layer III, 320 kbps, 44.1 kHz, stereo: a LAME Info frame counting
// `frames` silent frames after it, which, as for every MP3 with one, makes
// CoreAudio's open read the file's head and then its last bytes.
static NSData *VibeMP3WithInfoFrame(uint32_t frames) {
    const uint8_t header[4] = {0xFF, 0xFB, 0xE0, 0x00};
    NSMutableData *bytes = [NSMutableData data];
    for (uint32_t i = 0; i <= frames; i++) {
        NSMutableData *frame = [NSMutableData dataWithLength:1044];
        uint8_t *out = frame.mutableBytes;
        memcpy(out, header, sizeof(header));
        if (i == 0) {
            const uint32_t fields[3] = {CFSwapInt32HostToBig(3), CFSwapInt32HostToBig(frames + 1),
                                        CFSwapInt32HostToBig((frames + 1) * 1044)};
            memcpy(out + 36, "Info", 4);
            memcpy(out + 40, fields, sizeof(fields));
        }
        [bytes appendData:frame];
    }
    return bytes;
}

static NSURL *VibeAssetFixture(NSString *name) {
    NSString *tests = [NSString stringWithUTF8String:__FILE__].stringByDeletingLastPathComponent;
    NSString *path = [tests stringByAppendingPathComponent:[@"../Assets/test_audio_files" stringByAppendingPathComponent:name]];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? [NSURL fileURLWithPath:path.stringByStandardizingPath] : nil;
}

#pragma mark - Reading

// Interleaved float32 from the cursor, `chunk` frames a read, until the end
// or `limit` frames; nil when a read answers NO.
static NSData *VibeDecode(AudioFileHandle *handle, AVAudioFrameCount chunk, AVAudioFramePosition limit,
                          NSError **error) {
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:chunk];
    NSMutableData *pcm = [NSMutableData data];
    AVAudioFramePosition total = 0;
    while (total < limit) {
        AVAudioFrameCount wanted = (AVAudioFrameCount)MIN((AVAudioFramePosition)chunk, limit - total);
        if (![handle readIntoBuffer:buffer frameCount:wanted error:error]) {
            return nil;
        }
        if (buffer.frameLength == 0) {
            break;
        }
        VibeAppendPCM(pcm, buffer);
        total += buffer.frameLength;
    }
    return pcm;
}

// What a test's remote fetch was told, once.
enum { VibeFetchRunning = 0, VibeFetchCompleted, VibeFetchFailed, VibeFetchCancelled };

@interface AudioFileHandleStreamingTests : XCTestCase
@end

@implementation AudioFileHandleStreamingTests {
    NSURL *_directory;
    os_unfair_lock _streamsLock;
    NSMutableDictionary<NSString *, CloudFileAvailability *> *_streams;
    NSMutableArray<NSString *> *_lookups;
    CloudFileAvailability *_Nullable (^_lookupOverride)(NSURL *url);
    // Through the coordinator: the remote fetch, and what the test decided.
    CloudFileRemoteFetch _fetch;
    dispatch_semaphore_t _fetchVerdict;
    _Atomic int _fetchOutcome;
    _Atomic NSUInteger _fetchCancels;
    NSError *_fetchFailure;
    VibeGrowingFile *_remote;
    AudioFileMaterializationCoordinator *_coordinator;
}

- (void)setUp {
    [super setUp];
    _directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                            isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
    _streamsLock = OS_UNFAIR_LOCK_INIT;
    _streams = [NSMutableDictionary dictionary];
    _lookups = [NSMutableArray array];
    __weak AudioFileHandleStreamingTests *weakSelf = self;
    [CloudFileMaterializer setRemoteRoot:_directory fetch:^BOOL(NSURL *url, dispatch_block_t onReadable, void (^onCancel)(dispatch_block_t), NSError **error) {
        AudioFileHandleStreamingTests *test = weakSelf;
        CloudFileRemoteFetch fetch = test ? test->_fetch : nil;
        return fetch ? fetch(url, onReadable, onCancel, error) : NO;
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        return nil;
    } availability:^CloudFileAvailability *(NSURL *url) {
        return [weakSelf availabilityForURL:url];
    }];
}

- (void)tearDown {
    if (_coordinator) {
        [self finishRemote:VibeFetchCancelled];
        [self assertCoordinatorSettles];
    }
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    [NSFileManager.defaultManager removeItemAtURL:_directory error:NULL];
    [super tearDown];
}

- (CloudFileAvailability *)availabilityForURL:(NSURL *)url {
    os_unfair_lock_lock(&_streamsLock);
    [_lookups addObject:url.path];
    CloudFileAvailability *_Nullable (^override)(NSURL *) = _lookupOverride;
    CloudFileAvailability *availability = _streams[url.path];
    os_unfair_lock_unlock(&_streamsLock);
    return override ? override(url) : availability;
}

// The fixtures every test runs over: the decoder each one reaches, by file.
- (NSDictionary<NSURL *, NSString *> *)fixtures {
    NSMutableDictionary<NSURL *, NSString *> *fixtures = [NSMutableDictionary dictionary];
    NSError *error = nil;
    void (^add)(NSURL *, NSString *) = ^(NSURL *url, NSString *decoder) {
        XCTAssertNotNil(url, @"%@", decoder);
        if (url) {
            fixtures[url] = decoder;
        }
    };
    add(VibeWriteWAV([self sourceNamed:@"noise.wav"], VibeNoiseSamples(88200, 2), 44100, 2, 16, 88200 * 4), @"dr_wav");
    add(VibeWriteFixture([self sourceNamed:@"noise.aif"], VibeNoiseBuffer(88200), &error), @"dr_wav");
    add(VibeWriteFixture([self sourceNamed:@"noise.caf"], VibeNoiseBuffer(88200), &error), @"apple");
    AudioStreamBasicDescription flac = {.mSampleRate = 44100, .mFormatID = kAudioFormatFLAC,
                                        .mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData, .mChannelsPerFrame = 2};
    add(VibeWriteEncoded([self sourceNamed:@"noise.flac"], kAudioFileFLACType, flac, &error), @"dr_flac");
    AudioStreamBasicDescription alac = {.mSampleRate = 44100, .mFormatID = kAudioFormatAppleLossless,
                                        .mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData,
                                        .mFramesPerPacket = 4096, .mChannelsPerFrame = 2};
    add(VibeWriteEncoded([self sourceNamed:@"noise-alac.m4a"], kAudioFileM4AType, alac, &error), @"apple");
    AudioStreamBasicDescription aac = {.mSampleRate = 44100, .mFormatID = kAudioFormatMPEG4AAC,
                                       .mFramesPerPacket = 1024, .mChannelsPerFrame = 2};
    add(VibeWriteEncoded([self sourceNamed:@"noise-aac.m4a"], kAudioFileM4AType, aac, &error), @"apple");
    NSURL *mp3 = [self sourceNamed:@"info.mp3"];
    add([VibeMP3WithInfoFrame(400) writeToURL:mp3 atomically:YES] ? mp3 : nil, @"dr_mp3");
    // Real encodes when the gitignored corpus is here: a seek table, LAME's
    // CBR Info frame and a VBR Xing frame.
    for (NSString *name in @[@"tone.flac", @"tone-cbr.mp3", @"tone-vbr.mp3"]) {
        NSURL *asset = VibeAssetFixture(name);
        NSURL *copy = [self sourceNamed:name];
        if (asset && [NSFileManager.defaultManager copyItemAtURL:asset toURL:copy error:NULL]) {
            add(copy, [name hasSuffix:@"flac"] ? @"dr_flac" : @"dr_mp3");
        }
    }
    return fixtures;
}

- (NSURL *)sourceNamed:(NSString *)name {
    NSURL *sources = [_directory URLByAppendingPathComponent:@"whole" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:sources withIntermediateDirectories:YES attributes:nil error:NULL];
    return [sources URLByAppendingPathComponent:name];
}

// The source's bytes, streaming under a name of their own with `prefix` of
// them written.
- (VibeGrowingFile *)stream:(NSURL *)source prefix:(uint64_t)prefix {
    return [self stream:source prefix:prefix readyTail:0];
}

- (VibeGrowingFile *)stream:(NSURL *)source prefix:(uint64_t)prefix readyTail:(uint64_t)readyTail {
    NSURL *url = [_directory URLByAppendingPathComponent:source.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    VibeGrowingFile *file = [[VibeGrowingFile alloc] initWithBytes:[NSData dataWithContentsOfURL:source] url:url
                                                            prefix:prefix readyTail:readyTail];
    os_unfair_lock_lock(&_streamsLock);
    _streams[url.path] = file.availability;
    os_unfair_lock_unlock(&_streamsLock);
    return file;
}

- (AudioFileHandle *)openWhole:(NSURL *)source {
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:source error:&error];
    XCTAssertNotNil(handle, @"%@: %@", source.lastPathComponent, error);
    return handle;
}

- (NSData *)referenceOf:(NSURL *)source from:(AVAudioFramePosition)frame frames:(AVAudioFramePosition)frames {
    AudioFileHandle *whole = [self openWhole:source];
    NSError *error = nil;
    XCTAssertTrue([whole seekToFrame:frame error:&error], @"%@", error);
    NSData *pcm = VibeDecode(whole, 4096, frames, &error);
    XCTAssertNotNil(pcm, @"%@", error);
    return pcm;
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

// Exact, but for AAC: two of Apple's AAC decodes can differ in rounding, so
// it is held to four float epsilons, as the render suite holds it.
- (void)assertPCM:(NSData *)pcm equals:(NSData *)reference context:(NSString *)context {
    XCTAssertEqual(pcm.length, reference.length, @"%@: frames", context);
    const float *a = pcm.bytes, *b = reference.bytes;
    float tolerance = [context containsString:@"aac"] ? 4 * FLT_EPSILON : 0;
    for (NSUInteger i = 0; i < MIN(pcm.length, reference.length) / sizeof(float); i++) {
        if (fabsf(a[i] - b[i]) > tolerance) {
            XCTFail(@"%@: sample %lu is %g, expected %g", context, (unsigned long)i, a[i], b[i]);
            return;
        }
    }
}

#pragma mark - Decoding while the bytes arrive

// The open and every read wait at the edge, the fills come up short of their
// blocks there, and the PCM is the whole file's. A one-byte step ends every
// fill just past what it was asked for, the block cache's worst case. An MP3
// open reads its last bytes, so a tail window serves them here (the next
// test is the open without one).
- (void)testAGrowingFileDecodesExactlyAsTheWholeFile {
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        NSData *reference = [self referenceOf:source from:0 frames:INT64_MAX];
        for (NSNumber *step in @[@1, @7919]) {
            for (NSNumber *chunk in @[@333, @4096]) {
                NSString *context = [NSString stringWithFormat:@"%@, step %@, chunk %@", source.lastPathComponent, step, chunk];
                VibeGrowingFile *file = [self stream:source prefix:100
                                           readyTail:[source.pathExtension isEqualToString:@"mp3"] ? 128 : 0];
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

// The spike's head-only formats open on their head alone; AIFF also reads at
// exactly the file's size, which is the end, never a wait. A hang here is a
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

// Every MP3 open reads its last bytes (an ID3v1 check), so on a prefix it
// waits for the tail, and opens once the file is complete.
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

#pragma mark - Failure

// A failed transfer is a read failure with its error, never a clean end, and
// stays one.
- (void)testAFailedTransferFailsTheBlockedReadWithItsError {
    NSError *transferError = [NSError errorWithDomain:@"com.vibe.test-transfer" code:7 userInfo:nil];
    NSDictionary<NSURL *, NSString *> *fixtures = [self fixtures];
    for (NSURL *source in fixtures) {
        NSString *name = source.lastPathComponent;
        VibeGrowingFile *file = [self stream:source prefix:100 readyTail:[name hasSuffix:@"mp3"] ? 128 : 0];
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
        VibeGrowingFile *file = [self stream:source prefix:100 readyTail:[name hasSuffix:@"mp3"] ? 128 : 0];
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

// The transfer can finish and rename its part over the URL between the
// lookup and the open; the open then reads the whole file.
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

// A file nothing streams opens as it always has: the lookup asked once, the
// file itself read, and nothing waits.
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
                 completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
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

// Spins main, which carries the registry's edges, until the condition holds.
- (BOOL)eventually:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) {
            return NO;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return YES;
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

// A prefetch joining a readable claim is served at once, its own handle.
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

// Every handle on a readable, running transfer gone and nothing waiting: the
// transfer is cancelled, its lane and registry entry released.
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

// A prefetch handle still alive keeps the stream running when the playback
// handle goes; the stream is cancelled only once it goes too.
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

// A transfer that never reports readable (the provider's road) delivers only
// once complete, as before streaming.
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

@end
