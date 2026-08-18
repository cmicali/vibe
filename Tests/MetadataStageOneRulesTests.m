//
//  The scan's stage-one arrival barrier: enumeration and every discovered
//  cache check must settle before a content-reading stage-two miss can run.
//

#import <XCTest/XCTest.h>

#import "MetadataStageOneRules.h"

@interface MetadataStageOneRulesTests : XCTestCase
@end

@implementation MetadataStageOneRulesTests

- (void)testAZeroCountDuringEnumerationIsNotACompletedSweep {
    VibeMetadataStageOneState state = VibeMetadataStageOneStateMake();
    VibeMetadataStageOneBeginCheck(&state);
    VibeMetadataStageOneFinishCheck(&state);

    XCTAssertFalse(VibeMetadataStageTwoCanDispatch(state, 1));

    VibeMetadataStageOneBeginCheck(&state);
    VibeMetadataStageOneFinishEnumeration(&state);
    XCTAssertFalse(VibeMetadataStageTwoCanDispatch(state, 1));
    VibeMetadataStageOneFinishCheck(&state);
    XCTAssertTrue(VibeMetadataStageTwoCanDispatch(state, 1));
}

- (void)testAdversarialCheckCompletionOrderWaitsForTheLastCheck {
    VibeMetadataStageOneState state = VibeMetadataStageOneStateMake();
    for (NSUInteger index = 0; index < 20; index++) {
        VibeMetadataStageOneBeginCheck(&state);
    }
    VibeMetadataStageOneFinishEnumeration(&state);

    for (NSUInteger index = 19; index > 0; index--) {
        VibeMetadataStageOneFinishCheck(&state);
        XCTAssertFalse(VibeMetadataStageTwoCanDispatch(state, 20));
    }
    VibeMetadataStageOneFinishCheck(&state);
    XCTAssertTrue(VibeMetadataStageTwoCanDispatch(state, 20));
}

- (void)testZeroTrackSweepHasNothingToDispatch {
    VibeMetadataStageOneState state = VibeMetadataStageOneStateMake();
    VibeMetadataStageOneFinishEnumeration(&state);

    XCTAssertFalse(VibeMetadataStageTwoCanDispatch(state, 0));
}

- (void)testCancellationIsTerminalEvenWhenAWorkerFinishesLate {
    VibeMetadataStageOneState state = VibeMetadataStageOneStateMake();
    VibeMetadataStageOneBeginCheck(&state);
    VibeMetadataStageOneBeginCheck(&state);
    VibeMetadataStageOneCancel(&state);
    VibeMetadataStageOneFinishCheck(&state);

    XCTAssertTrue(state.cancelled);
    XCTAssertEqual(state.outstandingChecks, 0u);
    XCTAssertFalse(VibeMetadataStageTwoCanDispatch(state, 2));
}

@end

