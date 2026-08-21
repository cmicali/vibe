//
// Fixed-slot admission without pre-dispatched pending work.
//

#import <XCTest/XCTest.h>

#import "AudioWorkAdmissionRules.h"

@interface AudioWorkAdmissionRulesTests : XCTestCase
@end

@implementation AudioWorkAdmissionRulesTests

- (void)testFreeSlotStartsImmediately {
    XCTAssertEqual(VibeAudioWorkAdmission(1, 2, 0, 1), VibeAudioWorkAdmissionStart);
}

- (void)testSaturatedWorkersUseOnlyTheExplicitPendingBudget {
    XCTAssertEqual(VibeAudioWorkAdmission(2, 2, 0, 1), VibeAudioWorkAdmissionPark);
    XCTAssertEqual(VibeAudioWorkAdmission(2, 2, 1, 1), VibeAudioWorkAdmissionExhausted);
}

- (void)testZeroPendingBudgetRejectsInsteadOfQueueing {
    XCTAssertEqual(VibeAudioWorkAdmission(1, 1, 0, 0), VibeAudioWorkAdmissionExhausted);
}

- (void)testAdmissionDeadlineIsInclusive {
    XCTAssertFalse(VibeAudioWorkAdmissionExpired(9.999, 10));
    XCTAssertTrue(VibeAudioWorkAdmissionExpired(10, 10));
    XCTAssertTrue(VibeAudioWorkAdmissionExpired(11, 10));
}

@end
