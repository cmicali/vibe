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

- (void)testGarbageParsesToNil {
    XCTAssertNil(VibeColorFromHexString(nil));
    XCTAssertNil(VibeColorFromHexString(@""));
    XCTAssertNil(VibeColorFromHexString(@"#FFF"));
    XCTAssertNil(VibeColorFromHexString(@"#GGGGGG"));
    XCTAssertNil(VibeColorFromHexString(@"#FFFFFF00"));
    XCTAssertNil(VibeColorFromHexString(@"not a color"));
    XCTAssertNil(VibeColorFromHexString(@"-1234567"));
}

- (void)testHexFromNilColorIsNil {
    XCTAssertNil(VibeHexStringFromColor(nil));
}

@end
