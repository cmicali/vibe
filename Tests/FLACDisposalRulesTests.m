#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "FLACDisposalRules.h"
#import "AudioFileConverterInternal.h"
#import "FLACTagCopier.h"
#import "VibeStrings.h"
#import "AudioFileHandle.h"
#import "AudioFixtures.h"

// The dormant encoder path must never escape into TagLib from these tests.
VibeUncompressedContainer VibeSniffUncompressedContainer(NSString *path) {
    [NSException raise:NSInternalInconsistencyException format:@"Unexpected TagLib read: %@", path];
    return VibeUncompressedContainerUnknown;
}
BOOL VibeCopyTagsToFLAC(NSString *source, NSString *output, VibeUncompressedContainer container) {
    [NSException raise:NSInternalInconsistencyException format:@"Unexpected TagLib copy: %@", source];
    return NO;
}

@interface FLACDisposalRulesTests : XCTestCase
@property AudioFileConverter *converter;
@property VibeFLACConversionRecord *record;
@property NSUndoManager *manager;
@property NSMutableArray<NSString *> *events;
@property NSMutableArray<NSDictionary *> *settlements;
@property (copy) void (^restoreReply)(BOOL, NSError *);
@property (copy) void (^verifyReply)(BOOL, NSError *);
@property (copy) void (^trashReply)(VibeTrashOutcome, NSURL *, NSError *);
@property XCTestExpectation *settled;
@end

@implementation FLACDisposalRulesTests

#pragma mark - Trash outcome

- (void)testFailedTrashHasAnExplicitOutcome {
    XCTAssertEqual(VibeTrashOutcomeForResult(NO, NO),
            VibeTrashOutcomeFailed);
}

- (void)testMovedTrashRecordsWhetherItsRestoreURLIsKnown {
    XCTAssertEqual(VibeTrashOutcomeForResult(YES, YES),
            VibeTrashOutcomeMovedKnownURL);
    XCTAssertEqual(VibeTrashOutcomeForResult(YES, NO),
            VibeTrashOutcomeMovedUnknownURL);
}

- (void)testFailedTrashDoesNotTrustAnAncillaryURL {
    XCTAssertEqual(VibeTrashOutcomeForResult(NO, YES),
            VibeTrashOutcomeFailed);
}

- (void)testDidMoveIncludesTheUnknownURLSuccess {
    XCTAssertFalse(VibeTrashOutcomeDidMove(VibeTrashOutcomeSkipped));
    XCTAssertFalse(VibeTrashOutcomeDidMove(VibeTrashOutcomeFailed));
    XCTAssertTrue(VibeTrashOutcomeDidMove(VibeTrashOutcomeMovedKnownURL));
    XCTAssertTrue(VibeTrashOutcomeDidMove(VibeTrashOutcomeMovedUnknownURL));
}

- (void)testTrashOutcomePreservesTheFilesCurrentLocation {
    XCTAssertEqual(VibeFLACFileLocationAfterTrash(VibeTrashOutcomeSkipped),
            VibeFLACFileLocationExpectedPath);
    XCTAssertEqual(VibeFLACFileLocationAfterTrash(VibeTrashOutcomeFailed),
            VibeFLACFileLocationExpectedPath);
    XCTAssertEqual(VibeFLACFileLocationAfterTrash(VibeTrashOutcomeMovedKnownURL),
            VibeFLACFileLocationKnownTrashURL);
    XCTAssertEqual(VibeFLACFileLocationAfterTrash(VibeTrashOutcomeMovedUnknownURL),
            VibeFLACFileLocationUnknownTrashURL);
}

- (void)testOnlyAFileRecordedAtTheExpectedPathMayBeDisposedThere {
    XCTAssertTrue(VibeFLACMayDisposeExpectedPath(
            VibeFLACFileLocationExpectedPath));
    XCTAssertFalse(VibeFLACMayDisposeExpectedPath(
            VibeFLACFileLocationKnownTrashURL));
    XCTAssertFalse(VibeFLACMayDisposeExpectedPath(
            VibeFLACFileLocationUnknownTrashURL));
}

