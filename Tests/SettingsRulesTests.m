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

- (void)testWaveformThemeNormalizesUnknownsToWhite {
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"white"), @"white");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"orange"), @"orange");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"album_art"), @"album_art");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"custom"), @"custom");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(nil), @"white");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@""), @"white");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"Orange"), @"white");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"sonic_cirrus"), @"white");
}

// The one-time migration: only a themeless Sonic Cirrus user gets orange
// written; any stored theme key, right or wrong, means the decision is made.
- (void)testWaveformThemeMigrationDecision {
    XCTAssertEqualObjects(VibeMigratedWaveformTheme(nil, @"sonic_cirrus"), @"orange");
    XCTAssertNil(VibeMigratedWaveformTheme(nil, @"detailed"));
    XCTAssertNil(VibeMigratedWaveformTheme(nil, nil));
    XCTAssertNil(VibeMigratedWaveformTheme(@"white", @"sonic_cirrus"));
    XCTAssertNil(VibeMigratedWaveformTheme(@"orange", @"sonic_cirrus"));
}

@end
