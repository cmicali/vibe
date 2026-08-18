//
//  ForegroundContentHoldRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "ForegroundContentHoldRules.h"

@interface ForegroundContentHoldRulesTests : XCTestCase
@end


@implementation ForegroundContentHoldRulesTests

- (void)testMatchingSettlementReleasesTheHold {
    XCTAssertTrue(VibeForegroundContentHoldMayRelease(8, 8));
}

- (void)testOlderPrefetchAcknowledgementCannotReleaseANewerPlayHold {
    NSUInteger firstPlay = 8;
    NSUInteger sameRowReplay = 9;
    XCTAssertFalse(VibeForegroundContentHoldMayRelease(firstPlay, sameRowReplay));
}

- (void)testTrackAndURLIdentityDoNotParticipateInTheDecision {
    NSUInteger oldPlayForSameURL = 20;
    NSUInteger replacementForSameURL = 21;
    XCTAssertFalse(VibeForegroundContentHoldMayRelease(
            oldPlayForSameURL, replacementForSameURL));
}

@end
