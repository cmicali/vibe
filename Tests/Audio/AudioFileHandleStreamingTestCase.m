//
//  AudioFileHandleStreamingTestCase.m
//

#import "AudioFileHandleStreamingTestCase.h"

#pragma mark - Fixtures

// Deterministic, nonperiodic and full scale, so a frame read from the wrong
// offset, a dropped one or a repeated one never matches.
NSData *VibeNoiseSamples(uint32_t frames, uint16_t channels) {
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

AVAudioPCMBuffer *VibeNoiseBuffer(uint32_t frames) {
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
NSURL *VibeWriteEncoded(NSURL *url, AudioFileTypeID type, AudioStreamBasicDescription file, NSError **error) {
    AVAudioPCMBuffer *buffer = VibeNoiseBuffer(88200);
    AudioFileHandle *writer = [[AudioFileHandle alloc] initForWriting:url fileType:type
                                                           fileFormat:[[AVAudioFormat alloc] initWithStreamDescription:&file]
                                                     processingFormat:buffer.format error:error];
    return [writer writeFromBuffer:buffer error:error] && [writer closeWithError:error] ? url : nil;
}

static NSURL *VibeAssetFixture(NSString *name) {
    NSString *tests = [NSString stringWithUTF8String:__FILE__].stringByDeletingLastPathComponent;
    NSString *path = [tests stringByAppendingPathComponent:[@"../../Assets/test_audio_files" stringByAppendingPathComponent:name]];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? [NSURL fileURLWithPath:path.stringByStandardizingPath] : nil;
}

#pragma mark - Reading

// Interleaved float32 from the cursor, `chunk` frames a read, until the end
// or `limit` frames; nil when a read answers NO.
NSData *VibeDecode(AudioFileHandle *handle, AVAudioFrameCount chunk, AVAudioFramePosition limit,
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
NSData *VibeMoovLast(NSData *m4a) {
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
NSData *VibeWithoutVBRHeader(NSData *mp3) {
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

@implementation AudioFileHandleStreamingTestCase

- (void)setUp {
    [super setUp];
    // No test here races a deadline against the retry pause. They only wait it
    // out.
    [AudioFileHandle debugSetRetryScale:0.1];
    _directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                            isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
    _streamsLock = OS_UNFAIR_LOCK_INIT;
    _streams = [NSMutableDictionary dictionary];
    _lookups = [NSMutableArray array];
    __weak AudioFileHandleStreamingTestCase *weakSelf = self;
    [CloudFileMaterializer setRemoteRoot:_directory fetch:^BOOL(NSURL *url, dispatch_block_t onReadable, void (^onCancel)(dispatch_block_t), NSError **error) {
        AudioFileHandleStreamingTestCase *test = weakSelf;
        CloudFileRemoteFetch fetch = test ? test->_fetch : nil;
        return fetch ? fetch(url, onReadable, onCancel, error) : NO;
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        return nil;
    } availability:^CloudFileAvailability *(NSURL *url) {
        return [weakSelf availabilityForURL:url];
    }];
}

- (void)tearDown {
    if (_script) {
        // The orphan count is process-wide: every stalled thread is released
        // and gone before the next test counts.
        [_script releaseEverything];
        XCTAssertTrue([self eventually:^BOOL { return VibeReadAheadScript.threadsGone; }],
                      @"orphans %ld, live %ld", (long)AudioFileHandle.debugOrphanedReadAheads,
                      (long)AudioFileHandle.debugLiveReadAheads);
        [VibeReadAheadScript removeHook];
    }
    [AudioFileHandle debugSetRetryScale:1];
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

// The tail-reading opens, by the decoder each reaches, and a WAV. The WAV's
// open reads its head alone.
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

// Files on the test's network mount read ahead; every other file asks the
// real rule, which sends a local temporary directory down the direct road.
- (VibeReadAheadScript *)readAhead {
    if (!_script) {
        _network = [_directory URLByAppendingPathComponent:@"network" isDirectory:YES];
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_network withIntermediateDirectories:YES
                                                              attributes:nil error:NULL]);
        _script = [[VibeReadAheadScript alloc] initForPathsContaining:[_network.path stringByAppendingString:@"/"]];
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

- (BOOL)await:(dispatch_semaphore_t)semaphore {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
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

@end
