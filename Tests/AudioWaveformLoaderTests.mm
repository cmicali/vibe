//
//  AudioWaveformLoaderTests.mm
//  VibeTests
//
//  Pins the completeness rule: a file one chunk short looks identical on
//  screen, and a wrong answer either caches a truncated waveform under the
//  file's hash or freezes the strip mid-load with nothing logged.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioWaveformLoaderInternal.h"
#import "AudioFileHandle.h"
#import "AudioFixtures.h"
#import "AudioLoadTiming.h"
#import "AudioTrack.h"
#import "AudioWaveform.h"
#import "AudioWaveformCache.h"
#import "CloudFileMaterializer.h"
#import "NSURL+Hash.h"

#include <fcntl.h>
#include <atomic>
#include <sys/stat.h>
#include <sys/time.h>

@interface RecordingWaveformLoaderDelegate : NSObject <AudioWaveformLoaderDelegate>
@property (nonatomic, strong) XCTestExpectation *progressExpectation;
@end

@implementation RecordingWaveformLoaderDelegate
- (void)audioWaveformLoader:(AudioWaveformLoader *)loader
                   waveform:(CodableAudioWaveform *)waveform
                didLoadData:(float)percentLoaded {
    [_progressExpectation fulfill];
}
@end

// Each progressive snapshot, on main, as the loader delivers it.
@interface WaveformSnapshotRecorder : NSObject <AudioWaveformLoaderDelegate>
@property (nonatomic, readonly) NSMutableArray<CodableAudioWaveform *> *snapshots;
@property (nonatomic, readonly) NSMutableArray<NSNumber *> *fractions;
@end

@implementation WaveformSnapshotRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _snapshots = [NSMutableArray array];
        _fractions = [NSMutableArray array];
    }
    return self;
}
- (void)audioWaveformLoader:(AudioWaveformLoader *)loader
                   waveform:(CodableAudioWaveform *)waveform
                didLoadData:(float)percentLoaded {
    [_snapshots addObject:waveform];
    [_fractions addObject:@(percentLoaded)];
}
@end

// The cache's deliveries, on main.
@interface WaveformCacheRecorder : NSObject <AudioWaveformCacheDelegate>
@property (nonatomic) CodableAudioWaveform *complete;
@property (nonatomic) NSUInteger progressions;
@property (nonatomic) NSUInteger completions;
@property (nonatomic) NSUInteger failures;
@end