- (void)setUp {
    [super setUp];
    self.events = NSMutableArray.array;
    self.settlements = NSMutableArray.array;
    self.manager = NSUndoManager.new;
    self.manager.groupsByEvent = NO;
    self.record = VibeFLACConversionRecord.new;
    self.record.sourceURL = [NSURL fileURLWithPath:@"/tests/source.wav"];
    self.record.outputURL = [NSURL fileURLWithPath:@"/tests/source.flac"];
    self.record.sourceTrashURL = [NSURL fileURLWithPath:@"/tests/trash/source.wav"];
    self.record.sourceLocation = VibeFLACFileLocationKnownTrashURL;
    self.record.outputLocation = VibeFLACFileLocationExpectedPath;
    self.record.sourceWasTrashed = YES;
    __weak __typeof__(self) weakSelf = self;
    self.converter = [[AudioFileConverter alloc] initWithRestore:^(NSURL *from, NSURL *to, void (^reply)(BOOL, NSError *)) {
        [weakSelf.events addObject:[@"restore:" stringByAppendingString:to.pathExtension]];
        weakSelf.restoreReply = reply;
    } verify:^(NSURL *url, void (^reply)(BOOL, NSError *)) {
        [weakSelf.events addObject:[@"verify:" stringByAppendingString:url.pathExtension]];
        weakSelf.verifyReply = reply;
    } trash:^(NSURL *url, void (^reply)(VibeTrashOutcome, NSURL *, NSError *)) {
        [weakSelf.events addObject:[@"trash:" stringByAppendingString:url.pathExtension]];
        weakSelf.trashReply = reply;
    }];
    [self.manager beginUndoGrouping];
    [self.converter registerUndoForConversion:self.record undoManager:self.manager
            swap:^(NSURL *from, NSURL *to) {
        [weakSelf.events addObject:[NSString stringWithFormat:@"swap:%@>%@", from.pathExtension, to.pathExtension]];
    } completion:^(BOOL committed, NSString *reason, NSURL *stranded, NSError *error) {
        XCTAssertFalse(weakSelf.converter.isUndoRedoInFlight);
        [weakSelf.events addObject:@"settled"];
        [weakSelf.settlements addObject:@{@"committed": @(committed), @"reason": reason ?: @"", @"stranded": stranded ?: NSNull.null}];
        [weakSelf.settled fulfill];
    }];
    [self.manager endUndoGrouping];
}

- (void)tearDown {
    self.restoreReply = nil;
    self.verifyReply = nil;
    self.trashReply = nil;
    [self.manager removeAllActions];
    self.converter = nil;
    [super tearDown];
}

- (void)restore:(BOOL)success {
    void (^reply)(BOOL, NSError *) = self.restoreReply;
    self.restoreReply = nil;
    XCTAssertNotNil(reply);
    reply(success, nil);
}
- (void)verify:(BOOL)success {
    void (^reply)(BOOL, NSError *) = self.verifyReply;
    self.verifyReply = nil;
    XCTAssertNotNil(reply);
    reply(success, nil);
}
- (void)trash:(VibeTrashOutcome)outcome {
    void (^reply)(VibeTrashOutcome, NSURL *, NSError *) = self.trashReply;
    self.trashReply = nil;
    XCTAssertNotNil(reply);
    reply(outcome, outcome == VibeTrashOutcomeMovedKnownURL ? [NSURL fileURLWithPath:@"/tests/trash/moved"] : nil, nil);
}

- (void)testUndoRedoOrdersRestoreVerificationSwapAndTrashAndKeepsTheInverse {
    XCTAssertTrue(self.manager.canUndo);
    XCTAssertTrue([self.manager.undoMenuItemTitle containsString:STR_MENU_CONVERT_TO_FLAC]);
    [self.manager undo];
    XCTAssertTrue(self.converter.isUndoRedoInFlight);
    XCTAssertTrue(self.manager.canRedo); // registered before the async move answers
    XCTAssertEqualObjects(self.events, (@[@"restore:wav"]));
    [self restore:YES];
    XCTAssertEqual(self.record.sourceLocation, VibeFLACFileLocationExpectedPath);
    XCTAssertNil(self.record.sourceTrashURL);
    XCTAssertEqualObjects(self.events, (@[@"restore:wav", @"verify:wav"]));
    [self verify:YES];
    XCTAssertEqualObjects(self.events.lastObject, @"trash:flac");
    XCTAssertEqual(self.settlements.count, 0u);
    [self trash:VibeTrashOutcomeMovedKnownURL];
    XCTAssertEqual(self.record.outputLocation, VibeFLACFileLocationKnownTrashURL);
    [self.manager redo];
    XCTAssertTrue(self.manager.canUndo);
    [self restore:YES];
    [self verify:YES];
    [self trash:VibeTrashOutcomeMovedKnownURL];
    XCTAssertEqualObjects(self.events, (@[@"restore:wav", @"verify:wav", @"swap:flac>wav", @"trash:flac", @"settled",
            @"restore:flac", @"verify:flac", @"swap:wav>flac", @"trash:wav", @"settled"]));
    XCTAssertEqual(self.settlements.count, 2u);
    XCTAssertEqual(self.record.sourceLocation, VibeFLACFileLocationKnownTrashURL);
}

