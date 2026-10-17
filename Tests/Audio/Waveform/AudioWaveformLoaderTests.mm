//
//  AudioWaveformLoaderTests.mm
//  VibeTests
//
//  Pins the completeness rule: a file a little short looks identical on
//  screen, and a wrong answer either caches a truncated waveform under the
//  file's hash or freezes the strip mid-load with nothing logged.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#import "AudioWaveformLoaderInternal.h"
#import "AudioFileHandle.h"
#import "AudioFileHandle+Debug.h"
#import "AudioFixtures.h"
#import "AudioLoadTiming.h"
#import "AudioTrack.h"
#import "AudioWaveform.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "CloudFileMaterializer.h"
#import "NSURL+Hash.h"
#import "VibeReadAheadScript.h"

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
    // The read-ahead test's script. tearDown releases its stalled reads.
    VibeReadAheadScript *_readAhead;
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

- (void)tearDown {
    if (_streams) {
        [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    }
    if (_readAhead) {
        // The read-ahead counts are process-wide: every parked thread is
        // released and gone before the next test counts.
        [_readAhead releaseEverything];
        XCTAssertTrue([self eventually:^BOOL { return VibeReadAheadScript.threadsGone; }]);
        [VibeReadAheadScript removeHook];
    }
    [NSFileManager.defaultManager removeItemAtURL:_tempDirectory error:nil];
    _loader = nil;
    [super tearDown];
}

// A pass that read the whole file.
- (struct VibeWaveformDecodePass)completePassOfFrames:(AVAudioFramePosition)frames {
    struct VibeWaveformDecodePass pass = {};
    pass.totalFrames = frames;
    pass.numChannels = 2;
    pass.framesRead = frames;
    pass.readError = NO;
    return pass;
}

#pragma mark - isDecodeComplete: the shortfall tolerance

- (void)testDecodeThatReadEveryFrameIsComplete {
    struct VibeWaveformDecodePass pass = [self completePassOfFrames:441000];
    XCTAssertTrue([_loader isDecodeComplete:&pass filename:@"whole.wav"]);
    XCTAssertFalse(pass.readError);
}

// The tolerance exists because a VBR mis-tag or slight truncation makes
// file.length over-report: such a file must land on one side of the line or
// the other, never frozen mid-load.
- (void)testDecodeEndingWithinTheToleranceStillCounts {
    AVAudioFramePosition tolerance = [AudioWaveformLoader shortfallToleranceForFrames:441000];
    for (AVAudioFramePosition shortfall : {(AVAudioFramePosition)1, tolerance}) {
        struct VibeWaveformDecodePass pass = [self completePassOfFrames:441000];
        pass.framesRead = pass.totalFrames - shortfall;
        XCTAssertTrue([_loader isDecodeComplete:&pass filename:@"short.wav"],
                      @"%lld frames short must still count as complete", shortfall);
        XCTAssertFalse(pass.readError, @"a tolerated shortfall is not an error");
    }
}

// The promotion is why the phase is not a pure predicate.
- (void)testDecodeEndingWellShortIsPromotedToAReadError {
    struct VibeWaveformDecodePass pass = [self completePassOfFrames:441000];
    pass.framesRead = 400000;
    XCTAssertFalse([_loader isDecodeComplete:&pass filename:@"truncated.wav"]);
    XCTAssertTrue(pass.readError, @"an early end must be recorded, not just reported");
}

// The EOF check and the completeness threshold must agree, or a file lands in
// neither state. The boundary is the same on both sides.
- (void)testTheEOFToleranceAndTheCompletenessThresholdAgreeAtTheBoundary {
    AVAudioFramePosition tolerance = [AudioWaveformLoader shortfallToleranceForFrames:441000];
    struct VibeWaveformDecodePass tolerated = [self completePassOfFrames:441000];
    tolerated.framesRead = tolerated.totalFrames - tolerance;
    XCTAssertTrue([_loader isDecodeComplete:&tolerated filename:@"edge.wav"]);

    struct VibeWaveformDecodePass rejected = [self completePassOfFrames:441000];
    rejected.framesRead = rejected.totalFrames - tolerance - 1;
    XCTAssertFalse([_loader isDecodeComplete:&rejected filename:@"edge.wav"]);
}

// A tiny file keeps a tolerance of its own, and a file that read nothing is
// never complete, however small.
- (void)testATinyFileThatReadNothingIsNotComplete {
    for (AVAudioFramePosition frames = 1; frames <= 3; frames++) {
        struct VibeWaveformDecodePass filled = [self completePassOfFrames:frames];
        XCTAssertTrue([_loader isDecodeComplete:&filled filename:@"tiny.wav"]);

        struct VibeWaveformDecodePass empty = [self completePassOfFrames:frames];
        empty.framesRead = 0;
        XCTAssertFalse([_loader isDecodeComplete:&empty filename:@"tiny.wav"],
                       @"a tiny file that read nothing is not complete");
    }
}

- (void)testAReadErrorIsNeverComplete {
    struct VibeWaveformDecodePass pass = [self completePassOfFrames:441000];
    pass.readError = YES;
    XCTAssertFalse([_loader isDecodeComplete:&pass filename:@"failed.wav"]);
}

#pragma mark - builderForPass: the summary's bins

// A long file takes the full bin; a short one finer bins, so a one-shot draws
// at sample detail without a stretch.
- (void)testTheSummaryIsLaidOutOnTheWindowsLength {
    struct VibeWaveformDecodePass pass = {};
    pass.numChannels = 2;
    pass.totalFrames = 441000 * 10;
    std::unique_ptr<wavecore::SummaryBuilder> builder = [_loader builderForPass:&pass sampleRate:44100];
    std::unique_ptr<AudioWaveform> empty = builder->snapshot();
    XCTAssertEqual(empty->binFrames(), wavecore::kBaseBinFrames);
    XCTAssertEqual(empty->totalFrames(), pass.totalFrames, @"a streaming load lands where it will stay");
    XCTAssertFalse(empty->hasBands(), @"only a decode asked for the bands holds them");

    pass.totalFrames = 12;
    XCTAssertEqual([_loader builderForPass:&pass sampleRate:44100]->snapshot()->binFrames(), 1u);
    VibeWaveformAnalysis bands = {};
    bands.bands = YES;
    _loader.analysis = bands;
    XCTAssertTrue([_loader builderForPass:&pass sampleRate:44100]->snapshot()->hasBands());
}

#pragma mark - openFileAtPath: and the whole pass, over a written file

- (NSString *)writeWAVNamed:(NSString *)name seconds:(double)seconds {
    return [self writeWAVNamed:name seconds:seconds quietFrom:seconds];
}

// From quietFrom seconds on, the samples are ±0.25: a window's bins can be
// told from the rest of the file's by their energy alone.
- (NSString *)writeWAVNamed:(NSString *)name seconds:(double)seconds quietFrom:(double)quietFrom {
    const AVAudioFrameCount quiet = (AVAudioFrameCount)(44100.0 * quietFrom);
    // Alternating sign every sample, so that *every* bin carries both a
    // negative min and a positive max wherever its edges land.
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

// Every bin of the summary, as a column.
static std::vector<wavecore::Column> BinColumns(AudioWaveform *waveform) {
    std::vector<wavecore::Column> columns(waveform->binCount());
    waveform->columns(waveform->binFrames(), 0, columns.size(), columns.data());
    return columns;
}

static BOOL ColumnHasContent(const wavecore::Column &column) {
    return column.lo < 0.0f || column.hi > 0.0f;
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

// Deep zoom's blocks are the window's own frames, as the mix, from the
// window's start; a second ask reads nothing.
- (void)testDetailBlocksAreTheWindowsFrames {
    NSString *path = [self writeWAVNamed:@"detail.wav" seconds:4.0 sample:^float(AVAudioFrameCount i) {
        return (float)(i % 1000) / 1000.0f - 0.5f;
    }];
    _loader.cueStart = 37;   // frame 21756
    _loader.cueEnd = 0;
    CodableAudioWaveform *waveform = [[CodableAudioWaveform alloc]
            initWithWaveform:std::make_unique<AudioWaveform>(256, false, 44100)];
    NSMutableIndexSet *blocks = [NSMutableIndexSet indexSetWithIndex:1];
    [blocks addIndex:9];   // past the window: skipped
    XCTAssertTrue([_loader loadDetailBlocks:blocks ofFile:path intoWaveform:waveform]);
    wavecore::Detail &detail = waveform.waveform->detail();
    XCTAssertTrue(detail.hasBlock(1));
    XCTAssertFalse(detail.hasBlock(0));
    XCTAssertFalse(detail.hasBlock(9));
    const int64_t blockFrames = wavecore::Detail::kBlockFrames;
    wavecore::Column column;
    for (int64_t frame : {blockFrames + 1, blockFrames + 777, 2 * blockFrames - 2}) {
        // The column of one frame, at its center: the frame itself.
        XCTAssertTrue(detail.columns(0.5, 2 * frame, 1, 4 * 44100, &column));
        float expected = (float)((frame + 21756) % 1000) / 1000.0f - 0.5f;
        XCTAssertEqualWithAccuracy(column.hi, expected, 1e-3, @"frame %lld", frame);
    }
    XCTAssertTrue([_loader loadDetailBlocks:blocks ofFile:path intoWaveform:waveform]);
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

// The process's descriptors open on this file.
static NSUInteger DescriptorsOpenOn(NSString *path) {
    char resolved[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, resolved)) {
        return 0;
    }
    NSUInteger count = 0;
    for (int fd = 0; fd < getdtablesize(); fd++) {
        char open[PATH_MAX];
        if (fcntl(fd, F_GETPATH, open) == 0 && strcmp(open, resolved) == 0) {
            count++;
        }
    }
    return count;
}

// A loader outlives its load, held by the cache's claim and its wait timer,
// so a finished one that kept its handle kept the file open.
- (void)testAFinishedLoadLeavesItsFileClosed {
    NSString *path = [self writeWAVNamed:@"closed.wav" seconds:1.0];
    // The pool, so no autoreleased reference of the load's own outlives it.
    @autoreleasepool {
        XCTAssertNotNil([_loader load:path]);
    }
    XCTAssertTrue(_loader.isComplete);
    // The loader's open is interruptible, so its file closes on the close queue.
    dispatch_sync(AudioFileHandle.debugCloseQueue, ^{});
    XCTAssertEqual(DescriptorsOpenOn(path), (NSUInteger)0);
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
    XCTAssertEqual(waveform->frames(), 88200);
    XCTAssertTrue(waveform->isComplete());
    NSUInteger silent = 0, wrongLevel = 0;
    for (const wavecore::Column &column : BinColumns(waveform)) {
        if (!ColumnHasContent(column)) {
            silent++;
        }
        // Every sample of the fixture is ±0.5, so every window's RMS is 0.5.
        if (fabsf(column.loudest - 0.5f) > 1e-3f) {
            wrongLevel++;
        }
    }
    XCTAssertEqual(silent, (NSUInteger)0, @"every bin of a full-scale signal must have content");
    XCTAssertEqual(wrongLevel, (NSUInteger)0, @"every bin of a constant ±0.5 signal is at level 0.5");
}

// A cue row's waveform is its window at the full resolution: every bin is
// the quiet second, none the loud one before it or the silence after.
- (void)testFullLoadOfAWindowCoversOnlyTheWindow {
    NSString *path = [self writeWAVNamed:@"rows.wav" seconds:3.0 quietFrom:1.0];
    _loader.cueStart = 75;
    _loader.cueEnd = 150;
    CodableAudioWaveform *result = [_loader load:path];
    XCTAssertNotNil(result);
    XCTAssertTrue(_loader.isComplete);

    AudioWaveform *waveform = result.waveform;
    XCTAssertEqual(waveform->frames(), 44100, @"the window is one second");
    NSUInteger wrongLevel = 0;
    for (const wavecore::Column &column : BinColumns(waveform)) {
        if (fabsf(column.loudest - 0.25f) > 1e-3f) {
            wrongLevel++;
        }
    }
    XCTAssertEqual(wrongLevel, (NSUInteger)0, @"every bin of the window is the ±0.25 second");
}

// A second each of 80 Hz, 1 kHz and 8 kHz: each lands in its own band at
// about the tone's level, at least 10 dB over the other two.
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
    // Twelve columns. Each second's third quarter is past the filters'
    // settling, and its loudest windows reach no other tone.
    wavecore::Column quarters[12];
    result.waveform->columns(result.waveform->totalFrames() / 12.0, 0, 12, quarters);
    for (NSUInteger tone = 0; tone < 3; tone++) {
        const wavecore::Column &settled = quarters[tone * 4 + 2];
        float own = settled.bandLoudest[tone];
        XCTAssertEqualWithAccuracy(own, sqrtf(0.125f), 0.045f, @"%g Hz", tones[tone]);
        for (NSUInteger band = 0; band < wavecore::kBandCount; band++) {
            if (band != tone) {
                XCTAssertGreaterThan(own, sqrtf(10) * settled.bandLoudest[band],
                                     @"%g Hz leaks into band %lu", tones[tone], band);
            }
        }
    }
}

// A very short file keeps every sample: its bins are one frame each, and the
// view lays it out across its own length, with no stretch.
- (void)testFullLoadOfAVeryShortFileKeepsEverySample {
    NSString *path = [self writeWAVNamed:@"blip.wav" seconds:0.02]; // 882 frames
    CodableAudioWaveform *result = [_loader load:path];
    XCTAssertNotNil(result);
    XCTAssertTrue(_loader.isComplete);

    AudioWaveform *waveform = result.waveform;
    XCTAssertEqual(waveform->binFrames(), 1u);
    XCTAssertEqual(waveform->totalFrames(), 882);
    std::vector<wavecore::Column> bins = BinColumns(waveform);
    XCTAssertTrue(ColumnHasContent(bins.back()), @"the last sample is there");
}


#pragma mark - A file still downloading

static const time_t kStreamModified = 1700000000;

// A 16-bit stereo WAV of nonperiodic noise, so a bin read from the wrong
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

// The peaks exactly, and the level to the archive's float16: a waveform
// served from the cache matches the decode it was filed from. A snapshot's
// front has not read its whole loudest windows yet, so it compares peaks.
static BOOL ColumnsEqual(const wavecore::Column &a, const wavecore::Column &b, BOOL levels) {
    return a.lo == b.lo && a.hi == b.hi && (!levels || fabsf(a.loudest - b.loudest) <= 2e-3f * a.loudest + 1e-6f);
}

// How many leading bins of `waveform` are the reference's.
static NSUInteger MatchingBins(CodableAudioWaveform *waveform, CodableAudioWaveform *reference,
                               BOOL levels = YES) {
    NSUInteger count = reference.waveform->binCount();
    double binFrames = reference.waveform->binFrames();
    NSUInteger i = 0;
    while (i < count && ColumnsEqual(waveform.waveform->column(i * binFrames, (i + 1) * binFrames),
                                     reference.waveform->column(i * binFrames, (i + 1) * binFrames), levels)) {
        i++;
    }
    return i;
}

// The decode fills in as the download arrives: every snapshot's filled bins
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

    NSUInteger count = reference.waveform->binCount();
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
        XCTAssertGreaterThanOrEqual(MatchingBins(snapshot, reference, NO) + 1, filled, @"snapshot %lu", (unsigned long)i);
        double binFrames = reference.waveform->binFrames();
        wavecore::Column last = snapshot.waveform->column((count - 1) * binFrames, count * binFrames);
        XCTAssertEqual(last.loudest, 0.0f, @"what has not arrived is still empty");
        XCTAssertEqual(snapshot.waveform->totalFrames(), reference.waveform->totalFrames(),
                       @"a snapshot lays out on the whole length");
    }
    XCTAssertGreaterThanOrEqual(partial, 2u, @"it filled in as the download proceeded");
    XCTAssertTrue(loader.isComplete);
    XCTAssertTrue(result.waveform->isComplete());
    XCTAssertEqual(MatchingBins(result, reference), count);
    XCTAssertEqualObjects(url.cacheKey, placeholderKey, @"filed under the key the installed file answers");
}

