//
//  DownloadProgressRulesTests.m
//

#import <XCTest/XCTest.h>

#import "DownloadProgressRules.h"

@interface DownloadProgressRulesTests : XCTestCase
@end

@implementation DownloadProgressRulesTests

- (void)testInitialZeroIsNotMovement {
    XCTAssertFalse(VibeDownloadProgressIsMovement(0, 0));
}

- (void)testFirstPositiveFractionIsMovement {
    XCTAssertTrue(VibeDownloadProgressIsMovement(0, 0.0001f));
}

- (void)testRepeatedFractionIsNotMovement {
    XCTAssertFalse(VibeDownloadProgressIsMovement(0.25f, 0.25f));
}

- (void)testBackwardFractionIsNotMovement {
    XCTAssertFalse(VibeDownloadProgressIsMovement(0.25f, 0.2f));
}

- (void)testSubPercentIncreaseIsMovement {
    XCTAssertTrue(VibeDownloadProgressIsMovement(0.25f, 0.2501f));
}

- (void)testNegativeZeroAndNonfiniteFractionsAreNotMovement {
    XCTAssertFalse(VibeDownloadProgressIsMovement(0, -0.0f));
    XCTAssertFalse(VibeDownloadProgressIsMovement(0, -0.1f));
    XCTAssertFalse(VibeDownloadProgressIsMovement(0, NAN));
    XCTAssertFalse(VibeDownloadProgressIsMovement(0, -INFINITY));
    XCTAssertFalse(VibeDownloadProgressIsMovement(0, INFINITY));
}

- (void)testDatalessPollYieldsToICloudPercentage {
    XCTAssertFalse(VibeDownloadPollShouldPublish(YES, YES, NO));
}

- (void)testDatalessPollYieldsToFileProviderPercentage {
    XCTAssertFalse(VibeDownloadPollShouldPublish(YES, NO, YES));
}

- (void)testDatalessPollPublishesWithoutAnExactSource {
    XCTAssertTrue(VibeDownloadPollShouldPublish(YES, NO, NO));
}

- (void)testMaterializedPollPublishesEvenBeforeExactSourcesDetach {
    XCTAssertTrue(VibeDownloadPollShouldPublish(NO, YES, YES));
}

@end