@implementation WaveformCacheRecorder
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded forTrack:(AudioTrack *)track {
    if (percentLoaded >= 1) {
        _complete = waveform;
        _completions++;
    }
    else {
        _progressions++;
    }
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForTrack:(AudioTrack *)track {
    _failures++;
}
@end

// A remote placeholder's bytes streaming into its part file, as the mirror's
// fetch writes them; each wait about to block signals `event`.
@interface WaveformStreamAvailability : CloudFileAvailability
@property (nonatomic) dispatch_semaphore_t event;
@property (atomic) uint64_t blockedEnd; // the end of the range the last wait about to block asked for
@end

@implementation WaveformStreamAvailability {
    std::atomic<bool> _finished;
}
- (void)finishWithError:(NSError *)error {
    _finished = true;
    [super finishWithError:error];
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
    if (!_finished && end > self.writtenBytes) {
        self.blockedEnd = end;
        dispatch_semaphore_signal(_event);
    }
    return [super waitForBytesAt:offset length:length windowInto:buffer capacity:capacity copied:copied
                     interrupted:interrupted deadline:deadline error:error];
}
@end

@interface AudioWaveformLoaderTests : XCTestCase
@end

@implementation AudioWaveformLoaderTests {
    AudioWaveformLoader *_loader;
    NSURL *_tempDirectory;
    // The streams the remote backend answers, by path; set only by a test
    // that streams, and uninstalled in tearDown.
    NSMutableDictionary<NSString *, WaveformStreamAvailability *> *_streams;
}

- (void)setUp {
    [super setUp];
    _loader = [[AudioWaveformLoader alloc] init];
    _tempDirectory = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_tempDirectory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
}

// A chunk starts at (0, 0) and only widens, so an all-negative window keeps
// max == 0: content is either bound moving, never max alone.
static BOOL ChunkHasContent(AudioWaveformCacheChunk chunk) {
    return chunk.getMin() < 0.0f || chunk.getMax() > 0.0f;
}

- (void)tearDown {
    if (_streams) {
        [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    }
    [NSFileManager.defaultManager removeItemAtURL:_tempDirectory error:nil];
    _loader = nil;
    [super tearDown];
}

// A pass that read the whole file and filled every chunk.
- (struct VibeWaveformDecodePass)completePassWithChunks:(NSUInteger)chunks {
    struct VibeWaveformDecodePass pass = {};
    pass.totalFrames = 441000;
    pass.numChannels = 2;
    pass.effectiveChunks = chunks;
    pass.chunksFilled = chunks;
    pass.framesRead = pass.totalFrames;
    pass.readError = NO;
    return pass;
}

#pragma mark - isDecodeComplete: the two-chunk tolerance

- (void)testDecodeThatFilledEveryChunkIsComplete {
    struct VibeWaveformDecodePass pass = [self completePassWithChunks:1000];
    XCTAssertTrue([_loader isDecodeComplete:&pass filename:@"whole.wav"]);
    XCTAssertFalse(pass.readError);
}

// The tolerance exists because a VBR mis-tag or slight truncation makes
// file.length over-report: such a file must land on one side of the line or
// the other, never frozen mid-load.
- (void)testDecodeEndingOneOrTwoChunksShortStillCounts {
    for (NSUInteger shortfall = 1; shortfall <= 2; shortfall++) {
        struct VibeWaveformDecodePass pass = [self completePassWithChunks:1000];
        pass.chunksFilled = 1000 - shortfall;
        pass.framesRead = pass.totalFrames - 1; // EOF landed early
        XCTAssertTrue([_loader isDecodeComplete:&pass filename:@"short.wav"],
                      @"%lu chunk(s) short must still count as complete",
                      (unsigned long)shortfall);
        XCTAssertFalse(pass.readError, @"a tolerated shortfall is not an error");
    }
}

// The promotion is why the phase is not a pure predicate.
- (void)testDecodeEndingWellShortIsPromotedToAReadError {
    struct VibeWaveformDecodePass pass = [self completePassWithChunks:1000];
    pass.chunksFilled = 900;
    pass.framesRead = pass.totalFrames - 1;
    XCTAssertFalse([_loader isDecodeComplete:&pass filename:@"truncated.wav"]);
    XCTAssertTrue(pass.readError, @"an early end must be recorded, not just reported");
}

// The EOF check and the completeness threshold must agree, or a file lands in
// neither state. The boundary is the same on both sides: chunksFilled + 2.
- (void)testTheEOFToleranceAndTheCompletenessThresholdAgreeAtTheBoundary {
    struct VibeWaveformDecodePass tolerated = [self completePassWithChunks:1000];
    tolerated.chunksFilled = 998; // exactly two short
    tolerated.framesRead = tolerated.totalFrames - 1;
    XCTAssertTrue([_loader isDecodeComplete:&tolerated filename:@"edge.wav"]);

    struct VibeWaveformDecodePass rejected = [self completePassWithChunks:1000];
    rejected.chunksFilled = 997; // one past the tolerance
    rejected.framesRead = rejected.totalFrames - 1;
    XCTAssertFalse([_loader isDecodeComplete:&rejected filename:@"edge.wav"]);
}

// effectiveChunks is at least 1, and the threshold subtracts 2 from it: an
// unguarded unsigned subtraction would wrap and make every tiny file complete.
- (void)testTinyFileThresholdDoesNotWrap {
    for (NSUInteger chunks = 1; chunks <= 2; chunks++) {
        struct VibeWaveformDecodePass filled = [self completePassWithChunks:chunks];
        XCTAssertTrue([_loader isDecodeComplete:&filled filename:@"tiny.wav"]);

        struct VibeWaveformDecodePass empty = [self completePassWithChunks:chunks];
        empty.chunksFilled = 0;
        empty.framesRead = 0;
        XCTAssertFalse([_loader isDecodeComplete:&empty filename:@"tiny.wav"],
                       @"a tiny file that filled nothing is not complete");
    }
}

- (void)testAReadErrorIsNeverComplete {
    struct VibeWaveformDecodePass pass = [self completePassWithChunks:1000];
    pass.readError = YES;
    XCTAssertFalse([_loader isDecodeComplete:&pass filename:@"failed.wav"]);
}

#pragma mark - makeWaveformForPass: sizing the chunk array

- (void)testOrdinaryFileFillsTheWholeChunkArray {
    struct VibeWaveformDecodePass pass = {};
    pass.totalFrames = 441000;
    AudioWaveform *waveform = nullptr;
    NSUInteger numChunks = 0;
    CodableAudioWaveform *result = [_loader makeWaveformForPass:&pass
                                                       waveform:&waveform
                                                      numChunks:&numChunks];
    XCTAssertNotNil(result);
    XCTAssertTrue(numChunks > 0);
    XCTAssertEqual(pass.effectiveChunks, numChunks,
                   @"a normal file decodes into every chunk at its final position");
}

// Fewer frames than chunks is the one case that decodes short by design, and
// the stretch pass below is what makes it span the strip.
- (void)testFileShorterThanTheChunkArrayClampsEffectiveChunks {
    struct VibeWaveformDecodePass pass = {};
    pass.totalFrames = 12;
    AudioWaveform *waveform = nullptr;
    NSUInteger numChunks = 0;
    XCTAssertNotNil([_loader makeWaveformForPass:&pass waveform:&waveform numChunks:&numChunks]);
    XCTAssertEqual(pass.effectiveChunks, (NSUInteger)12);
    XCTAssertTrue(pass.effectiveChunks < numChunks);
}

#pragma mark - stretchWaveform: spanning the strip

// Back to front so it is safe in place. Every destination chunk must come from
// a source chunk that was actually decoded, and the last one from the last.
- (void)testShortFileIsStretchedAcrossTheFullWidth {
    struct VibeWaveformDecodePass pass = {};
    pass.totalFrames = 4;
    AudioWaveform *waveform = nullptr;
    NSUInteger numChunks = 0;
    XCTAssertNotNil([_loader makeWaveformForPass:&pass waveform:&waveform numChunks:&numChunks]);
    pass.chunksFilled = 4;

    // Distinguishable content in the four decoded chunks, silence after them.
    for (NSUInteger i = 0; i < 4; i++) {
        AudioWaveformCacheChunk chunk;
        chunk.set(-(float)(i + 1), (float)(i + 1));
        waveform->setChunkAtIndex(chunk, i);
    }
    _loader.isComplete = YES;
    [_loader stretchWaveform:waveform pass:&pass numChunks:numChunks];

    XCTAssertEqual(waveform->getChunkAtIndex(0, numChunks).getMax(), 1.0f);
    XCTAssertEqual(waveform->getChunkAtIndex(numChunks - 1, numChunks).getMax(), 4.0f,
                   @"the tail must hold the last decoded chunk, not silence");
    for (NSUInteger i = 0; i < numChunks; i++) {
        XCTAssertTrue(ChunkHasContent(waveform->getChunkAtIndex(i, numChunks)),
                      @"no gap may survive the stretch (chunk %lu)", (unsigned long)i);
    }
}

- (void)testOrdinaryFileIsNotStretched {
    struct VibeWaveformDecodePass pass = {};
    pass.totalFrames = 441000;
    AudioWaveform *waveform = nullptr;
    NSUInteger numChunks = 0;
    XCTAssertNotNil([_loader makeWaveformForPass:&pass waveform:&waveform numChunks:&numChunks]);
    pass.chunksFilled = numChunks;

    AudioWaveformCacheChunk marker;
    marker.set(-0.5f, 0.5f);
    waveform->setChunkAtIndex(marker, 0);
    _loader.isComplete = YES;
    [_loader stretchWaveform:waveform pass:&pass numChunks:numChunks];
    XCTAssertEqual(waveform->getChunkAtIndex(0, numChunks).getMax(), 0.5f);
    XCTAssertEqual(waveform->getChunkAtIndex(1, numChunks).getMax(), 0.0f,
                   @"a full decode must not be remapped");
}

// An incomplete decode is not stretched: spreading a partial read across the
// full width would draw a plausible waveform for a file that failed.
- (void)testIncompleteDecodeIsNotStretched {
    struct VibeWaveformDecodePass pass = {};
    pass.totalFrames = 4;
    AudioWaveform *waveform = nullptr;
    NSUInteger numChunks = 0;
    XCTAssertNotNil([_loader makeWaveformForPass:&pass waveform:&waveform numChunks:&numChunks]);
    pass.chunksFilled = 4;
    AudioWaveformCacheChunk chunk;
    chunk.set(-1, 1);
    waveform->setChunkAtIndex(chunk, 0);

    _loader.isComplete = NO;
    [_loader stretchWaveform:waveform pass:&pass numChunks:numChunks];
    XCTAssertEqual(waveform->getChunkAtIndex(numChunks - 1, numChunks).getMax(), 0.0f);
}

#pragma mark - openFileAtPath: and the whole pass, over a written file

- (NSString *)writeWAVNamed:(NSString *)name seconds:(double)seconds {
    return [self writeWAVNamed:name seconds:seconds quietFrom:seconds];
}

// From quietFrom seconds on, the samples are ±0.25: a window's chunks can be
// told from the rest of the file's by their energy alone.
- (NSString *)writeWAVNamed:(NSString *)name seconds:(double)seconds quietFrom:(double)quietFrom {
    const AVAudioFrameCount quiet = (AVAudioFrameCount)(44100.0 * quietFrom);
    // Alternating sign every sample, so that *every* chunk — each covering
    // about ten frames — carries both a negative min and a positive max
    // whatever the chunk boundaries land on.
    return [self writeWAVNamed:name seconds:seconds sample:^float(AVAudioFrameCount i) {
        float level = i < quiet ? 0.5f : 0.25f;
        return (i % 2 == 0) ? -level : level;
    }];
}

// 44.1 kHz stereo float, both channels sample(i).
- (NSString *)writeWAVNamed:(NSString *)name seconds:(double)seconds
                     sample:(float (^)(AVAudioFrameCount i))sample {
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:name];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                             sampleRate:44100
                                                               channels:2
                                                            interleaved:NO];
    const AVAudioFrameCount total = (AVAudioFrameCount)(44100.0 * seconds);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                             frameCapacity:total];
    buffer.frameLength = total;
    for (AVAudioFrameCount i = 0; i < total; i++) {
        float v = sample(i);
        buffer.floatChannelData[0][i] = v;
        buffer.floatChannelData[1][i] = v;
    }
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"could not write fixture: %@", error);
    return url.path;
}

