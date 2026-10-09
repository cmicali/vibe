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
#include <libkern/OSByteOrder.h>
#include <os/lock.h>
#include <stdatomic.h>

#import "AudioFileHandle.h"
#import "AudioFileHandle+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioFixtures.h"
#import "AudioTrack.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistry.h"
#import "NSURL+Hash.h"

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

#pragma mark - A network mount's reads

// What a read-ahead's reads do, as a test scripts them through the debug
// seam's hook: each counted by offset, then slept, stalled until released,
// failed or cut short. A stalled read holds its thread as a dead mount's
// syscall does.
@interface VibeReadAheadScript : NSObject
// Signalled once per read that stalls, and per read that fails.
@property (nonatomic, readonly) dispatch_semaphore_t stalled;
@property (nonatomic, readonly) dispatch_semaphore_t failed;
@property (atomic) useconds_t throttle;
- (void)stallFrom:(uint64_t)offset;
// Lets one stalled read through. The rest stay stalled.
- (void)releaseOneStall;
// Releases every stalled read and every held failure.
- (void)releaseStalls;
// Reads at or past `offset` fail with `code`, once or every time.
- (void)fail:(int)code from:(uint64_t)offset always:(BOOL)always;
// A failing read then waits after signalling `failed`, until releaseStalls.
// Its errno reaches the thread only then.
- (void)holdFailures;
// Reads at or past `offset` find the file's end.
- (void)cutAt:(uint64_t)offset;
- (NSUInteger)readsAt:(uint64_t)offset;
// Every read the hook was called for.
@property (atomic, readonly) NSUInteger reads;
- (int)beforeReadAt:(uint64_t)offset;
@end

@implementation VibeReadAheadScript {
    NSCondition *_condition;
    NSCountedSet<NSNumber *> *_reads;
    uint64_t _stallFrom, _failFrom, _cutAt;
    NSUInteger _stallPasses;
    int _failCode;
    BOOL _failAlways;
    BOOL _holdFailures;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _reads = [NSCountedSet set];
        _stalled = dispatch_semaphore_create(0);
        _failed = dispatch_semaphore_create(0);
        _stallFrom = _failFrom = _cutAt = UINT64_MAX;
    }
    return self;
}

- (void)stallFrom:(uint64_t)offset {
    [_condition lock];
    _stallFrom = offset;
    [_condition broadcast];
    [_condition unlock];
}

- (void)releaseOneStall {
    [_condition lock];
    _stallPasses++;
    [_condition broadcast];
    [_condition unlock];
}

- (void)releaseStalls {
    [_condition lock];
    _stallFrom = UINT64_MAX;
    _holdFailures = NO;
    [_condition broadcast];
    [_condition unlock];
}

- (void)holdFailures {
    [_condition lock];
    _holdFailures = YES;
    [_condition unlock];
}

- (void)fail:(int)code from:(uint64_t)offset always:(BOOL)always {
    [_condition lock];
    _failCode = code;
    _failFrom = offset;
    _failAlways = always;
    [_condition unlock];
}

- (void)cutAt:(uint64_t)offset {
    [_condition lock];
    _cutAt = offset;
    [_condition unlock];
}

- (NSUInteger)readsAt:(uint64_t)offset {
    [_condition lock];
    NSUInteger reads = [_reads countForObject:@(offset)];
    [_condition unlock];
    return reads;
}

- (NSUInteger)reads {
    [_condition lock];
    NSUInteger reads = 0;
    for (NSNumber *offset in _reads) {
        reads += [_reads countForObject:offset];
    }
    [_condition unlock];
    return reads;
}