- (void)testRestoreFailureDoesNotVerifySwapOrTrashAndLeavesRedo {
    [self.manager undo];
    [self restore:NO];
    XCTAssertEqualObjects(self.events, (@[@"restore:wav", @"settled"]));
    XCTAssertEqualObjects(self.settlements.lastObject[@"reason"], @"restore_failed");
    XCTAssertEqualObjects(self.settlements.lastObject[@"stranded"], self.record.sourceTrashURL);
    XCTAssertTrue(self.manager.canRedo);
    XCTAssertEqual(self.record.sourceLocation, VibeFLACFileLocationKnownTrashURL);
    // The failed undo's redo verifies the output but cannot dispose a source
    // already in Trash, even if an unrelated file now occupies its old path.
    [self.manager redo];
    [self verify:YES];
    XCTAssertEqualObjects(self.settlements.lastObject[@"reason"], @"already_at_target");
    XCTAssertFalse([self.events containsObject:@"trash:wav"]);
}

- (void)testUnplayableReplacementPreservesCurrentFileAfterSuccessfulRestore {
    [self.manager undo];
    [self restore:YES];
    [self verify:NO];
    XCTAssertEqualObjects(self.events, (@[@"restore:wav", @"verify:wav", @"settled"]));
    XCTAssertEqualObjects(self.settlements.lastObject[@"reason"], @"replacement_unavailable");
    XCTAssertEqual(self.record.sourceLocation, VibeFLACFileLocationExpectedPath);
    XCTAssertEqual(self.record.outputLocation, VibeFLACFileLocationExpectedPath);
}