- (void)testOpenReportsTheFileShape {
    NSString *path = [self writeWAVNamed:@"shape.wav" seconds:1.0];
    struct VibeWaveformDecodePass pass = {};
    AudioFileHandle *file = [_loader openFileAtPath:path pass:&pass];
    XCTAssertNotNil(file);
    XCTAssertEqual(pass.totalFrames, (AVAudioFramePosition)44100);
    XCTAssertEqual(pass.numChannels, (NSUInteger)2);
}

// 44.1 kHz is 588 frames per CD frame, so [37, 112) is [21756, 65856).
- (void)testOpenOfAWindowReportsTheWindowLength {
    NSString *path = [self writeWAVNamed:@"window.wav" seconds:2.0];
    _loader.cueStart = 37;
    _loader.cueEnd = 112;
    struct VibeWaveformDecodePass pass = {};
    AudioFileHandle *file = [_loader openFileAtPath:path pass:&pass];
    XCTAssertNotNil(file);
    XCTAssertEqual(pass.totalFrames, (AVAudioFramePosition)44100);
    XCTAssertEqual(file.framePosition, (AVAudioFramePosition)21756);
}

- (void)testOpenOfAWindowPastTheFileAnswersNil {
    NSString *path = [self writeWAVNamed:@"short.wav" seconds:1.0];
    _loader.cueStart = 150;
    struct VibeWaveformDecodePass pass = {};
    XCTAssertNil([_loader openFileAtPath:path pass:&pass]);
}

