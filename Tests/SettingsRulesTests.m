//
// The normalize-on-read rules a stored setting is snapped to, so a value no
// pane can produce — an external `defaults write`, or one left by an older
// build — cannot leave the pane displaying one thing while the engine uses
// another.
//

#import <XCTest/XCTest.h>

#import "SettingsRules.h"
#import "AppSettingsInternal.h"
#import "AppSettings+Mac.h"

@interface SettingsRulesTests : XCTestCase
@end

@implementation SettingsRulesTests

- (void)tearDown {
    [AppSettings.sharedInstance resetToDefaults];
    [super tearDown];
}

- (AppSettings *)freshSettings {
    [AppSettings.sharedInstance resetToDefaults];
    return AppSettings.sharedInstance;
}

// Exercise the persisted getters, not a second copy of the snapping rule.
// Midpoint ties favor the smaller preset; extreme external values must not
// overflow the distance calculation and choose the opposite end of a ladder.
- (void)testStoredPresetValuesClampAndBreakTiesDownward {
    AppSettings *settings = [self freshSettings];
    NSArray *cases = @[
        @[@"skipBaseBars", @[@[@(NSIntegerMin), @4], @[@6, @4], @[@7, @8],
                            @[@12, @8], @[@13, @16], @[@(NSIntegerMax), @16]]],
        @[@"crossfadeMilliseconds", @[@[@(NSIntegerMin), @10], @[@255, @10],
                            @[@256, @500], @[@1250, @500], @[@1251, @2000],
                            @[@(NSIntegerMax), @2000]]],
        @[@"uiUpdateHzCap", @[@[@(NSIntegerMin), @3], @[@16, @3], @[@17, @30],
                            @[@45, @30], @[@46, @60], @[@(NSIntegerMax), @60]]]
    ];
    for (NSArray *settingCase in cases) {
        for (NSArray *pair in settingCase[1]) {
            [settings setValue:pair[0] forKey:settingCase[0]];
            XCTAssertEqualObjects([settings valueForKey:settingCase[0]], pair[1], @"%@ %@", settingCase[0], pair[0]);
            XCTAssertEqualObjects([[AppSettings new] valueForKey:settingCase[0]], pair[1]);
        }
    }
}

- (void)testAppearancePreviewIsTransientAndExplicitChoiceClearsIt {
    AppSettings *settings = [self freshSettings];
    XCTAssertNil(settings.windowAppearance);
    settings.windowAppearanceStyle = @"dark";
    settings.windowAppearancePreviewStyle = @"light";
    XCTAssertEqualObjects(settings.windowAppearance.name, NSAppearanceNameAqua);
    XCTAssertEqualObjects(settings.windowAppearanceStyle, @"dark");
    XCTAssertNil([AppSettings new].windowAppearancePreviewStyle);
    XCTAssertEqualObjects([AppSettings new].windowAppearance.name, NSAppearanceNameDarkAqua);
    settings.windowAppearanceStyle = @"dark";
    XCTAssertNil(settings.windowAppearancePreviewStyle);
    XCTAssertEqualObjects(settings.windowAppearance.name, NSAppearanceNameDarkAqua);
    settings.windowAppearanceStyle = @"unknown";
    XCTAssertNil(settings.windowAppearance);
}

- (void)testEndingPreviewRestoresStoredAppearance {
    AppSettings *settings = [self freshSettings];
    for (NSString *style in @[@"", @"light", @"dark"]) {
        settings.windowAppearanceStyle = style;
        NSAppearance *stored = settings.windowAppearance;
        settings.windowAppearancePreviewStyle = @"dark";
        settings.windowAppearancePreviewStyle = nil;
        XCTAssertEqualObjects(settings.windowAppearance.name, stored.name);
    }
}

- (void)testSingleModeThemeOutranksBothPreviewAndStoredAppearance {
    AppSettings *settings = [self freshSettings];
    settings.windowAppearanceStyle = @"light";
    settings.windowAppearancePreviewStyle = @"light";
    settings.currentTheme.mode = @"single";
    [settings currentThemeDidChange];
    XCTAssertEqualObjects(settings.windowAppearance.name, NSAppearanceNameDarkAqua);
    XCTAssertEqualObjects(settings.windowAppearanceStyle, @"light");
    settings.currentTheme.mode = @"dual";
    [settings currentThemeDidChange];
    XCTAssertEqualObjects(settings.windowAppearance.name, NSAppearanceNameAqua);
}