// A main thread that stalls through a decode is handed one snapshot, not a
// queue of them, each a target fill for a picture already superseded.
- (void)testAStalledMainIsHandedOneSnapshot {
    NSString *path = [self writeWAVNamed:@"paced.wav" seconds:60];
    WaveformSnapshotRecorder *recorder = [[WaveformSnapshotRecorder alloc] init];
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] initWithDelegate:recorder];
    // Paced, so the decode makes a snapshot every 0.1 s while main waits.
    NSTimeInterval pace = AudioWaveformCache.debugDecodeSeconds;
    AudioWaveformCache.debugDecodeSeconds = 1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [loader load:path];
        dispatch_semaphore_signal(done);
    });
    // Main stalls through the whole decode, then drains its queue in order:
    // every delivery queued during the stall runs before the marker.
    XCTAssertTrue([self await:done]);
    AudioWaveformCache.debugDecodeSeconds = pace;
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        drained = YES;
    });
    XCTAssertTrue([self eventually:^BOOL { return drained; }]);
    XCTAssertEqual(recorder.snapshots.count, 1u, @"one waited for main, and none queued behind it");
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

// A load on a network mount reads ahead, its handle waiting for bytes as a
// stream's does, so it publishes its first block at once, before a read
// stalled on the server can hold it: a snapshot arrives while the decode
// waits. A cancel then ends that wait.
- (void)testAReadAheadLoadPublishesItsFirstBlockBeforeAStalledRead {
    NSURL *url = [self writeNoiseWAVNamed:@"network.wav" seconds:6.0 seed:17];
    _readAhead = [[VibeReadAheadScript alloc] initForPathsContaining:url.path];
    // The first decode read takes blocks 0 and 1; the second waits on block 2.
    [_readAhead stallFrom:2 * kReadAheadBlock];
    WaveformSnapshotRecorder *recorder = [[WaveformSnapshotRecorder alloc] init];
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] initWithDelegate:recorder];
    __block CodableAudioWaveform *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = [loader load:url.path];
        dispatch_semaphore_signal(done);
    });
    XCTAssertTrue([self await:_readAhead.stalled], @"the read-ahead stalled on block 2");
    XCTAssertTrue([self eventually:^BOOL { return recorder.snapshots.count >= 1; }],
                  @"the first block published while the next read waits");
    XCTAssertLessThan(recorder.fractions.firstObject.floatValue, 1.0f);
    XCTAssertFalse(loader.isComplete);
    [loader cancel];
    XCTAssertTrue([self await:done], @"the cancel ended the wait");
    XCTAssertNil(result);
}