- (int)beforeReadAt:(uint64_t)offset {
    useconds_t throttle = self.throttle;
    if (throttle) {
        usleep(throttle);
    }
    [_condition lock];
    [_reads addObject:@(offset)];
    if (offset >= _stallFrom) {
        dispatch_semaphore_signal(_stalled);
        while (offset >= _stallFrom && _stallPasses == 0) {
            [_condition wait];
        }
        if (offset >= _stallFrom) {
            _stallPasses--;
        }
    }
    int code = 0;
    if (offset >= _failFrom) {
        code = _failCode;
        if (!_failAlways) {
            _failFrom = UINT64_MAX;
        }
    }
    BOOL cut = offset >= _cutAt;
    if (code) {
        dispatch_semaphore_signal(_failed);
        while (_holdFailures) {
            [_condition wait];
        }
    }
    [_condition unlock];
    return code ?: cut ? -1 : 0;
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
    // The read-ahead tests' network mount: files under it read ahead, their
    // reads as the script says.
    NSURL *_network;
    VibeReadAheadScript *_script;
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
    if (_script) {
        // The orphan count is process-wide: every stalled thread is released
        // and gone before the next test counts.
        [AudioFileHandle debugSetMountRule:nil];
        [_script releaseStalls];
        XCTAssertTrue([self eventually:^BOOL {
            return AudioFileHandle.debugOrphanedReadAheads == 0 && AudioFileHandle.debugLiveReadAheads == 0;
        }], @"orphans %ld, live %ld", (long)AudioFileHandle.debugOrphanedReadAheads, (long)AudioFileHandle.debugLiveReadAheads);
        [AudioFileHandle debugSetBeforeRead:nil];
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
    add([VibeMP3WithInfoFrame(400, NO) writeToURL:mp3 atomically:YES] ? mp3 : nil, @"dr_mp3");
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

// Each chunk offset inside the atoms from `at` to `end` moved back by `shift`.
static void VibeShiftChunkOffsets(uint8_t *bytes, NSUInteger at, NSUInteger end, uint32_t shift) {
    while (at + 8 <= end) {
        uint32_t size = OSReadBigInt32(bytes, at);
        if (size < 8 || at + size > end) {
            return;
        }
        const void *type = bytes + at + 4;
        if (!memcmp(type, "trak", 4) || !memcmp(type, "mdia", 4) || !memcmp(type, "minf", 4) || !memcmp(type, "stbl", 4)) {
            VibeShiftChunkOffsets(bytes, at + 8, at + size, shift);
        }
        else if (!memcmp(type, "stco", 4)) {
            for (uint32_t i = 0, count = OSReadBigInt32(bytes, at + 12); i < count && at + 20 + 4 * i <= end; i++) {
                OSWriteBigInt32(bytes, at + 16 + 4 * i, OSReadBigInt32(bytes, at + 16 + 4 * i) - shift);
            }
        }
        else if (!memcmp(type, "co64", 4)) {
            for (uint32_t i = 0, count = OSReadBigInt32(bytes, at + 12); i < count && at + 24 + 8 * i <= end; i++) {
                OSWriteBigInt64(bytes, at + 16 + 8 * i, OSReadBigInt64(bytes, at + 16 + 8 * i) - shift);
            }
        }
        at += size;
    }
}

// An M4A with its moov first rewritten with it last, after the mdat, as
// ffmpeg writes by default; nil when it was not first.
static NSData *VibeMoovLast(NSData *m4a) {
    const uint8_t *bytes = m4a.bytes;
    NSRange moov = {NSNotFound, 0};
    NSMutableData *rest = [NSMutableData data];
    for (NSUInteger at = 0; at + 8 <= m4a.length;) {
        uint32_t size = OSReadBigInt32(bytes, at);
        if (size < 8 || at + size > m4a.length) {
            return nil;
        }
        if (!memcmp(bytes + at + 4, "moov", 4)) {
            moov = NSMakeRange(at, size);
        }
        else if (!memcmp(bytes + at + 4, "mdat", 4) && moov.location == NSNotFound) {
            return nil;
        }
        else {
            [rest appendBytes:bytes + at length:size];
        }
        at += size;
    }
    if (moov.location == NSNotFound) {
        return nil;
    }
    NSMutableData *moved = [[m4a subdataWithRange:moov] mutableCopy];
    VibeShiftChunkOffsets(moved.mutableBytes, 8, moved.length, (uint32_t)moov.length);
    [rest appendData:moved];
    return rest;
}

// A FLAC whose STREAMINFO counts no samples: a length unknown, as a streamed
// encode leaves it.
static NSData *VibeFLACWithUnknownTotal(NSData *flac) {
    NSMutableData *bytes = [flac mutableCopy];
    uint8_t *b = bytes.mutableBytes;
    if (bytes.length < 42 || memcmp(b, "fLaC", 4) != 0 || (b[4] & 0x7F) != 0) {
        return nil;
    }
    b[21] &= 0xF0;
    memset(b + 22, 0, 4);
    return bytes;
}

// The MP3 with its Xing or Info tag blanked: that frame decodes as silence,
// and nothing in the stream counts its packets.
static NSData *VibeWithoutVBRHeader(NSData *mp3) {
    NSMutableData *bytes = [mp3 mutableCopy];
    for (NSString *tag in @[@"Xing", @"Info"]) {
        NSRange found = [bytes rangeOfData:[tag dataUsingEncoding:NSASCIIStringEncoding] options:0
                                     range:NSMakeRange(0, MIN(bytes.length, (NSUInteger)65536))];
        if (found.location != NSNotFound) {
            memset((uint8_t *)bytes.mutableBytes + found.location, 0, found.length);
            return bytes;
        }
    }
    return nil;
}

// The spike's tail-reading opens, by the decoder each reaches, and a WAV,
// whose open reads its head alone.
- (NSDictionary<NSURL *, NSString *> *)tailFixtures {
    NSMutableDictionary<NSURL *, NSString *> *fixtures = [NSMutableDictionary dictionary];
    NSError *error = nil;
    void (^add)(NSString *, NSData *, NSString *) = ^(NSString *name, NSData *bytes, NSString *decoder) {
        NSURL *url = [self sourceNamed:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES], @"%@", name);
        fixtures[url] = decoder;
    };
    add(@"id3v1.mp3", VibeMP3WithInfoFrame(400, YES), @"dr_mp3");
    AudioStreamBasicDescription alac = {.mSampleRate = 44100, .mFormatID = kAudioFormatAppleLossless,
                                        .mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData,
                                        .mFramesPerPacket = 4096, .mChannelsPerFrame = 2};
    NSURL *moovFirst = VibeWriteEncoded([self sourceNamed:@"moov-first.m4a"], kAudioFileM4AType, alac, &error);
    NSData *moovLast = moovFirst ? VibeMoovLast([NSData dataWithContentsOfURL:moovFirst]) : nil;
    XCTAssertNotNil(moovLast, @"%@", error);
    if (moovLast) {
        add(@"moov-last.m4a", moovLast, @"apple");
    }
    AudioStreamBasicDescription flac = {.mSampleRate = 44100, .mFormatID = kAudioFormatFLAC,
                                        .mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData, .mChannelsPerFrame = 2};
    NSURL *known = VibeWriteEncoded([self sourceNamed:@"known.flac"], kAudioFileFLACType, flac, &error);
    NSData *unknown = known ? VibeFLACWithUnknownTotal([NSData dataWithContentsOfURL:known]) : nil;
    XCTAssertNotNil(unknown, @"%@", error);
    if (unknown) {
        add(@"unknown-total.flac", unknown, @"dr_flac");
    }
    add(@"head-only.wav", [NSData dataWithContentsOfURL:VibeWriteWAV([self sourceNamed:@"head.wav"],
            VibeNoiseSamples(88200, 2), 44100, 2, 16, 88200 * 4)], @"dr_wav");
    add(@"unheadered.mp3", VibeWithoutVBRHeader(VibeMP3WithInfoFrame(400, YES)), @"dr_mp3");
    add(@"unheadered-vbr.mp3", VibeMP3WithoutVBRHeader(1200, 44100, ^uint8_t(uint32_t frame) { return (uint8_t)(9 + frame % 6); }),
        @"dr_mp3");
    for (NSString *name in @[@"tone-cbr.mp3", @"tone-vbr.mp3"]) {
        NSURL *asset = VibeAssetFixture(name);
        if (asset) {
            add(name, [NSData dataWithContentsOfURL:asset], @"dr_mp3");
            add([@"unheadered-" stringByAppendingString:name],
                VibeWithoutVBRHeader([NSData dataWithContentsOfURL:asset]), @"dr_mp3");
        }
    }
    return fixtures;
}

// With the tail window, every open the spike saw read past its head — an MP3
// (its ID3v1 check), an M4A with its moov last, a FLAC with no length — opens
// on its head and the window, never waiting for the download; its first
// second decodes with the download still short of the end; the whole decode
// is the whole file's; and the download reaching the window drops it. The
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

// A failed transfer is a read failure with its error, never a clean end, and
// stays one.
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


#pragma mark - Reading ahead

// Files on the test's network mount read ahead; every other file asks the
// real rule, which sends a local temporary directory down the direct road.
- (VibeReadAheadScript *)readAhead {
    if (!_script) {
        _network = [_directory URLByAppendingPathComponent:@"network" isDirectory:YES];
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_network withIntermediateDirectories:YES
                                                              attributes:nil error:NULL]);
        _script = [[VibeReadAheadScript alloc] init];
        VibeReadAheadScript *script = _script;
        NSString *prefix = [_network.path stringByAppendingString:@"/"];
        [AudioFileHandle debugSetMountRule:^NSNumber *(NSURL *url) {
            return [url.path hasPrefix:prefix] ? @YES : nil;
        }];
        [AudioFileHandle debugSetBeforeRead:^int(NSURL *url, uint64_t offset, uint64_t length) {
            return [url.path hasPrefix:prefix] ? [script beforeReadAt:offset] : 0;
        }];
    }
    return _script;
}

