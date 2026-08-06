//
// Proves the harness itself runs: target wiring, XCTest linkage, the
// inherited prefix header. If this fails, nothing else in here is meaningful.
//

#import <XCTest/XCTest.h>

@interface SmokeTests : XCTestCase
@end

@implementation SmokeTests

- (void)testHarnessRuns {
    XCTAssertEqual(1 + 1, 2);
}

@end
