//
//  PlatformColorTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import "PlatformColor.h"

@interface PlatformColorTests : XCTestCase
@end

@implementation PlatformColorTests

- (void)testHexRoundTrip {
    NSArray<NSString *> *hexes = @[@"#000000", @"#FFFFFF", @"#FF7300", @"#1A2B3C"];
    for (NSString *hex in hexes) {
        VibeColor *color = VibeColorFromHexString(hex);
        XCTAssertNotNil(color, @"%@", hex);
        XCTAssertEqualObjects(VibeHexStringFromColor(color), hex);
    }
}

- (void)testParseAcceptsBareAndPrefixedDigits {
    XCTAssertNotNil(VibeColorFromHexString(@"ff7300"));
    XCTAssertEqualObjects(VibeHexStringFromColor(VibeColorFromHexString(@"ff7300")), @"#FF7300");
}

- (void)testAlphaRoundTripsAsEightDigits {
    VibeColor *translucent = VibeColorFromHexString(@"#FF7300BF");
    XCTAssertNotNil(translucent);
    XCTAssertEqualWithAccuracy(CGColorGetAlpha(translucent.CGColor), 0.75, 0.01);
    XCTAssertEqualObjects(VibeHexStringFromColor(translucent), @"#FF7300BF");
    // Opaque emits the short form, so pre-alpha stored values are unchanged.
    XCTAssertEqualObjects(VibeHexStringFromColor(VibeColorFromHexString(@"#FF7300FF")), @"#FF7300");
    XCTAssertEqualWithAccuracy(CGColorGetAlpha(VibeColorFromHexString(@"#FFFFFF00").CGColor), 0, 0.001);
}

- (void)testGarbageParsesToNil {
    XCTAssertNil(VibeColorFromHexString(nil));
    XCTAssertNil(VibeColorFromHexString(@""));
    XCTAssertNil(VibeColorFromHexString(@"#FFF"));
    XCTAssertNil(VibeColorFromHexString(@"#GGGGGG"));
    XCTAssertNil(VibeColorFromHexString(@"#FFFFFF0"));
    XCTAssertNil(VibeColorFromHexString(@"#FFFFFF000"));
    XCTAssertNil(VibeColorFromHexString(@"not a color"));
    XCTAssertNil(VibeColorFromHexString(@"-1234567"));
}

- (void)testHexFromNilColorIsNil {
    XCTAssertNil(VibeHexStringFromColor(nil));
}

@end
