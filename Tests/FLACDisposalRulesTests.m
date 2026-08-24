//
// Convert-to-FLAC disposal outcomes and location bookkeeping.
//

#import <XCTest/XCTest.h>

#import "FLACDisposalRules.h"

@interface FLACDisposalRulesTests : XCTestCase
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

@end
