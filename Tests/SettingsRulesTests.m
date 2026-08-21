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

- (void)testWaveformThemeNormalizesUnknownsToMono {
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"mono"), @"mono");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"orange"), @"orange");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"album_art"), @"album_art");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"custom"), @"custom");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(nil), @"mono");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@""), @"mono");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"Orange"), @"mono");
    XCTAssertEqualObjects(VibeNormalizedWaveformTheme(@"sonic_cirrus"), @"mono");
}

- (void)testWaveformDragBehaviorNormalizesUnknownsToDragWindow {
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"drag_window"), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"seek"), @"seek");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(nil), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@""), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"Seek"), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"classic"), @"drag_window");
}

// The one-time migration: only a themeless Sonic Cirrus user gets orange
// written; any stored theme key, right or wrong, means the decision is made.
- (void)testWaveformThemeMigrationDecision {
    XCTAssertEqualObjects(VibeMigratedWaveformTheme(nil, @"sonic_cirrus"), @"orange");
    XCTAssertNil(VibeMigratedWaveformTheme(nil, @"detailed"));
    XCTAssertNil(VibeMigratedWaveformTheme(nil, nil));
    XCTAssertNil(VibeMigratedWaveformTheme(@"mono", @"sonic_cirrus"));
    XCTAssertNil(VibeMigratedWaveformTheme(@"orange", @"sonic_cirrus"));
}

@end