- (void)testOpenOfAMissingFileAnswersNil {
    struct VibeWaveformDecodePass pass = {};
    NSString *path = [_tempDirectory URLByAppendingPathComponent:@"absent.wav"].path;
    XCTAssertNil([_loader openFileAtPath:path pass:&pass]);
}

- (void)testOpenOfANonAudioFileAnswersNil {
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:@"notaudio.wav"];
    [@"this is not a wav" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    struct VibeWaveformDecodePass pass = {};
    XCTAssertNil([_loader openFileAtPath:url.path pass:&pass]);
}

// A cancel that arrived while the load was queued must cost no decode at all.
- (void)testCancelledLoadDoesNoWork {
    NSString *path = [self writeWAVNamed:@"cancelled.wav" seconds:1.0];
    _loader.isCancelled = YES;
    XCTAssertNil([_loader load:path]);
    XCTAssertFalse(_loader.isComplete);
}

- (void)testDetachedLoadFinishesWithoutProgressDeliveries {
    NSString *path = [self writeWAVNamed:@"detached.wav" seconds:1.0];
    XCTestExpectation *progress = [self expectationWithDescription:@"no detached progress"];
    progress.inverted = YES;
    RecordingWaveformLoaderDelegate *delegate = [RecordingWaveformLoaderDelegate new];
    delegate.progressExpectation = progress;
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] initWithDelegate:delegate];
    [loader detach];

    XCTAssertNotNil([loader load:path]);
    XCTAssertTrue(loader.isComplete);
    [self waitForExpectations:@[progress] timeout:0.2];
    XCTAssertEqual(delegate.progressExpectation, progress);
}

- (void)testFullLoadOfAWrittenFileIsComplete {
    NSString *path = [self writeWAVNamed:@"full.wav" seconds:2.0];
    CodableAudioWaveform *result = [_loader load:path];
    XCTAssertNotNil(result);
    XCTAssertTrue(_loader.isComplete);

    AudioWaveform *waveform = result.waveform;
    NSUInteger numChunks = waveform->getNumChunks();
    XCTAssertTrue(numChunks > 0);
    NSUInteger silent = 0, wrongEnergy = 0;
    for (NSUInteger i = 0; i < numChunks; i++) {
        AudioWaveformCacheChunk chunk = waveform->getChunkAtIndex(i, numChunks);
        if (!ChunkHasContent(chunk)) {
            silent++;
        }
        // Every sample of the fixture is ±0.5, so every chunk's meanSquare is
        // exactly 0.25 wherever the chunk boundaries land.
        if (fabsf(chunk.getMeanSquare() - 0.25f) > 1e-4f) {
            wrongEnergy++;
        }
    }
    XCTAssertEqual(silent, (NSUInteger)0, @"every chunk of a full-scale signal must have content");
    XCTAssertEqual(wrongEnergy, (NSUInteger)0, @"every chunk of a constant ±0.5 signal carries meanSquare 0.25");
}

// A cue row's waveform is its window at the full resolution: every chunk is
// the quiet second, none the loud one before it or the silence after.
- (void)testFullLoadOfAWindowCoversOnlyTheWindow {
    NSString *path = [self writeWAVNamed:@"rows.wav" seconds:3.0 quietFrom:1.0];
    _loader.cueStart = 75;
    _loader.cueEnd = 150;
    CodableAudioWaveform *result = [_loader load:path];
    XCTAssertNotNil(result);
    XCTAssertTrue(_loader.isComplete);

    AudioWaveform *waveform = result.waveform;
    NSUInteger numChunks = waveform->getNumChunks();
    NSUInteger wrongEnergy = 0;
    for (NSUInteger i = 0; i < numChunks; i++) {
        if (fabsf(waveform->getChunkAtIndex(i, numChunks).getMeanSquare() - 0.0625f) > 1e-4f) {
            wrongEnergy++;
        }
    }
    XCTAssertEqual(wrongEnergy, (NSUInteger)0, @"every chunk of the window is the ±0.25 second");
}