- (void)testThemeApplicationKeepsCommonPlaybackAndWaveformSettings {
    AppSettings *settings = [self freshSettings];
    settings.pauseAtTrackEnd = YES;
    settings.crossfadeMilliseconds = 500;
    settings.waveformNormalize = NO;
    settings.waveformGainDB = 3.3;
    settings.folderOpenSort = VibeFolderOpenSortNewestFirst;
    NSString *theme = [settings addUserThemeWithRecord:@{@"waveformTheme": @"orange"} name:@"Levels"];
    [settings applyThemeWithIdentifier:theme];
    [settings applyThemeWithIdentifier:@"vibe"];
    AppSettings *reloaded = [AppSettings new];
    XCTAssertTrue(reloaded.pauseAtTrackEnd);
    XCTAssertEqual(reloaded.crossfadeMilliseconds, 500);
    XCTAssertFalse(reloaded.waveformNormalize);
    XCTAssertEqual(reloaded.waveformGainDB, 3.5);
    XCTAssertEqual(reloaded.folderOpenSort, VibeFolderOpenSortNewestFirst);
}

- (void)testExternalSharedSettingsNormalizeOnRead {
    AppSettings *settings = [self freshSettings];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@"date" forKey:SETTING_FOLDER_OPEN_SORT];
    XCTAssertEqual(settings.folderOpenSort, VibeFolderOpenSortName);
    [defaults setDouble:30 forKey:SETTING_WAVEFORM_GAIN_DB];
    XCTAssertEqual(settings.waveformGainDB, kVibeWaveformGainMaxDB);
    [defaults setDouble:-6.74 forKey:SETTING_WAVEFORM_GAIN_DB];
    XCTAssertEqual(settings.waveformGainDB, -6.5);
    settings.waveformDragBehavior = @"Seek";
    settings.artworkDragAction = @"copy_name";
    XCTAssertEqualObjects(settings.waveformDragBehavior, @"drag_window");
    XCTAssertEqualObjects(settings.artworkDragAction, @"copy_file");
}

- (void)testResetRestoresDerivedSettingsAndLeavesOtherStoresAlone {
    AppSettings *settings = [self freshSettings];
    NSString *foreignKey = @"SettingsRulesTests.foreignStore";
    [NSUserDefaults.standardUserDefaults setObject:@"keep" forKey:foreignKey];
    @try {
        XCTAssertTrue(settings.allSettingsAtDefaults);
        settings.audioFXEnabled = NO;
        settings.pauseAtTrackEnd = YES;
        settings.windowAppearanceStyle = @"light";
        settings.crossfadeMilliseconds = 2000;
        settings.waveformGainDB = 7;
        XCTAssertFalse(settings.allSettingsAtDefaults);
        [settings resetToDefaults];
        XCTAssertTrue(settings.allSettingsAtDefaults);
        XCTAssertTrue(settings.audioFXEnabled);
        XCTAssertFalse(settings.pauseAtTrackEnd);
        XCTAssertNil(settings.windowAppearance);
        XCTAssertEqual(settings.crossfadeMilliseconds, 10);
        XCTAssertEqual(settings.waveformGainDB, 0);
        XCTAssertEqualObjects([NSUserDefaults.standardUserDefaults objectForKey:foreignKey], @"keep");
    } @finally {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:foreignKey];
    }
}

// The store is keyed by device UID and never asks whether the device is
// present, which is what lets an unplugged device keep its modes.
- (void)testOutputModesAreRememberedPerDeviceAndOffStoresNothing {
    AppSettings *settings = [self freshSettings];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *key = @"AudioPlayer.outputModesByDeviceUID";

    settings.bitPerfectOutput = YES; // System Output has no UID to remember it under
    XCTAssertFalse(settings.bitPerfectOutput);
    XCTAssertNil([defaults objectForKey:key]);

    settings.audioOutputDeviceUID = @"dac";
    settings.bitPerfectOutput = YES;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    settings.exclusiveOutput = YES;
    XCTAssertTrue(settings.exclusiveOutput);
#endif
    XCTAssertTrue(settings.bitPerfectOutput);
    XCTAssertFalse(settings.audioFXAllowed);

    // The fallback after an unplug: the saved device moves, nothing is written.
    settings.audioOutputDeviceUID = @"";
    XCTAssertFalse(settings.bitPerfectOutput);
    XCTAssertFalse(settings.exclusiveOutput);
    XCTAssertTrue(settings.audioFXAllowed);
    settings.audioOutputDeviceUID = @"speakers";
    XCTAssertFalse(settings.bitPerfectOutput);
    XCTAssertTrue([settings bitPerfectOutputForDeviceUID:@"dac"]);

    settings.audioOutputDeviceUID = @"dac";
    XCTAssertTrue(settings.bitPerfectOutput);
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    // Exclusive survives a bit-perfect toggle, so the entry stays for it alone.
    settings.bitPerfectOutput = NO;
    XCTAssertEqualObjects([defaults dictionaryForKey:key], @{@"dac": @{@"exclusive": @YES}});
    settings.exclusiveOutput = NO;
#else
    settings.bitPerfectOutput = NO;
#endif
    XCTAssertNil([defaults objectForKey:key]);
    settings.bitPerfectOutput = YES;
    [settings resetToDefaults];
    XCTAssertNil([defaults objectForKey:key]);

    [defaults setObject:@{@"dac": @"yes"} forKey:key]; // an external write of the wrong shape
    settings.audioOutputDeviceUID = @"dac";
    XCTAssertFalse(settings.bitPerfectOutput);
    settings.bitPerfectOutput = YES;
    XCTAssertTrue(settings.bitPerfectOutput);
}

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

