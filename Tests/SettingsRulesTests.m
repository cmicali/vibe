//
// The normalize-on-read rules a stored setting is snapped to, so a value no
// pane can produce — an external `defaults write`, or one left by an older
// build — cannot leave the pane displaying one thing while the engine uses
// another.
//

#import <XCTest/XCTest.h>

#import "SettingsRules.h"

@interface SettingsRulesTests : XCTestCase
@end

@implementation SettingsRulesTests

- (void)testPitchRangeNormalizesToSupportedValues {
    XCTAssertEqual(VibeNormalizedPitchRange(8), 8);
    XCTAssertEqual(VibeNormalizedPitchRange(16), 16);
    XCTAssertEqual(VibeNormalizedPitchRange(0), 8);
    XCTAssertEqual(VibeNormalizedPitchRange(-16), 8);
    XCTAssertEqual(VibeNormalizedPitchRange(32), 8);
}

@end