// A second each of 80 Hz, 1 kHz and 8 kHz: each lands in its own band at
// about the tone's power, at least 10 dB over the other two.
- (void)testEachToneLandsInItsOwnBand {
    static const double tones[] = {80, 1000, 8000};
    NSString *path = [self writeWAVNamed:@"tones.wav" seconds:3 sample:^float(AVAudioFrameCount i) {
        return 0.5f * (float)sin(2 * M_PI * tones[i / 44100] * i / 44100.0);
    }];

    // Unasked, a decode skips the split altogether.
    XCTAssertFalse([_loader load:path].waveform->hasBands());

    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
    loader.analysis = (VibeWaveformAnalysis){.bands = YES};
    CodableAudioWaveform *result = [loader load:path];
    XCTAssertNotNil(result);
    XCTAssertTrue(result.waveform->hasBands());
    for (NSUInteger tone = 0; tone < 3; tone++) {
        // Each second's latter half, past the filters' settling.
        float meanSquares[kAudioWaveformBandCount];
        result.waveform->getBandMeanSquares(tone * 2 + 1, 6, meanSquares);
        float own = meanSquares[tone];
        XCTAssertEqualWithAccuracy(own, 0.125f, 0.03f, @"%g Hz", tones[tone]);
        for (NSUInteger band = 0; band < kAudioWaveformBandCount; band++) {
            if (band != tone) {
                XCTAssertGreaterThan(own, 10 * meanSquares[band],
                                     @"%g Hz leaks into band %lu", tones[tone], band);
            }
        }
    }
}

- (void)testFullLoadOfAVeryShortFileSpansTheStrip {
    NSString *path = [self writeWAVNamed:@"blip.wav" seconds:0.02]; // 882 frames
    CodableAudioWaveform *result = [_loader load:path];
    XCTAssertNotNil(result);
    XCTAssertTrue(_loader.isComplete);

    AudioWaveform *waveform = result.waveform;
    NSUInteger numChunks = waveform->getNumChunks();
    XCTAssertTrue(ChunkHasContent(waveform->getChunkAtIndex(numChunks - 1, numChunks)),
                  @"a short file must be stretched to the last chunk");
}


#pragma mark - A file still downloading

static const time_t kStreamModified = 1700000000;

// A 16-bit stereo WAV of nonperiodic noise, so a chunk read from the wrong
// offset never matches the reference's.
- (NSURL *)writeNoiseWAVNamed:(NSString *)name seconds:(double)seconds seed:(uint32_t)seed {
    uint32_t frames = (uint32_t)(44100.0 * seconds);
    NSMutableData *samples = [NSMutableData dataWithLength:(NSUInteger)frames * 4];
    int16_t *out = (int16_t *)samples.mutableBytes;
    uint32_t state = seed;
    for (NSUInteger i = 0; i < (NSUInteger)frames * 2; i++) {
        state = state * 1664525u + 1013904223u;
        out[i] = (int16_t)(sin((double)i * 0.00071) * 16000.0 + (double)(int16_t)(state >> 16) * 0.4);
    }
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:name];
    XCTAssertNotNil(VibeWriteWAV(url, samples, 44100, 2, 16, frames * 4));
    return url;
}

- (void)installRemoteBackend {
    if (_streams) {
        return;
    }
    _streams = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, WaveformStreamAvailability *> *streams = _streams;
    [CloudFileMaterializer setRemoteRoot:_tempDirectory fetch:^BOOL(NSURL *url, dispatch_block_t onReadable,
                                                                    void (^onCancel)(dispatch_block_t), NSError **error) {
        return NO;
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        return nil;
    } availability:^CloudFileAvailability *(NSURL *url) {
        @synchronized (streams) {
            return streams[url.path];
        }
    }];
}