- (void)testDockIconNormalizesUnknownsToAlbumArt {
    XCTAssertEqualObjects(VibeNormalizedDockIcon(@"album_art"), @"album_art");
    XCTAssertEqualObjects(VibeNormalizedDockIcon(@"app_icon"), @"app_icon");
    XCTAssertEqualObjects(VibeNormalizedDockIcon(nil), @"album_art");
    XCTAssertEqualObjects(VibeNormalizedDockIcon(@"App Icon"), @"album_art");
}

// The editor's glyph menus offer only symbols this macOS draws, and every
// play pick has a pause partner that is also a real symbol; a play glyph
// outside the table pairs with the factory pause, never with itself.
- (void)testGlyphChoicesAreRealSymbolsWithPausePartners {
    for (NSString *glyph in [VibePlaylistButtonGlyphs() arrayByAddingObjectsFromArray:VibeNextButtonGlyphs()]) {
        XCTAssertNotNil([NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil], @"%@", glyph);
    }
    XCTAssertEqualObjects(VibePlayButtonGlyphs().firstObject, @"play.fill");
    for (NSArray<NSString *> *pair in VibePlayPauseGlyphPairs()) {
        NSString *play = pair[0], *pause = pair[1];
        XCTAssertNotNil([NSImage imageWithSystemSymbolName:play accessibilityDescription:nil], @"%@", play);
        XCTAssertNotNil([NSImage imageWithSystemSymbolName:pause accessibilityDescription:nil], @"%@", pause);
        XCTAssertNotEqualObjects(play, pause);
        XCTAssertEqualObjects(VibePauseGlyphForPlayGlyph(play), pause);
    }
    XCTAssertEqualObjects(VibePauseGlyphForPlayGlyph(@"play.fill"), @"pause.fill");
    XCTAssertEqualObjects(VibePauseGlyphForPlayGlyph(@"hand.raised"), @"pause.fill");
    XCTAssertEqualObjects(VibePauseGlyphForPlayGlyph(nil), @"pause.fill");
}

- (void)testWaveformGainClampsAndLandsOnHalfDecibels {
    XCTAssertEqual(VibeNormalizedWaveformGainDB(0), 0);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(3.5), 3.5);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(3.3), 3.5);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(3.2), 3.0);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(-6.74), -6.5);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(-0.2), 0);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(40), kVibeWaveformGainMaxDB);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(-40), -kVibeWaveformGainMaxDB);
    XCTAssertEqual(VibeNormalizedWaveformGainDB(NAN), 0);
}

- (void)testFolderOpenSortNormalizesUnknownsToName {
    XCTAssertEqual(VibeNormalizedFolderOpenSort(@"name"), VibeFolderOpenSortName);
    XCTAssertEqual(VibeNormalizedFolderOpenSort(@"newest_first"), VibeFolderOpenSortNewestFirst);
    XCTAssertEqual(VibeNormalizedFolderOpenSort(@"as_received"), VibeFolderOpenSortAsReceived);
    XCTAssertEqual(VibeNormalizedFolderOpenSort(nil), VibeFolderOpenSortName);
    XCTAssertEqual(VibeNormalizedFolderOpenSort(@""), VibeFolderOpenSortName);
    XCTAssertEqual(VibeNormalizedFolderOpenSort(@"Newest_First"), VibeFolderOpenSortName);
    XCTAssertEqual(VibeNormalizedFolderOpenSort(@"date"), VibeFolderOpenSortName);
}

// The identifier is what is persisted, so the pair has to round-trip: a getter
// that could not read back its own setter would reset the choice on relaunch.
- (void)testFolderOpenSortIdentifierRoundTrips {
    for (VibeFolderOpenSort sort = VibeFolderOpenSortName;
         sort <= VibeFolderOpenSortAsReceived; sort++) {
        XCTAssertEqual(VibeNormalizedFolderOpenSort(VibeFolderOpenSortIdentifier(sort)), sort);
    }
    XCTAssertEqualObjects(VibeFolderOpenSortIdentifier(VibeFolderOpenSortNewestFirst),
                          @"newest_first");
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