- (NSURL *)networkCopyOf:(NSURL *)source {
    [self readAhead];
    NSURL *url = [_network URLByAppendingPathComponent:source.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:source toURL:url error:NULL], @"%@", source);
    return url;
}

// An open that can be interrupted, as the coordinator's and the waveform
// loader's are; only such an open reads ahead.
static AudioFileHandle *VibeOpenInterruptibly(NSURL *url, NSError **error) {
    return [[AudioFileHandle alloc] initForReading:url interleaved:NO interrupted:^BOOL { return NO; } error:error];
}

- (NSURL *)noiseWAVNamed:(NSString *)name frames:(uint32_t)frames {
    return VibeWriteWAV([self sourceNamed:name], VibeNoiseSamples(frames, 2), 44100, 2, 16, frames * 4);
}

- (BOOL)await:(dispatch_semaphore_t)semaphore {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
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

// A missing file, an empty one and a directory fail to open as the direct
// road fails them: the same domain, code and words. The thread that found it
// exits uncounted.
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
    XCTAssertTrue([self eventually:^BOOL {
        return AudioFileHandle.debugOrphanedReadAheads == 0 && AudioFileHandle.debugLiveReadAheads == 0;
    }]);
}

// A read waiting on a stalled read-ahead returns on interruptReads, neither
// the end nor a failure. After allowReads a seek into what is held lands
// exactly, and once the server answers again the rest reads exactly too.
- (void)testAStalledReadReturnsOnInterruptReadsAndASeekLandsExactly {
    VibeReadAheadScript *script = [self readAhead];
    [script stallFrom:2 * 256 * 1024];
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

// While reads are interrupted the read-ahead fetches nothing new: its
// progress stays where the read in flight left it, and grows again, to the
// whole file, after allowReads.
- (void)testProgressStaysFlatWhileReadsAreInterrupted {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = 256 * 1024;
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

// A read the server fails is tried again after a pause, and the decode
// completes exactly, never seeing the failure.
- (void)testAFailedReadIsRetriedAndTheDecodeCompletesExactly {
    VibeReadAheadScript *script = [self readAhead];
    [script fail:EIO from:256 * 1024 always:NO];
    NSURL *source = [self noiseWAVNamed:@"retried.wav" frames:400000];
    AudioFileHandle *handle = VibeOpenInterruptibly([self networkCopyOf:source], NULL);
    NSError *error = nil;
    NSData *pcm = VibeDecode(handle, 4096, INT64_MAX, &error);
    XCTAssertNotNil(pcm, @"%@", error);
    [self assertPCM:pcm equals:[self referenceOf:source from:0 frames:INT64_MAX] context:@"retried"];
    XCTAssertEqual([script readsAt:256 * 1024], 2u, @"failed once, then read");
}

// A file cut short after its open ends there cleanly, with no error and no
// wait, as the direct open of the cut file does.
- (void)testAFileCutShortAfterItsOpenEndsCleanly {
    const uint64_t cut = 256 * 1024;
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

        [script cutAt:cut];
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
        [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertNotNil(pcm, @"%@: %@", name, readError);
        [self assertPCM:pcm equals:reference context:name];
        [script cutAt:UINT64_MAX];
    }
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

    [script stallFrom:256 * 1024];
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
    const uint64_t block = 256 * 1024;
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

// A handle let go while its thread waits out a failed read's pause ends the
// thread, and the read is never tried again. The failed read returns only
// once the handle is gone. The pause's first wait then sees the finish,
// whatever the scheduling.
- (void)testAHandleGoneDuringTheRetryPauseEndsItsThreadWithoutARetry {
    VibeReadAheadScript *script = [self readAhead];
    [script fail:EIO from:256 * 1024 always:NO];
    [script holdFailures];
    NSURL *url = [self networkCopyOf:[self noiseWAVNamed:@"pausing.wav" frames:400000]];
    @autoreleasepool {
        AudioFileHandle *handle = VibeOpenInterruptibly(url, NULL);
        XCTAssertNotNil(handle);
        XCTAssertTrue([self await:script.failed], @"a read failed");
    }
    XCTAssertEqual(AudioFileHandle.debugOrphanedReadAheads, 1, @"its thread holds the failed read");
    [script releaseStalls];
    XCTAssertTrue([self eventually:^BOOL {
        return AudioFileHandle.debugLiveReadAheads == 0 && AudioFileHandle.debugOrphanedReadAheads == 0;
    }]);
    XCTAssertEqual([script readsAt:256 * 1024], 1u, @"never retried");
    XCTAssertEqual(script.reads, 2u, @"block 0, then the failed read, and nothing after");
}

// An open that read the file's tail last, an M4A with its moov there, leaves
// its reader at the head. The thread then fetches the whole span ahead of the
// head with no read asked of it, as a parked prefetch needs. Throttled, the
// thread cannot reach the span's last block while the open still reads the
// head.
- (void)testAnOpenThatReadTheTailFetchesAheadOfTheHead {
    VibeReadAheadScript *script = [self readAhead];
    const uint64_t block = 256 * 1024;
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
    const uint64_t block = 256 * 1024, partial = block + 100 * 1024;
    NSURL *source = [self noiseWAVNamed:@"partial.wav" frames:400000];
    NSURL *url = [self networkCopyOf:source];
    NSData *bytes = [NSData dataWithContentsOfURL:source];
    [script stallFrom:block];
    AudioFileHandle *handle = VibeOpenInterruptibly(url, NULL);
    XCTAssertNotNil(handle);
    XCTAssertTrue([self await:script.stalled], @"block 1's read waits");
    // The file is short while that read runs: its first pread comes back
    // partial, and the next one fails.
    XCTAssertEqual(truncate(url.fileSystemRepresentation, (off_t)partial), 0);
    [script fail:EIO from:partial always:NO];
    [script holdFailures];
    [script stallFrom:UINT64_MAX];
    XCTAssertTrue([self await:script.failed]);
    XCTAssertTrue([bytes writeToURL:url atomically:NO]);
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