// `source` as the mirror leaves a file it streams: a placeholder of the final
// size and the version's mtime with no permissions, and a part file holding
// its first `prefix` bytes.
- (WaveformStreamAvailability *)stream:(NSURL *)source as:(NSURL *)url prefix:(NSUInteger)prefix {
    [self installRemoteBackend];
    NSData *bytes = [NSData dataWithContentsOfURL:source];
    int fd = open(url.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    struct timeval times[2] = {{kStreamModified, 0}, {kStreamModified, 0}};
    XCTAssertTrue(fd >= 0 && ftruncate(fd, (off_t)bytes.length) == 0 && futimes(fd, times) == 0 && fchmod(fd, 0) == 0);
    close(fd);
    NSURL *part = [url.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.part", url.lastPathComponent]];
    WaveformStreamAvailability *stream = [[WaveformStreamAvailability alloc] initWithPartURL:part size:bytes.length];
    stream.event = dispatch_semaphore_create(0);
    [[bytes subdataWithRange:NSMakeRange(0, prefix)] writeToURL:part atomically:NO];
    [stream noteWrittenBytes:prefix];
    @synchronized (_streams) {
        _streams[url.path] = stream;
    }
    return stream;
}

- (void)write:(WaveformStreamAvailability *)stream from:(NSURL *)source to:(uint64_t)end {
    NSData *bytes = [NSData dataWithContentsOfURL:source];
    end = MIN(end, (uint64_t)bytes.length);
    uint64_t written = stream.writtenBytes;
    if (end <= written) {
        return;
    }
    NSFileHandle *part = [NSFileHandle fileHandleForWritingToURL:stream.partURL error:NULL];
    [part seekToEndOfFile];
    [part writeData:[bytes subdataWithRange:NSMakeRange((NSUInteger)written, (NSUInteger)(end - written))]];
    [part closeFile];
    [stream noteWrittenBytes:end];
}

// The mirror's install: the last bytes, the version's mtime and the rename,
// then the finish, then forgotten.
- (void)complete:(WaveformStreamAvailability *)stream from:(NSURL *)source as:(NSURL *)url {
    [self write:stream from:source to:UINT64_MAX];
    struct timeval times[2] = {{kStreamModified, 0}, {kStreamModified, 0}};
    XCTAssertEqual(chmod(stream.partURL.fileSystemRepresentation, 0644), 0);
    XCTAssertEqual(utimes(stream.partURL.fileSystemRepresentation, times), 0);
    XCTAssertEqual(rename(stream.partURL.fileSystemRepresentation, url.fileSystemRepresentation), 0);
    [stream finishWithError:nil];
    @synchronized (_streams) {
        [_streams removeObjectForKey:url.path];
    }
}

// What the coordinator's cancel comes to once the play lets the stream go.
- (void)abandon:(WaveformStreamAvailability *)stream as:(NSURL *)url {
    [NSFileManager.defaultManager removeItemAtURL:stream.partURL error:NULL];
    [stream finishWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    @synchronized (_streams) {
        [_streams removeObjectForKey:url.path];
    }
}

- (BOOL)await:(dispatch_semaphore_t)semaphore {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
}

// Spins main, where deliveries land, until the condition holds.
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

static BOOL ChunksEqual(AudioWaveformCacheChunk a, AudioWaveformCacheChunk b) {
    return a.getMin() == b.getMin() && a.getMax() == b.getMax() && a.getMeanSquare() == b.getMeanSquare();
}

// How many leading chunks of `waveform` are exactly the reference's.
static NSUInteger MatchingChunks(CodableAudioWaveform *waveform, CodableAudioWaveform *reference) {
    NSUInteger count = reference.waveform->getNumChunks();
    NSUInteger i = 0;
    while (i < count && ChunksEqual(waveform.waveform->getChunkAtIndex(i, count),
                                    reference.waveform->getChunkAtIndex(i, count))) {
        i++;
    }
    return i;
}

// The decode fills in as the download arrives: every snapshot's filled chunks
// are the whole file's exactly and the rest still empty; it completes once the
// download does, never holding the transfer; and the key it would be filed
// under, the placeholder's, is the installed file's.
- (void)testAStreamingLoadFillsInAsTheDownloadArrivesAndCompletesWithIt {
    NSURL *source = [self writeNoiseWAVNamed:@"whole.wav" seconds:6.0 seed:7];
    CodableAudioWaveform *reference = [[[AudioWaveformLoader alloc] init] load:source.path];
    XCTAssertNotNil(reference);
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:@"streaming.wav"];
    WaveformStreamAvailability *stream = [self stream:source as:url prefix:64 * 1024];
    NSString *placeholderKey = [AudioTrack withURL:url].cacheKey;
    XCTAssertNotNil(placeholderKey);

    WaveformSnapshotRecorder *recorder = [[WaveformSnapshotRecorder alloc] init];
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] initWithDelegate:recorder];
    __block CodableAudioWaveform *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = [loader load:url.path];
        dispatch_semaphore_signal(done);
    });
    // A block's worth at a time, each past the snapshot throttle.
    const uint64_t step = 256 * 1024;
    uint64_t size = stream.size;
    while (stream.writtenBytes + step < size) {
        XCTAssertTrue([self await:stream.event], @"the decode waits at the download's edge");
        XCTAssertEqual(stream.readerCount, 0u, @"a waveform never holds the transfer");
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        [self write:stream from:source to:stream.writtenBytes + step];
    }
    XCTAssertTrue([self await:stream.event]);
    XCTAssertFalse(loader.isComplete, @"not before the download is");
    [self complete:stream from:source as:url];
    XCTAssertTrue([self await:done]);
    XCTAssertTrue([self eventually:^BOOL { return recorder.snapshots.count >= 2; }]);

    NSUInteger count = reference.waveform->getNumChunks();
    NSUInteger partial = 0;
    for (NSUInteger i = 0; i < recorder.snapshots.count; i++) {
        float fraction = recorder.fractions[i].floatValue;
        XCTAssertLessThan(fraction, 1.0f, @"1 is the completion's, never a snapshot's");
        NSUInteger filled = (NSUInteger)lroundf(fraction * (float)count);
        if (filled >= count) {
            continue;
        }
        partial++;
        CodableAudioWaveform *snapshot = recorder.snapshots[i];
        XCTAssertFalse(snapshot.waveform->isComplete());
        XCTAssertGreaterThanOrEqual(MatchingChunks(snapshot, reference), filled, @"snapshot %lu", (unsigned long)i);
        AudioWaveformCacheChunk last = snapshot.waveform->getChunkAtIndex(count - 1, count);
        XCTAssertEqual(last.getMeanSquare(), 0.0f, @"what has not arrived is still empty");
    }
    XCTAssertGreaterThanOrEqual(partial, 2u, @"it filled in as the download proceeded");
    XCTAssertTrue(loader.isComplete);
    XCTAssertTrue(result.waveform->isComplete());
    XCTAssertEqual(MatchingChunks(result, reference), count);
    XCTAssertEqualObjects(url.cacheKey, placeholderKey, @"filed under the key the installed file answers");
}

