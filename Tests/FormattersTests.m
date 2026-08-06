//
// The duration strings every time label renders through.
//

#import <XCTest/XCTest.h>

#import "Formatters.h"

@interface FormattersTests : XCTestCase
@end

@implementation FormattersTests {
    Formatters *_formatters;
}

- (void)setUp {
    _formatters = [Formatters sharedInstance];
}

- (NSString *)stringFor:(NSTimeInterval)duration {
    return [_formatters durationStringFromTimeInterval:duration];
}

- (void)testSubMinuteDurationsKeepTheLeadingZeroMinute {
    XCTAssertEqualObjects([self stringFor:0], @"0:00");
    XCTAssertEqualObjects([self stringFor:9], @"0:09");
    XCTAssertEqualObjects([self stringFor:24], @"0:24");
    XCTAssertEqualObjects([self stringFor:59], @"0:59");
}

- (void)testMinutesAndSeconds {
    XCTAssertEqualObjects([self stringFor:60], @"1:00");
    XCTAssertEqualObjects([self stringFor:125], @"2:05");
    XCTAssertEqualObjects([self stringFor:599], @"9:59");
}

- (void)testSecondsAreTruncatedNotRounded {
    // The position label ticks with the playhead; rounding up would show a
    // second that hasn't happened yet.
    XCTAssertEqualObjects([self stringFor:24.9], @"0:24");
}

- (void)testHourLongFilesRollOverInsteadOfCountingMinutesForever {
    // DJ sets and live recordings: "90:00" is unreadable.
    XCTAssertEqualObjects([self stringFor:3599], @"59:59");
    XCTAssertEqualObjects([self stringFor:3600], @"1:00:00");
    XCTAssertEqualObjects([self stringFor:5400], @"1:30:00");
}

- (void)testTheHourIsNotZeroPadded {
    // DropLeading: "1:30:00", never "01:30:00".
    NSString *rendered = [self stringFor:5400];
    XCTAssertFalse([rendered hasPrefix:@"0"], @"got %@", rendered);
}

- (void)testDegenerateInputsRenderAsZeroRatherThanGarbage {
    // duration is -1 until the decode publishes a length, and a failed open
    // can leave it NaN; neither should reach the label as "-1:00" or "NaN".
    XCTAssertEqualObjects([self stringFor:NAN], @"0:00");
    XCTAssertEqualObjects([self stringFor:-1], @"0:00");
    XCTAssertEqualObjects([self stringFor:-3600], @"0:00");
}

- (void)testInfiniteDurationsAreSurvivable {
    // NSDateComponentsFormatter RAISES on a non-finite interval, so the guard
    // has to cover infinity (a zero sample rate) and not just NaN.
    XCTAssertEqualObjects([self stringFor:INFINITY], @"0:00");
    XCTAssertEqualObjects([self stringFor:-INFINITY], @"0:00");
}

- (void)testNeverReturnsNil {
    // The label binding has no nil branch.
    XCTAssertNotNil([self stringFor:0]);
    XCTAssertNotNil([self stringFor:5400]);
}

@end