#pragma mark - Through the cache

- (AudioWaveformCache *)cacheWithRecorder:(WaveformCacheRecorder *)recorder {
    NSString *root = [_tempDirectory URLByAppendingPathComponent:@"cache"].path;
    AudioWaveformCache *cache = [[AudioWaveformCache alloc] initWithRootPath:root];
    cache.delegate = recorder;
    return cache;
}

- (void)testCacheOnlyLookupMissesWithoutDecodingAndChecksAnalysisRequirements {
    NSURL *url = [self writeNoiseWAVNamed:@"preview.wav" seconds:2.0 seed:31];
    WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
    AudioWaveformCache *cache = [self cacheWithRecorder:recorder];
    AudioTrack *track = [AudioTrack withURL:url];
    __block BOOL settled = NO;
    [cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertNil(waveform);
        settled = YES;
    }];
    XCTAssertTrue([self eventually:^BOOL { return settled; }]);
    XCTAssertEqual(recorder.completions, 0u);
    XCTAssertEqual(recorder.progressions, 0u);
    XCTAssertEqual(recorder.failures, 0u);

    settled = NO;
    [cache cacheWaveformForURL:url completion:^(BOOL ok, BOOL wasCached, float bpm, NSInteger key) {
        XCTAssertTrue(ok);
        XCTAssertFalse(wasCached, @"the preview miss must not have populated the cache");
        settled = YES;
    }];
    XCTAssertTrue([self eventually:^BOOL { return settled; }]);
    settled = NO;
    [cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
        XCTAssertNotNil(waveform);
        XCTAssertTrue(waveform.waveform->isComplete());
        settled = YES;
    }];
    XCTAssertTrue([self eventually:^BOOL { return settled; }]);

    cache.analysisProvider = ^VibeWaveformAnalysis { return (VibeWaveformAnalysis){.bands = YES}; };
    settled = NO;
    [cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
        XCTAssertNil(waveform, @"a broadband entry cannot prepare a 3-Band page");
        settled = YES;
    }];
    XCTAssertTrue([self eventually:^BOOL { return settled; }]);
    cache.analysisProvider = nil;
    AudioTrack *cue = [[AudioTrack alloc] initWithURL:url cueStart:75 cueEnd:150
                                              title:nil performer:nil sheet:nil trackNumber:0];
    settled = NO;
    [cache cachedWaveformForTrack:cue completion:^(CodableAudioWaveform *waveform) {
        XCTAssertNil(waveform, @"a cue row cannot borrow its whole file's waveform");
        settled = YES;
    }];
    XCTAssertTrue([self eventually:^BOOL { return settled; }]);
}