// A cancel ends a decode parked at the download's edge at once, in the open
// or in a read, freeing its slot without completing.
- (void)testCancellingAStreamingLoadParkedAtTheEdgeEndsItPromptly {
    NSURL *source = [self writeNoiseWAVNamed:@"whole.wav" seconds:3.0 seed:11];
    for (NSNumber *prefix in @[@16, @(128 * 1024)]) {
        NSURL *url = [_tempDirectory URLByAppendingPathComponent:
                [NSString stringWithFormat:@"parked-%@.wav", prefix]];
        WaveformStreamAvailability *stream = [self stream:source as:url prefix:prefix.unsignedIntegerValue];
        AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
        __block CodableAudioWaveform *result = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            result = [loader load:url.path];
            dispatch_semaphore_signal(done);
        });
        XCTAssertTrue([self await:stream.event], @"%@: parked", prefix);
        [loader cancel];
        XCTAssertTrue([self await:done], @"%@: the cancel ended the wait", prefix);
        XCTAssertNil(result);
        XCTAssertFalse(loader.isComplete);
        XCTAssertEqual(stream.writtenBytes, prefix.unsignedLongLongValue, @"%@: nothing more arrived", prefix);
        [self abandon:stream as:url];
    }
}

// The play letting its stream go cancels the transfer, which ends a waveform
// riding it: no completion, so nothing is persisted.
- (void)testAStreamThePlayLetsGoEndsTheLoadUnfinished {
    NSURL *source = [self writeNoiseWAVNamed:@"whole.wav" seconds:3.0 seed:13];
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:@"abandoned.wav"];
    WaveformStreamAvailability *stream = [self stream:source as:url prefix:128 * 1024];
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
    [loader detach];
    __block CodableAudioWaveform *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = [loader load:url.path];
        dispatch_semaphore_signal(done);
    });
    XCTAssertTrue([self await:stream.event]);
    [self abandon:stream as:url];
    XCTAssertTrue([self await:done]);
    XCTAssertFalse(loader.isComplete, @"a partial decode is never complete, so never persisted");
}

#pragma mark - Through the cache

- (AudioWaveformCache *)cacheWithRecorder:(WaveformCacheRecorder *)recorder {
    NSString *root = [_tempDirectory URLByAppendingPathComponent:@"cache"].path;
    AudioWaveformCache *cache = [[AudioWaveformCache alloc] initWithRootPath:root];
    cache.delegate = recorder;
    return cache;
}

// A streaming load persists under the installed file's key: once the bytes
// are replaced at the same size and mtime with ones that cannot be decoded,
// a fresh track's request is answered from the cache.
- (void)testAStreamingLoadIsFoundByALaterLookupOfTheInstalledFile {
    NSURL *source = [self writeNoiseWAVNamed:@"whole.wav" seconds:3.0 seed:17];
    CodableAudioWaveform *reference = [[[AudioWaveformLoader alloc] init] load:source.path];
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:@"cached.wav"];
    WaveformStreamAvailability *stream = [self stream:source as:url prefix:128 * 1024];
    WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
    AudioWaveformCache *cache = [self cacheWithRecorder:recorder];

    [cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self await:stream.event]);
    [self complete:stream from:source as:url];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 1; }]);
    NSUInteger count = reference.waveform->getNumChunks();
    XCTAssertEqual(MatchingChunks(recorder.complete, reference), count);

    NSString *installedKey = url.cacheKey;
    NSData *zeros = [NSMutableData dataWithLength:[NSData dataWithContentsOfURL:url].length];
    XCTAssertTrue([zeros writeToURL:url atomically:NO]);
    struct timeval times[2] = {{kStreamModified, 0}, {kStreamModified, 0}};
    XCTAssertEqual(utimes(url.fileSystemRepresentation, times), 0);
    XCTAssertEqualObjects(url.cacheKey, installedKey);
    recorder.complete = nil;
    [cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 2 || recorder.failures > 0; }]);
    XCTAssertEqual(recorder.failures, 0u, @"a miss would have decoded the zeros and failed");
    XCTAssertEqual(MatchingChunks(recorder.complete, reference), count);
}

