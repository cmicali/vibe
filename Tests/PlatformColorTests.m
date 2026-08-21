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

// NSScanner's leniency, which the digit count alone does not catch: it skips
// leading whitespace and accepts an 0x prefix, so an eight-character "0x123456"
// once scanned clean and read as RRGGBBAA.
- (void)testScannerLeniencyIsRefused {
    XCTAssertNil(VibeColorFromHexString(@"0x123456"));
    XCTAssertNil(VibeColorFromHexString(@"0X123456"));
    XCTAssertNil(VibeColorFromHexString(@" 23456"));
    XCTAssertNil(VibeColorFromHexString(@"#  7300"));
    XCTAssertNil(VibeColorFromHexString(@"\tFF7300"));
    XCTAssertNil(VibeColorFromHexString(@"+F7300"));
}

- (void)testHexFromNilColorIsNil {
    XCTAssertNil(VibeHexStringFromColor(nil));
}

@end