- (void)testBlockedPreviewStatsLeaveThePlayingLookupFree {
    NSURL *url = [self writeNoiseWAVNamed:@"foreground.wav" seconds:1.0 seed:17];
    WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
    AudioWaveformCache *cache = [self cacheWithRecorder:recorder];
    AudioTrack *preview = [AudioTrack withURL:[_tempDirectory URLByAppendingPathComponent:@"blocked.wav"]];
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    Method method = class_getInstanceMethod(AudioTrack.class, @selector(cacheKey));
    IMP original = method_getImplementation(method);
    IMP held = imp_implementationWithBlock(^NSString *(AudioTrack *track) {
        if (track == preview) {
            dispatch_semaphore_signal(started);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
            return nil;
        }
        return ((NSString *(*)(id, SEL))original)(track, @selector(cacheKey));
    });
    __block NSUInteger replies = 0;
    method_setImplementation(method, held);
    @try {
        // More than the lookup lane's running and pending capacity.
        for (NSUInteger i = 0; i < 8; i++) {
            [cache cachedWaveformForTrack:preview completion:^(CodableAudioWaveform *waveform) {
                replies++;
            }];
        }
        XCTAssertTrue([self await:started]);
        [cache loadWaveformForTrack:[AudioTrack withURL:url]];
        XCTAssertTrue([self eventually:^BOOL { return recorder.completions || recorder.failures; }]);
        XCTAssertEqual(recorder.completions, 1u, @"preview stats must not occupy the playing lookup lane");
        XCTAssertEqual(recorder.failures, 0u);
    }
    @finally {
        for (NSUInteger i = 0; i < 8; i++) dispatch_semaphore_signal(release);
        XCTAssertTrue([self eventually:^BOOL { return replies == 8; }]);
        method_setImplementation(method, original);
        imp_removeBlock(held);
    }
}