- (void)testUnknownTrashLocationFailsClosedWithoutAnyFileOperation {
    self.record.sourceLocation = VibeFLACFileLocationUnknownTrashURL;
    self.record.sourceTrashURL = nil;
    self.settled = [self expectationWithDescription:@"unknown location settles"];
    [self.manager undo];
    [self waitForExpectations:@[self.settled] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(self.events, (@[@"settled"]));
    XCTAssertEqualObjects(self.settlements.lastObject[@"reason"], @"replacement_location_unknown");
}

- (void)testDisposalFailureCommitsTheSwapAndRedoUsesTheFileStillInPlace {
    [self.manager undo];
    [self restore:YES];
    [self verify:YES];
    [self trash:VibeTrashOutcomeFailed];
    XCTAssertEqualObjects(self.settlements.lastObject[@"committed"], @YES);
    XCTAssertEqual(self.record.outputLocation, VibeFLACFileLocationExpectedPath);
    [self.manager redo];
    XCTAssertEqualObjects(self.events.lastObject, @"verify:flac");
    [self verify:YES];
    [self trash:VibeTrashOutcomeMovedUnknownURL];
    XCTAssertEqual(self.record.sourceLocation, VibeFLACFileLocationUnknownTrashURL);
    XCTAssertNil(self.record.sourceTrashURL);
}

- (void)testRedoKeepsOriginalWhenTheAcceptedConversionKeptIt {
    self.record.sourceWasTrashed = NO;
    self.record.sourceLocation = VibeFLACFileLocationExpectedPath;
    self.record.sourceTrashURL = nil;
    [self.manager undo];
    [self verify:YES];
    [self trash:VibeTrashOutcomeMovedKnownURL];
    [self.manager redo];
    [self restore:YES];
    [self verify:YES];
    XCTAssertEqualObjects(self.settlements.lastObject[@"committed"], @YES);
    XCTAssertFalse([self.events containsObject:@"trash:wav"]);
}

- (void)testInverseArrivingWhileBusyDoesNotStartASecondFileChain {
    [self.manager undo];
    [self.manager redo];
    XCTAssertTrue(self.manager.canUndo);
    XCTAssertEqualObjects(self.events, (@[@"restore:wav"]));
    [self restore:YES];
    [self verify:YES];
    [self trash:VibeTrashOutcomeMovedKnownURL];
    XCTAssertEqual(self.settlements.count, 1u);
}

- (void)testCancelWaitersSettleOnceAfterTheirOwnRequestIncludingReentrantAccept {
    [self.converter beginConversionDeletingOriginal:NO];
    NSMutableArray *order = NSMutableArray.array;
    [self.converter cancelConversionWithCompletion:^{ [order addObject:@"cancel-one"]; }];
    [self.converter cancelConversionWithCompletion:^{ [order addObject:@"cancel-two"]; }];
    XCTAssertEqual(order.count, 0u);
    XCTestExpectation *first = [self expectationWithDescription:@"first settlement"];
    [self.converter settleConversionWithURL:nil error:nil completion:^(NSURL *url, NSError *error) {
        XCTAssertFalse(self.converter.isConverting);
        [order addObject:@"request-one"];
        [self.converter beginConversionDeletingOriginal:NO];
        [self.converter cancelConversionWithCompletion:^{ [order addObject:@"new-cancel"]; }];
        [first fulfill];
    }];
    [self waitForExpectations:@[first] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(order, (@[@"request-one", @"cancel-one", @"cancel-two"]));
    XCTestExpectation *second = [self expectationWithDescription:@"second settlement"];
    [self.converter settleConversionWithURL:nil error:nil completion:^(NSURL *url, NSError *error) {
        [order addObject:@"request-two"];
        [second fulfill];
    }];
    [self waitForExpectations:@[second] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(order, (@[@"request-one", @"cancel-one", @"cancel-two", @"request-two", @"new-cancel"]));
}

// A Quit issued from a main-queue block (the debug channel's quit) waits for
// the cancel inside that block, where the main dispatch queue never drains.
- (void)testCancelSettlesWhileAMainQueueBlockWaitsForIt {
    [self.converter beginConversionDeletingOriginal:NO];
    XCTestExpectation *done = [self expectationWithDescription:@"waited inside a main-queue block"];
    dispatch_async(dispatch_get_main_queue(), ^{
        __block BOOL cancelled = NO;
        [self.converter cancelConversionWithCompletion:^{ cancelled = YES; }];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self.converter settleConversionWithURL:nil error:nil completion:^(NSURL *url, NSError *error) {}];
        });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
        while (!cancelled && deadline.timeIntervalSinceNow > 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        }
        XCTAssertTrue(cancelled);
        XCTAssertFalse(self.converter.isConverting);
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testIdleCancellationCompletesAsynchronously {
    __block NSUInteger completions = 0;
    XCTestExpectation *done = [self expectationWithDescription:@"idle cancel"];
    [self.converter cancelConversionWithCompletion:^{ completions++; [done fulfill]; }];
    XCTAssertEqual(completions, 0u);
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(completions, 1u);
}
@end

#pragma mark - The encode itself

@interface FLACEncodeRoundTripTests : XCTestCase
@end

@implementation FLACEncodeRoundTripTests {
    NSURL *_directory;
    NSURL *_outputURL;
    AudioFileConverter *_converter;
}

- (void)setUp {
    [super setUp];
    _directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
    _outputURL = [_directory URLByAppendingPathComponent:@"encoded.flac"];
    _converter = [[AudioFileConverter alloc] initWithRestore:nil verify:nil trash:nil];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
    _converter = nil;
    [super tearDown];
}

// sample (n, c) at `bits`: full-scale noise with the limits in the first frames.
static int32_t VibeEncodeSample(uint32_t frame, uint32_t channel, int bits) {
    if (frame == 0) return -(1 << (bits - 1));
    if (frame == 1) return (1 << (bits - 1)) - 1;
    uint32_t state = (frame * 2654435761u) ^ (channel * 40503u);
    state = 1664525u * state + 1013904223u;
    return (int32_t)(state >> (32 - bits)) - (1 << (bits - 1));
}

// A WAV of `frames` frames: `bits` 16 or 24 integer, or 32 float with
// frame 1 exactly +1.0; for a name ending .aif, the integers as a
// little-endian (sowt) AIFF-C.
- (NSURL *)writeSourceNamed:(NSString *)name frames:(uint32_t)frames channels:(uint16_t)channels bits:(uint16_t)bits {
    NSMutableData *samples = [NSMutableData data];
    for (uint32_t frame = 0; frame < frames; frame++) {
        for (uint16_t channel = 0; channel < channels; channel++) {
            if (bits == 32) {
                float v = frame == 1 ? 1.0f : VibeEncodeSample(frame, channel, 24) / 8388608.0f + (frame > 1 ? 1e-9f : 0); // off the 24-bit grid
                [samples appendBytes:&v length:4];
            } else {
                int32_t v = VibeEncodeSample(frame, channel, bits);
                [samples appendBytes:&v length:bits / 8]; // little-endian low bytes
            }
        }
    }
    NSURL *url = [_directory URLByAppendingPathComponent:name];
    url = [name hasSuffix:@".aif"] ? VibeWriteSowtAIFF(url, samples, 48000, channels, bits)
                                   : VibeWriteWAV(url, samples, 48000, channels, bits, (uint32_t)samples.length);
    XCTAssertNotNil(url);
    return url;
}

// The whole encoded file back through the handle, checking the declared
// source depth and that the final partial packet is kept.
- (AVAudioPCMBuffer *)decode:(NSURL *)url expecting:(AVAudioFramePosition)frames depth:(AudioFormatFlags)depth {
    NSError *error = nil;
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatID, kAudioFormatFLAC);
    XCTAssertEqual(handle.fileFormat.streamDescription->mFormatFlags, depth);
    XCTAssertEqual(handle.length, frames);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:(AVAudioFrameCount)frames + 4608];
    XCTAssertTrue([handle readIntoBuffer:buffer error:&error], @"%@", error);
    XCTAssertEqual(buffer.frameLength, (AVAudioFrameCount)frames, @"the final partial packet is kept");
    return buffer;
}

- (void)testPlayableValidationRequiresADecodedFrame {
    NSURL *url = [self writeSourceNamed:@"verify.wav" frames:4800 channels:2 bits:16];
    NSError *error = nil;
    XCTAssertTrue([_converter playableFileAtURL:url error:&error]);
    XCTAssertNil(error);
    XCTAssertGreaterThan([[AudioFileHandle alloc] initForReading:url error:nil].length, 0);

    Method method = class_getInstanceMethod(AudioFileHandle.class, @selector(readIntoBuffer:error:));
    __block BOOL readSucceeds = NO;
    IMP replacement = imp_implementationWithBlock(^BOOL(AudioFileHandle *file, AVAudioPCMBuffer *buffer, NSError **readError) {
        buffer.frameLength = 0;
        return readSucceeds;
    });
    IMP original = method_setImplementation(method, replacement);
    @try {
        for (NSNumber *success in @[@NO, @YES]) {
            readSucceeds = success.boolValue;
            error = nil;
            XCTAssertFalse([_converter playableFileAtURL:url error:&error],
                           @"neither a read failure nor an empty successful read certifies playable audio");
            XCTAssertEqual(error.code, VibeConvertErrorReplacementUnavailable);
        }
    }
    @finally {
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}

- (void)testSixteenBitSourceRoundTripsExactlyAsASixteenBitFLAC {
    const uint32_t frames = 4608 * 3 + 777; // three packets and a partial one
    NSURL *source = [self writeSourceNamed:@"s16.wav" frames:frames channels:2 bits:16];
    NSError *error = nil;
    __block double last = 0;
    NSURL *flac = [_converter encodeSource:source toURL:_outputURL progress:^(double fraction) { last = fraction; } error:&error];
    XCTAssertNotNil(flac, @"%@", error);
    XCTAssertEqual(last, 1.0);
    AVAudioPCMBuffer *buffer = [self decode:flac expecting:frames depth:kAppleLosslessFormatFlag_16BitSourceData];
    for (uint32_t frame = 0; frame < frames; frame++) {
        for (uint32_t channel = 0; channel < 2; channel++) {
            if (buffer.floatChannelData[channel][frame] != VibeEncodeSample(frame, channel, 16) / 32768.0f) {
                XCTFail(@"frame %u channel %u differs", frame, channel);
                return;
            }
        }
    }
}

// A WAV, and a little-endian (sowt) AIFF-C, which CoreAudio's parser takes
// for 16-bit and 1.5 times as long.
- (void)testTwentyFourBitSourceRoundTripsExactlyAsATwentyFourBitFLAC {
    const uint32_t frames = 4608 + 1;
    for (NSString *name in @[@"s24.wav", @"s24.aif"]) {
        NSURL *source = [self writeSourceNamed:name frames:frames channels:2 bits:24];
        NSError *error = nil;
        NSURL *flac = [_converter encodeSource:source toURL:_outputURL progress:nil error:&error];
        XCTAssertNotNil(flac, @"%@: %@", name, error);
        AVAudioPCMBuffer *buffer = [self decode:flac expecting:frames depth:kAppleLosslessFormatFlag_24BitSourceData];
        for (uint32_t sample = 0; sample < buffer.frameLength * 2; sample++) {
            uint32_t frame = sample / 2, channel = sample % 2;
            float expected = VibeEncodeSample(frame, channel, 24) / 8388608.0f; // exact: 24 bits fit float32
            if (buffer.floatChannelData[channel][frame] != expected) {
                XCTFail(@"%@: frame %u channel %u: %g, expected %g", name, frame, channel, buffer.floatChannelData[channel][frame], expected);
                break;
            }
        }
    }
}

// Float is the one lossy case: a 24-bit FLAC, every sample within one
// 24-bit step of the source, +1.0 included, which the encoder wraps to -1.0
// when fed Int32 buffers. (A FLAC shorter than one 4608-frame packet
// cannot be reopened by CoreAudio's reader, whichever writer made it, so
// the fixture is longer than that.)
- (void)testFloatSourceBecomesATwentyFourBitFLACWithinAQuantum {
    const uint32_t frames = 4608 * 2 + 100;
    NSURL *source = [self writeSourceNamed:@"f32.wav" frames:frames channels:2 bits:32];
    NSError *error = nil;
    NSURL *flac = [_converter encodeSource:source toURL:_outputURL progress:nil error:&error];
    XCTAssertNotNil(flac, @"%@", error);
    AVAudioPCMBuffer *buffer = [self decode:flac expecting:frames depth:kAppleLosslessFormatFlag_24BitSourceData];
    for (uint32_t frame = 0; frame < frames; frame++) {
        for (uint32_t channel = 0; channel < 2; channel++) {
            float expected = frame == 1 ? 1.0f : VibeEncodeSample(frame, channel, 24) / 8388608.0f + 1e-9f;
            if (fabsf(buffer.floatChannelData[channel][frame] - expected) > 1.0f / 8388608.0f) {
                XCTFail(@"frame %u channel %u: %g, expected %g", frame, channel, buffer.floatChannelData[channel][frame], expected);
                return;
            }
        }
    }
}

// A PCM header that over-declares is clamped by the reader, so the source
// that ends early is a compressed one: a FLAC cut off after its header
// still declares its full length.
- (void)testASourceThatEndsEarlyIsRefusedAndLeavesNoTemp {
    NSURL *whole = [self writeSourceNamed:@"whole.wav" frames:4608 * 4 channels:2 bits:16];
    NSError *error = nil;
    NSURL *encoded = [_converter encodeSource:whole toURL:_outputURL progress:nil error:&error];
    XCTAssertNotNil(encoded, @"%@", error);
    NSData *bytes = [NSData dataWithContentsOfURL:encoded];
    [NSFileManager.defaultManager removeItemAtURL:encoded error:nil];
    NSURL *source = [_directory URLByAppendingPathComponent:@"short.flac"];
    XCTAssertTrue([[bytes subdataWithRange:NSMakeRange(0, bytes.length / 2)] writeToURL:source atomically:YES]);
    NSURL *flac = [_converter encodeSource:source toURL:_outputURL progress:nil error:&error];
    XCTAssertNil(flac);
    XCTAssertEqual(error.code, VibeConvertErrorEncodeFailed);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:_outputURL.path]);
}

- (void)testASourceWithNoFramesIsNotConvertible {
    NSURL *source = [self writeSourceNamed:@"none.wav" frames:0 channels:2 bits:16];
    NSError *error = nil;
    XCTAssertNil([_converter encodeSource:source toURL:_outputURL progress:nil error:&error]);
    XCTAssertEqual(error.code, VibeConvertErrorNotConvertible);
}

@end
