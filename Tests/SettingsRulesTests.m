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

- (void)testWindowTintNormalizesUnknownsToArtwork {
    XCTAssertEqualObjects(VibeNormalizedWindowTint(@"mono"), @"mono");
    XCTAssertEqualObjects(VibeNormalizedWindowTint(@"artwork"), @"artwork");
    XCTAssertEqualObjects(VibeNormalizedWindowTint(@"custom"), @"custom");
    XCTAssertEqualObjects(VibeNormalizedWindowTint(nil), @"artwork");
    XCTAssertEqualObjects(VibeNormalizedWindowTint(@""), @"artwork");
    XCTAssertEqualObjects(VibeNormalizedWindowTint(@"Mono"), @"artwork");
    XCTAssertEqualObjects(VibeNormalizedWindowTint(@"album_art"), @"artwork");
}

- (void)testWaveformDragBehaviorNormalizesUnknownsToDragWindow {
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"drag_window"), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"seek"), @"seek");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(nil), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@""), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"Seek"), @"drag_window");
    XCTAssertEqualObjects(VibeNormalizedWaveformDragBehavior(@"classic"), @"drag_window");
}

- (void)testArtworkDragActionNormalizesUnknownsToCopyFile {
    XCTAssertEqualObjects(VibeNormalizedArtworkDragAction(@"copy_file"), @"copy_file");
    XCTAssertEqualObjects(VibeNormalizedArtworkDragAction(@"copy_path"), @"copy_path");
    XCTAssertEqualObjects(VibeNormalizedArtworkDragAction(@"copy_artist_title"), @"copy_artist_title");
    XCTAssertEqualObjects(VibeNormalizedArtworkDragAction(nil), @"copy_file");
    XCTAssertEqualObjects(VibeNormalizedArtworkDragAction(@""), @"copy_file");
    XCTAssertEqualObjects(VibeNormalizedArtworkDragAction(@"Copy_Path"), @"copy_file");
    XCTAssertEqualObjects(VibeNormalizedArtworkDragAction(@"copy_name"), @"copy_file");
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

- (void)testSettingsAreAtDefaults {
    NSDictionary *registered = @{@"a": @(8), @"b": @"mono"};
    NSArray *nullable = @[@"color"];

    // Nothing stored, and a stored value equal to its default (a migration
    // writing the default back), both count as default.
    XCTAssertTrue(VibeSettingsAreAtDefaults(nil, registered, nullable));
    XCTAssertTrue(VibeSettingsAreAtDefaults(@{}, registered, nullable));
    XCTAssertTrue(VibeSettingsAreAtDefaults(@{@"a": @(8)}, registered, nullable));
    // Numeric equality, not type identity: a bool or double spelling of the
    // stored number still reads as the default.
    XCTAssertTrue(VibeSettingsAreAtDefaults(@{@"a": @(8.0)}, registered, nullable));
    // A key this app does not own changes nothing.
    XCTAssertTrue(VibeSettingsAreAtDefaults(@{@"NSQuitAlwaysKeepsWindows": @(YES)}, registered, nullable));

    XCTAssertFalse(VibeSettingsAreAtDefaults(@{@"a": @(16)}, registered, nullable));
    XCTAssertFalse(VibeSettingsAreAtDefaults(@{@"b": @"orange"}, registered, nullable));
    // A nullable key is non-default by existing, whatever its value.
    XCTAssertFalse(VibeSettingsAreAtDefaults(@{@"color": @"#FF8800"}, registered, nullable));
}

@end