- (void)testCacheOnlyLookupDoesNotDetachThePlayingTracksDecode {
    NSURL *source = [self writeNoiseWAVNamed:@"whole.wav" seconds:3.0 seed:17];
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:@"stream.wav"];
    WaveformStreamAvailability *stream = [self stream:source as:url prefix:128 * 1024];
    WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
    AudioWaveformCache *cache = [self cacheWithRecorder:recorder];
    [cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self await:stream.event]);
    __block BOOL settled = NO;
    [cache cachedWaveformForTrack:[AudioTrack withURL:source] completion:^(CodableAudioWaveform *waveform) {
        XCTAssertNil(waveform);
        settled = YES;
    }];
    XCTAssertTrue([self eventually:^BOOL { return settled; }]);
    [self complete:stream from:source as:url];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 1; }]);
    XCTAssertEqual(recorder.failures, 0u);
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
    NSUInteger count = reference.waveform->binCount();
    XCTAssertEqual(MatchingBins(recorder.complete, reference), count);

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
    XCTAssertEqual(MatchingBins(recorder.complete, reference), count);
}

// A headerless MP3 streams on a length counted from its head: a VBR one's an
// estimate from its frames, here under half its true length; one whose head
// is one rate and the rest another, that rate's count, as short; a constant
// one's, its rate's count, right. Each waveform decodes as the bytes arrive,
// laid out on that count, and is complete only once the length is exact: the
// constant one's pass ends there, the other two read on to the exact length
// once the download completes. So the waveform delivered and persisted is
// always laid out on the exact length, under the file's key.
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