// A headerless MP3 streams on a length counted from its head: a VBR one's an
// estimate from its frames, here under half its true length; one whose head
// is one rate and the rest another, that rate's count, as short; a constant
// one's, its rate's count, right. Each waveform decodes as the bytes arrive,
// sized by that count, and is complete only once the length is exact and is
// the count it was sized by: the constant one's first decode, the other two
// decoded again from disk once the download completes, so the waveform
// delivered and persisted is always sized by the exact length, under the
// file's key.
- (void)testAWaveformDecodesAsTheBytesArriveAndCompletesOnlyOnTheExactLength {
    NSDictionary<NSString *, uint8_t (^)(uint32_t)> *rates = @{
        @"estimated.mp3": ^uint8_t(uint32_t frame) { return frame < 60 ? 13 + frame % 2 : 1 + frame % 2; },
        @"constant-head.mp3": ^uint8_t(uint32_t frame) { return frame < 200 ? 14 : 9; },
        @"constant.mp3": ^uint8_t(uint32_t frame) { return 9; },
    };
    for (NSString *name in rates) {
        NSURL *source = [_tempDirectory URLByAppendingPathComponent:[@"whole-" stringByAppendingString:name]];
        NSData *bytes = VibeMP3WithoutVBRHeader(2000, 48000, rates[name]);
        XCTAssertTrue([bytes writeToURL:source atomically:YES]);
        AVAudioFramePosition length = [[AudioFileHandle alloc] initForReading:source error:NULL].length;
        NSURL *url = [_tempDirectory URLByAppendingPathComponent:name];
        WaveformStreamAvailability *stream = [self stream:source as:url prefix:64 * 1024];
        NSUInteger window = 80 * 1024, at = bytes.length - window;
        [stream installWindow:[bytes subdataWithRange:NSMakeRange(at, window)] atOffset:at];
        WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
        AudioWaveformCache *cache = [self cacheWithRecorder:recorder];
        [AudioLoadTiming reset];
        [cache loadWaveformForTrack:[AudioTrack withURL:url]];
        XCTAssertTrue([self eventually:^BOOL { return recorder.progressions > 0; }], @"%@: decoding as the bytes arrive", name);
        XCTAssertEqual(recorder.completions, 0u, @"%@: nothing complete before the length is exact", name);
        [self complete:stream from:source as:url];
        XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 1; }], @"%@", name);
        XCTAssertEqual(recorder.failures, 0u, @"%@", name);
        XCTAssertEqualWithAccuracy([[AudioLoadTiming newestJSONForPath:url.path][@"audioSeconds"] doubleValue],
                                   (double)length / 48000, 1e-9, @"%@: sized by the exact length", name);
        NSData *zeros = [NSMutableData dataWithLength:bytes.length];
        XCTAssertTrue([zeros writeToURL:url atomically:NO]);
        struct timeval times[2] = {{kStreamModified, 0}, {kStreamModified, 0}};
        XCTAssertEqual(utimes(url.fileSystemRepresentation, times), 0);
        [cache loadWaveformForTrack:[AudioTrack withURL:url]];
        XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 2 || recorder.failures > 0; }]);
        XCTAssertEqual(recorder.failures, 0u, @"%@: persisted under the file's key: a miss would have failed on the zeros", name);
    }
}

// A file replaced by another version under its URL: the memoized key keeps
// answering the old version's entry until the memos are retired, after which
// the cache misses and decodes what the file now holds.
- (void)testAReKeyedTrackMissesTheOldVersionsEntry {
    NSURL *url = [self writeNoiseWAVNamed:@"track.wav" seconds:2.0 seed:19];
    CodableAudioWaveform *first = [[[AudioWaveformLoader alloc] init] load:url.path];
    WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
    AudioWaveformCache *cache = [self cacheWithRecorder:recorder];
    AudioTrack *track = [AudioTrack withURL:url];
    [cache loadWaveformForTrack:track];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 1; }]);
    NSUInteger count = first.waveform->getNumChunks();
    XCTAssertEqual(MatchingChunks(recorder.complete, first), count);

    [self writeNoiseWAVNamed:@"track.wav" seconds:2.5 seed:23];
    CodableAudioWaveform *second = [[[AudioWaveformLoader alloc] init] load:url.path];
    [cache loadWaveformForTrack:track];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 2; }]);
    XCTAssertEqual(MatchingChunks(recorder.complete, first), count, @"the stale memo serves the old version");

    [AudioTrack invalidateMemoizedCacheKeys];
    [cache loadWaveformForTrack:track];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 3; }]);
    XCTAssertEqual(MatchingChunks(recorder.complete, second), count, @"re-keyed, it misses and decodes the new one");
    XCTAssertEqual(recorder.failures, 0u);
}

@end
