//
// Convert-to-FLAC disposal outcomes and location bookkeeping.
//

#import <XCTest/XCTest.h>

#import "FLACDisposalRules.h"
#import "AudioFileConverterInternal.h"
#import "FLACTagCopier.h"
#import "VibeStrings.h"

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
    [self waitForExpectations:@[self.settled] timeout:1];
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
    [self waitForExpectations:@[first] timeout:1];
    XCTAssertEqualObjects(order, (@[@"request-one", @"cancel-one", @"cancel-two"]));
    XCTestExpectation *second = [self expectationWithDescription:@"second settlement"];
    [self.converter settleConversionWithURL:nil error:nil completion:^(NSURL *url, NSError *error) {
        [order addObject:@"request-two"];
        [second fulfill];
    }];
    [self waitForExpectations:@[second] timeout:1];
    XCTAssertEqualObjects(order, (@[@"request-one", @"cancel-one", @"cancel-two", @"request-two", @"new-cancel"]));
}

- (void)testIdleCancellationCompletesAsynchronously {
    __block NSUInteger completions = 0;
    XCTestExpectation *done = [self expectationWithDescription:@"idle cancel"];
    [self.converter cancelConversionWithCompletion:^{ completions++; [done fulfill]; }];
    XCTAssertEqual(completions, 0u);
    [self waitForExpectations:@[done] timeout:1];
    XCTAssertEqual(completions, 1u);
}
@end
