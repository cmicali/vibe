//
//  IntegerTokenRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "IntegerTokenRules.h"

@interface IntegerTokenRulesTests : XCTestCase
@end

@implementation IntegerTokenRulesTests

- (void)testDigitsParse {
    NSUInteger value = 7;
    XCTAssertTrue(VibeParseNonnegativeInteger(@"0", &value));
    XCTAssertEqual(value, 0u);
    XCTAssertTrue(VibeParseNonnegativeInteger(@"4096", &value));
    XCTAssertEqual(value, 4096u);
}

- (void)testAnythingButDigitsIsRefusedAndLeavesTheValue {
    for (NSString *token in @[@"", @"-1", @"+1", @" 1", @"1 ", @"1.5", @"12k", @"0x10"]) {
        NSUInteger value = 7;
        XCTAssertFalse(VibeParseNonnegativeInteger(token, &value), @"%@", token);
        XCTAssertEqual(value, 7u, @"%@", token);
    }
}

- (void)testTheLargestValueParsesAndOneMoreIsRefused {
    NSUInteger value = 0;
    NSString *max = [NSString stringWithFormat:@"%lu", (unsigned long)NSUIntegerMax];
    XCTAssertTrue(VibeParseNonnegativeInteger(max, &value));
    XCTAssertEqual(value, NSUIntegerMax);
    XCTAssertFalse(VibeParseNonnegativeInteger(@"18446744073709551616", &value));
}

@end