// An estimate never costs a second decode: a bin's frames do not depend on
// the length, so the pass keeps what it read and ends on the exact length.
// Here four tail frames at a higher rate, past the head the estimate walks,
// make it one packet over, and eight two packets. Either way the waveform is
// delivered complete on the exact length and persisted under the file's key.
- (void)testAnEstimatedLengthEndsOnTheExactLength {
    const uint32_t frames = 12000, packet = 1152;
    for (NSNumber *tail in @[@4, @8]) {
        uint32_t fast = tail.unsignedIntValue;
        NSString *name = [NSString stringWithFormat:@"over-%u.mp3", fast];
        NSURL *source = [_tempDirectory URLByAppendingPathComponent:[@"whole-" stringByAppendingString:name]];
        // 128 kbps frames are 384 bytes at 48 kHz, 160 kbps ones 480: four of
        // the latter add one 128 kbps packet to the byte count, eight add two.
        NSData *bytes = VibeMP3WithoutVBRHeader(frames, 48000, ^uint8_t(uint32_t frame) {
            return frame >= frames - fast ? 10 : 9;
        });
        XCTAssertTrue([bytes writeToURL:source atomically:YES]);
        AVAudioFramePosition length = [[AudioFileHandle alloc] initForReading:source error:NULL].length;
        XCTAssertEqual(length, (AVAudioFramePosition)frames * packet);
        NSURL *url = [_tempDirectory URLByAppendingPathComponent:name];
        WaveformStreamAvailability *stream = [self stream:source as:url prefix:64 * 1024];
        NSUInteger window = 80 * 1024, at = bytes.length - window;
        [stream installWindow:[bytes subdataWithRange:NSMakeRange(at, window)] atOffset:at];
        WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
        AudioWaveformCache *cache = [self cacheWithRecorder:recorder];
        [AudioLoadTiming reset];
        [cache loadWaveformForTrack:[AudioTrack withURL:url]];
        XCTAssertTrue([self eventually:^BOOL { return recorder.progressions > 0; }], @"%@", name);
        XCTAssertEqual(recorder.completions, 0u, @"%@: nothing complete before the length is exact", name);
        [self complete:stream from:source as:url];
        XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 1; }], @"%@", name);
        XCTAssertEqual(recorder.failures, 0u, @"%@", name);
        XCTAssertEqualWithAccuracy([[AudioLoadTiming newestJSONForPath:url.path][@"audioSeconds"] doubleValue],
                                   (double)length / 48000, 1e-9, @"%@", name);
        XCTAssertEqual(recorder.complete.waveform->totalFrames(), length, @"%@: laid out on the exact length", name);
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
    NSUInteger count = first.waveform->binCount();
    XCTAssertEqual(MatchingBins(recorder.complete, first), count);

    [self writeNoiseWAVNamed:@"track.wav" seconds:2.5 seed:23];
    CodableAudioWaveform *second = [[[AudioWaveformLoader alloc] init] load:url.path];
    [cache loadWaveformForTrack:track];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 2; }]);
    XCTAssertEqual(MatchingBins(recorder.complete, first), count, @"the stale memo serves the old version");

    [AudioTrack invalidateMemoizedCacheKeys];
    [cache loadWaveformForTrack:track];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 3; }]);
    XCTAssertEqual(MatchingBins(recorder.complete, second), second.waveform->binCount(),
                   @"re-keyed, it misses and decodes the new one");
    XCTAssertEqual(recorder.failures, 0u);
}

// Turning tempo detection on reaches a file decoded while it was off: the
// entry records that it skipped the analyzer, so a request running it misses
// and decodes again, and the request after that is a hit on the new entry.
- (void)testAnEntryDecodedWithoutTempoMissesForARequestThatRunsIt {
    NSURL *url = [self writeNoiseWAVNamed:@"analysis.wav" seconds:2.0 seed:23];
    WaveformCacheRecorder *recorder = [[WaveformCacheRecorder alloc] init];
    AudioWaveformCache *cache = [self cacheWithRecorder:recorder];
    __block VibeWaveformAnalysis analysis = {};
    cache.analysisProvider = ^VibeWaveformAnalysis { return analysis; };

    [cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 1; }]);
    XCTAssertFalse(recorder.complete.bpmAnalyzed, @"decoded with detection off");

    analysis.bpm = YES;
    [cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 2; }]);
    XCTAssertTrue(recorder.complete.bpmAnalyzed, @"the skipped analysis is a miss, decoded again");

    analysis.bpm = NO;
    [cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return recorder.completions == 3; }]);
    XCTAssertTrue(recorder.complete.bpmAnalyzed, @"a request without it takes the analyzed entry");
}

@end
