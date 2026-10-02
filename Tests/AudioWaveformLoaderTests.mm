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
#import "AudioFixtures.h"
#import "AudioWaveform.h"

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

@interface AudioWaveformLoaderTests : XCTestCase
@end

@implementation AudioWaveformLoaderTests {
    AudioWaveformLoader *_loader;
    NSURL *_tempDirectory;
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

@end
