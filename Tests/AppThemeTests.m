//
// AppTheme's record contract: the same sanitization gates a JSON import, a
// stored record and a UI edit, records stay sparse against the defaults, and
// the built-ins are exactly what they claim — vibe the empty record,
// sonic_cirrus its waveform overrides.
//

#import <XCTest/XCTest.h>

#import "AppTheme.h"
#import "SettingsRules.h"
#import "AppTheme+Archive.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AppSettingsInternal.h"
#import "PlatformColor.h"
#import "SettingsAppearanceViewController+Editor.h"

@interface AppThemeTests : XCTestCase
@end

@implementation AppThemeTests {
    NSString *_artDir;
    NSString *_suiteArtDir;
    AppSettings *_editingSettings;
}

// A directory per test, so one test's stored images cannot be found by the
// next. The suite-wide redirect (TestFilesystemGuard.m) is already in force;
// this narrows it rather than establishing it.
- (void)setUp {
    _suiteArtDir = @(getenv("VIBE_THEME_ART_DIR") ?: "");
    _artDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"VibeThemeArtTest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    setenv("VIBE_THEME_ART_DIR", _artDir.UTF8String, 1);
}

- (void)tearDown {
    [_editingSettings factoryReset];
    [NSFileManager.defaultManager removeItemAtPath:_artDir error:NULL];
    // TRAP: restore, never unsetenv. The suite is unsandboxed, so an unset
    // path resolves to the developer's real ~/Library, and the file lands
    // under whichever test class runs next, not this one.
    setenv("VIBE_THEME_ART_DIR", _suiteArtDir.UTF8String, 1);
}


#pragma mark Defaults and sparseness

- (void)testEmptyRecordIsTheDefaultLook {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    XCTAssertEqualObjects(theme.waveformStyle, @"oversampling_detailed_x4");
    XCTAssertEqualObjects(theme.waveformTheme, @"mono");
    XCTAssertEqualObjects(theme.windowTint, @"artwork");
    XCTAssertEqualObjects(theme.playlistTint, @"mono");
    XCTAssertEqualObjects(theme.windowBackgroundStyle, @"glass");
    XCTAssertEqualObjects(theme.playlistBackgroundStyle, @"glass");
    XCTAssertEqual(theme.windowCornerRadius, 16);
    XCTAssertFalse(theme.customCornerRadius);
    XCTAssertEqual(theme.resolvedWindowCornerRadius, 16);
    XCTAssertEqualObjects(theme.dockIcon, @"album_art");
    XCTAssertTrue(theme.appIconShape);
    XCTAssertEqualObjects(theme.buttonGradient, @"always");
    XCTAssertEqualObjects(theme.volumeBar, @"waveform");
    XCTAssertTrue(theme.showVolumeLabels);
    XCTAssertEqualObjects(theme.volumeLocation, @"top_right");
    XCTAssertEqualObjects(theme.playlistButtonGlyph, @"list.bullet");
    XCTAssertEqualObjects(theme.playButtonGlyph, @"play.fill");
    XCTAssertEqualObjects(theme.pauseButtonGlyph, @"pause.fill");
    XCTAssertEqualObjects(theme.nextButtonGlyph, @"forward.end.fill");
    for (NSString *key in AppTheme.imageFieldKeys) {
        XCTAssertEqualObjects([theme imageReferenceForKey:key], @"", @"%@", key);
        XCTAssertNil([theme customImageForKey:key], @"%@", key);
    }
    XCTAssertTrue(theme.showFileInfo);
    XCTAssertTrue(theme.showTransportButtons);
    XCTAssertTrue(theme.showStatusIcons);
    XCTAssertTrue(theme.showTimeLabels);
    XCTAssertTrue(theme.waveformGradient);
    XCTAssertFalse(theme.waveformPlayheadLine);
    XCTAssertEqual(theme.waveformBarDensity, 1);
    XCTAssertEqual(theme.waveformBarWidth, 1);
    XCTAssertTrue(theme.showPlaylistNumberColumn);
    XCTAssertTrue(theme.showPlaylistArtworkColumn);
    XCTAssertTrue(theme.showPlaylistDurationColumn);
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotPlaylistDuration], 12);
    XCTAssertEqualObjects(theme.mode, @"dual");
    XCTAssertFalse(theme.showRemainingTime);
    XCTAssertTrue(theme.showBPM);
    XCTAssertTrue(theme.showKey);
    XCTAssertFalse(theme.keyColorsEnabled);
    for (NSString *base in @[kVibeThemeColorPlaylistNumber, kVibeThemeColorPlaylistTitle,
                             kVibeThemeColorPlaylistArtist, kVibeThemeColorPlaylistDuration]) {
        XCTAssertFalse([theme playlistColorEnabledForBase:base], @"%@", base);
    }
    XCTAssertEqualObjects(theme.keyNotation, @"camelot");
    XCTAssertEqualObjects([theme fontFaceForSlot:VibeFontSlotTitle], @"");
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotTitle], 23);
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotInfo], 13);
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotPlaylist], 14);
    XCTAssertNil([theme colorForBase:kVibeThemeColorTitle dark:YES]);
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

- (void)testDefaultValuedFieldsAreNotStored {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"waveformTheme": @"mono",
        @"waveformBarDensity": @1,
        @"waveformBarWidth": @1,
        @"customCornerRadius": @NO,
        @"windowCornerRadius": @16,
        @"showFileInfo": @YES,
        @"showTransportButtons": @YES,
        @"showStatusIcons": @YES,
        @"showTimeLabels": @YES,
        @"titleFontFace": @"",
        @"dockIcon": @"album_art",
        @"playButtonGlyph": @"play.fill",
        @"appIcon": @"",
    }];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

// Records written before the switch existed name a radius alone, and keep
// that shape. One that says off draws the standard radius whatever its slider
// holds.
- (void)testARadiusWithoutTheSwitchReadsAsCustom {
    AppTheme *legacy = [[AppTheme alloc] initWithRecord:@{@"windowCornerRadius": @8}];
    XCTAssertTrue(legacy.customCornerRadius);
    XCTAssertEqual(legacy.resolvedWindowCornerRadius, 8);
    XCTAssertEqualObjects(legacy.dictionaryRepresentation,
                          (@{@"windowCornerRadius": @8, @"customCornerRadius": @YES}));

    AppTheme *off = [[AppTheme alloc] initWithRecord:@{@"windowCornerRadius": @8,
                                                        @"customCornerRadius": @NO}];
    XCTAssertFalse(off.customCornerRadius);
    XCTAssertEqual(off.windowCornerRadius, 8, @"the slider keeps its value");
    XCTAssertEqual(off.resolvedWindowCornerRadius, 16, @"but the window draws the standard one");

    // Setters infer nothing: a radius alone leaves the switch off, and on
    // survives the standard radius, the one value the record does not store.
    AppTheme *edited = [[AppTheme alloc] initWithRecord:nil];
    edited.windowCornerRadius = 30;
    XCTAssertFalse(edited.customCornerRadius);
    XCTAssertEqual(edited.resolvedWindowCornerRadius, 16);
    edited.customCornerRadius = YES;
    XCTAssertEqual(edited.resolvedWindowCornerRadius, 30);
    edited.windowCornerRadius = 8;
    edited.windowCornerRadius = 16;
    XCTAssertTrue(edited.customCornerRadius, @"through 16 the switch stands");
    XCTAssertEqualObjects(edited.dictionaryRepresentation, @{@"customCornerRadius": @YES});
    edited.windowCornerRadius = 20;
    XCTAssertEqual(edited.resolvedWindowCornerRadius, 20);
}

// Off is stored as an explicit false beside the radius: dropped for equalling
// the default, the bare radius left behind would read back as custom.
- (void)testSwitchingCustomRadiusOffSurvivesEveryRoundTrip {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    theme.customCornerRadius = YES;
    theme.windowCornerRadius = 8;
    theme.customCornerRadius = NO;
    NSDictionary *record = @{@"windowCornerRadius": @8, @"customCornerRadius": @NO};
    XCTAssertEqualObjects(theme.dictionaryRepresentation, record);
    XCTAssertEqual(theme.resolvedWindowCornerRadius, 16);

    AppTheme *reloaded = [[AppTheme alloc] initWithRecord:theme.dictionaryRepresentation];
    XCTAssertFalse(reloaded.customCornerRadius);
    XCTAssertEqual(reloaded.resolvedWindowCornerRadius, 16);
    XCTAssertEqualObjects(reloaded.dictionaryRepresentation, record);
    XCTAssertEqualObjects([AppTheme sanitizedRecord:record], record);

    NSData *json = [AppTheme JSONDataForRecord:record name:@"Off"];
    NSDictionary *file = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    XCTAssertEqualObjects(file[@"window"], (@{@"cornerRadius": @8, @"customCornerRadius": @NO}));
    XCTAssertEqualObjects([AppTheme recordFromJSONData:json name:NULL error:NULL], record);

    theme.customCornerRadius = YES;
    XCTAssertEqual(theme.resolvedWindowCornerRadius, 8);
    theme.customCornerRadius = NO;
    theme.windowCornerRadius = 16;
    XCTAssertFalse(theme.customCornerRadius);
    XCTAssertEqual(theme.resolvedWindowCornerRadius, 16);
    XCTAssertEqualObjects([AppTheme sanitizedRecord:theme.dictionaryRepresentation], @{});
}

- (void)testDockIconSnapsToAlbumArt {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"dockIcon": @"finder"}];
    XCTAssertEqualObjects(theme.dockIcon, @"album_art");
    theme.dockIcon = @"app_icon";
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{@"dockIcon": @"app_icon"});
}

// A glyph field is free text in the symbol-name shape, like a font face: the
// record does not know the symbol catalog, and the draw site falls back for
// a name this macOS lacks. Anything outside the shape drops to the default.
- (void)testGlyphsKeepTheSymbolNameShape {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"playlistButtonGlyph": @"  music.note.list ",
        @"playButtonGlyph": @"play.circle",
        @"pauseButtonGlyph": @"pause.circle",
        @"nextButtonGlyph": @"chevron.right.2",
    }];
    XCTAssertEqualObjects(theme.playlistButtonGlyph, @"music.note.list");
    XCTAssertEqualObjects(theme.playButtonGlyph, @"play.circle");
    XCTAssertEqualObjects(theme.pauseButtonGlyph, @"pause.circle");
    XCTAssertEqualObjects(theme.nextButtonGlyph, @"chevron.right.2");
    XCTAssertEqual(theme.dictionaryRepresentation.count, 4u);
    for (NSString *bad in @[@"", @"Play.Fill", @"play fill", @"custom-image", @"play/fill"]) {
        theme.nextButtonGlyph = bad;
        XCTAssertEqualObjects(theme.nextButtonGlyph, @"forward.end.fill", @"%@", bad);
    }
    // Capped like a face, so a runaway name is stored short rather than dropped.
    theme.nextButtonGlyph = [@"" stringByPaddingToLength:80 withString:@"a" startingAtIndex:0];
    XCTAssertEqual(theme.nextButtonGlyph.length, 64u);
    AppTheme *number = [[AppTheme alloc] initWithRecord:@{@"playButtonGlyph": @7}];
    XCTAssertEqualObjects(number.playButtonGlyph, @"play.fill");
}

// Every image field takes a custom: or bundled: reference and drops anything
// else. customImageForKey: answers nil for the factory and for a reference
// whose file is gone, so the app icon and buttons fall back to their own
// factory art.
- (void)testEveryImageFieldTakesOneReferenceShape {
    NSArray<NSString *> *keys = AppTheme.imageFieldKeys;
    XCTAssertEqualObjects(keys, (@[@"appIcon", @"defaultArtworkDark", @"defaultArtworkLight",
                                   @"playlistButtonImageDark", @"playlistButtonImageLight",
                                   @"playButtonImageDark", @"playButtonImageLight",
                                   @"pauseButtonImageDark", @"pauseButtonImageLight",
                                   @"nextButtonImageDark", @"nextButtonImageLight"]));
    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    for (NSString *key in keys) {
        [theme setImageReference:stored forKey:key];
        XCTAssertEqualObjects([theme imageReferenceForKey:key], stored, @"%@", key);
        XCTAssertNotNil([theme customImageForKey:key], @"%@", key);
        [theme setImageReference:@"vinyl_red" forKey:key];
        XCTAssertEqualObjects([theme imageReferenceForKey:key], @"", @"%@", key);
    }
    [theme setImageReference:stored forKey:@"appIcon"];
    XCTAssertEqualObjects([AppTheme customImageFilesInRecord:theme.dictionaryRepresentation],
                          [NSSet setWithObject:[stored substringFromIndex:7]]);
    [NSFileManager.defaultManager removeItemAtPath:
            [_artDir stringByAppendingPathComponent:[stored substringFromIndex:7]] error:NULL];
    XCTAssertTrue([AppTheme referenceIsMissing:stored]);
    XCTAssertNil([theme customImageForKey:@"appIcon"], @"a missing image is no image");
    XCTAssertNotNil([AppTheme imageForReference:stored], @"the placeholder's fallback still draws");
}

// Only the placeholder's light slot follows single mode's dark-slot rule.
// The buttons' image and color pairs are keyed by the art under them, not
// the appearance, so both of their sides stay live under single mode.
- (void)testSingleModeRedirectsOnlyThePlaceholderPair {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"mode": @"single"}];
    NSString *reference = @"custom:0123456789abcdef0123456789abcdef01234567.png";
    [theme setImageReference:reference forKey:@"defaultArtworkLight"];
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtworkDark"], reference);
    XCTAssertNil(theme.dictionaryRepresentation[@"defaultArtworkLight"]);
    [theme setImageReference:reference forKey:@"playButtonImageLight"];
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"playButtonImageLight"], reference);
    XCTAssertNil(theme.dictionaryRepresentation[@"playButtonImageDark"]);
    [theme setColor:VibeColorFromHexString(@"#112233") forBase:kVibeThemeColorNextButton dark:NO];
    [theme setColor:VibeColorFromHexString(@"#445566") forBase:kVibeThemeColorNextButton dark:YES];
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorNextButton dark:NO]),
                          @"#112233");
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorNextButton dark:YES]),
                          @"#445566");
    // An appearance-keyed pair still collapses.
    [theme setColor:VibeColorFromHexString(@"#778899") forBase:kVibeThemeColorTitle dark:NO];
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"titleColorDark"], @"#778899");
    XCTAssertNil(theme.dictionaryRepresentation[@"titleColorLight"]);
}

- (void)testSettingBackToTheDefaultEmptiesTheRecord {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    theme.windowCornerRadius = 8;
    theme.waveformTheme = @"orange";
    XCTAssertEqual(theme.dictionaryRepresentation.count, 2u);
    theme.windowCornerRadius = 16;
    theme.waveformTheme = @"mono";
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

#pragma mark Sanitization

- (void)testUnknownFieldsAreDropped {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"version": @1,
        @"name": @"Someone's Theme",
        @"id": @"ABC",
        @"futureField": @"whatever",
        @"windowCornerRadius": @12,
    }];
    XCTAssertEqualObjects(theme.dictionaryRepresentation,
                          (@{@"windowCornerRadius": @12, @"customCornerRadius": @YES}));
}

- (void)testIdentifiersSnapToTheirLadders {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"waveformTheme": @"purple",
        @"windowTint": @"plaid",
        @"playlistTint": @"plaid",
        @"windowBackgroundStyle": @"translucent",
        // The window's alone: the playlist has no panes to keep.
        @"playlistBackgroundStyle": @"frosted",
        @"keyNotation": @"solfege",
    }];
    // Every snap lands on the default, so nothing is stored.
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
    XCTAssertEqualObjects(theme.waveformTheme, @"mono");
    XCTAssertEqualObjects(theme.windowTint, @"artwork");
    XCTAssertEqualObjects(theme.playlistTint, @"mono");
    XCTAssertEqualObjects(theme.windowBackgroundStyle, @"glass");
    XCTAssertEqualObjects(theme.playlistBackgroundStyle, @"glass");
    XCTAssertEqualObjects(theme.keyNotation, @"camelot");
    // The third background style is a real choice on both surfaces.
    theme.windowBackgroundStyle = @"clear";
    theme.playlistBackgroundStyle = @"clear";
    XCTAssertEqualObjects(theme.dictionaryRepresentation,
                          (@{@"windowBackgroundStyle": @"clear", @"playlistBackgroundStyle": @"clear"}));
    theme.windowBackgroundStyle = @"frosted";
    XCTAssertEqualObjects(theme.windowBackgroundStyle, @"frosted");
}

// Frosted is solid's color with the glass panes kept over it, so both take
// the color pair and only they do.
- (void)testFrostedAndSolidTakeTheBackgroundColor {
    for (NSString *style in @[@"glass", @"frosted", @"solid", @"clear"]) {
        BOOL colored = [style isEqualToString:@"frosted"] || [style isEqualToString:@"solid"];
        XCTAssertEqual(VibeWindowBackgroundTakesColor(VibeNormalizedWindowBackgroundStyle(style)), colored, @"%@", style);
    }
    XCTAssertEqualObjects(VibeNormalizedPlaylistBackgroundStyle(@"frosted"), @"glass");
}

- (void)testPlaylistTintLadderKeepsItsOwnDefault {
    // Unknowns snap to mono, not the window tint's artwork: the factory
    // playlist takes no artwork wash.
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"playlistTint": @"artwork"}];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{@"playlistTint": @"artwork"});
    theme.playlistTint = @"custom";
    XCTAssertEqualObjects(theme.playlistTint, @"custom");
    theme.playlistTint = @"plaid";
    XCTAssertEqualObjects(theme.playlistTint, @"mono");
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

- (void)testNumbersClampBothEnds {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"windowCornerRadius": @500,
        @"titleFontSize": @5,
        @"infoFontSize": @72,
        @"playlistFontSize": @(-3),
        @"waveformBarDensity": @50,
        @"waveformBarWidth": @50,
    }];
    XCTAssertEqual(theme.windowCornerRadius, 36);
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotTitle], 20);
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotInfo], 15);
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotPlaylist], 11);
    XCTAssertEqual(theme.waveformBarDensity, 2);
    XCTAssertEqual(theme.waveformBarWidth, 2);
    theme.waveformBarWidth = -1;
    XCTAssertEqual(theme.waveformBarWidth, 0.5);
    theme.waveformBarDensity = -1;
    XCTAssertEqual(theme.waveformBarDensity, 0.5);
    theme.windowCornerRadius = -10;
    XCTAssertEqual(theme.windowCornerRadius, 0);
}

- (void)testMalformedValuesAreDropped {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"windowCornerRadius": @"big",
        @"titleFontSize": @(NAN),
        @"showBPM": @"true",
        @"titleColorDark": @"#GGHHII",
        @"artistColorDark": @123,
        @"waveformStyle": @7,
        @"waveformBarDensity": @(INFINITY),
        @"waveformBarWidth": @(NAN),
    }];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
    XCTAssertTrue(theme.showBPM);
}

- (void)testBoolsCoerceFromNumbersOnly {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"showRemainingTime": @1,
        @"showKey": @NO,
    }];
    XCTAssertTrue(theme.showRemainingTime);
    XCTAssertFalse(theme.showKey);
    XCTAssertEqual(theme.dictionaryRepresentation.count, 2u);
}

- (void)testFontFacesAreTrimmedAndCapped {
    NSString *longFace = [@"" stringByPaddingToLength:200 withString:@"F" startingAtIndex:0];
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"infoFontFace": @"  Menlo-Regular  ",
        @"titleFontFace": longFace,
    }];
    XCTAssertEqualObjects([theme fontFaceForSlot:VibeFontSlotInfo], @"Menlo-Regular");
    XCTAssertEqual([theme fontFaceForSlot:VibeFontSlotTitle].length, 64u);
}

// None is what an unset control tag or a zero-filled ivar holds, so it must
// name no field — never the title's.
- (void)testNoneFontSlotNamesNoField {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"titleFontFace": @"Menlo-Regular",
                                                          @"titleFontSize": @24}];
    XCTAssertEqualObjects([theme fontFaceForSlot:VibeFontSlotNone], @"");
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotNone], 0);
    [theme setFontFace:@"Courier" size:22 forSlot:VibeFontSlotNone];
    XCTAssertEqualObjects([theme fontFaceForSlot:VibeFontSlotTitle], @"Menlo-Regular");
    XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotTitle], 24);
    XCTAssertEqualObjects(theme.dictionaryRepresentation,
                          (@{@"titleFontFace": @"Menlo-Regular", @"titleFontSize": @24}));
}

- (void)testColorsRoundTripThroughHexWithAlpha {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    [theme setColor:VibeColorFromHexString(@"#FF6600AA") forBase:kVibeThemeColorPlaylistPlayingRow dark:YES];
    XCTAssertEqualObjects(theme.dictionaryRepresentation,
                          @{@"playlistPlayingRowColorDark": @"#FF6600AA"});
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorPlaylistPlayingRow dark:YES]),
                          @"#FF6600AA");
    XCTAssertNil([theme colorForBase:kVibeThemeColorPlaylistPlayingRow dark:NO]);
    [theme setColor:nil forBase:kVibeThemeColorPlaylistPlayingRow dark:YES];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

// Every pair, by the base key the editor's wells bind by: unset it displays
// the constant its surface paints, set it displays its own override.
- (void)testDisplayColorIsTheOverrideOrThePairsConstant {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    NSArray<NSString *> *bases = @[kVibeThemeColorWaveformPlayed, kVibeThemeColorWaveformUnplayed,
                                   kVibeThemeColorWaveformPlayhead, kVibeThemeColorWindowTint, kVibeThemeColorPlaylistTint,
                                   kVibeThemeColorWindowBackground, kVibeThemeColorTitle,
                                   kVibeThemeColorArtist, kVibeThemeColorInfo, kVibeThemeColorTime,
                                   kVibeThemeColorPlaylistBackground, kVibeThemeColorPlaylistPlayingRow,
                                   kVibeThemeColorPlaylistSelectedRow, kVibeThemeColorPlaylistButton,
                                   kVibeThemeColorPlayButton, kVibeThemeColorNextButton,
                                   kVibeThemeColorPlaylistNumber, kVibeThemeColorPlaylistTitle,
                                   kVibeThemeColorPlaylistArtist, kVibeThemeColorPlaylistDuration];
    for (NSString *base in bases) {
        XCTAssertNotNil([theme displayColorForBase:base dark:YES], @"%@", base);
        XCTAssertNotNil([theme displayColorForBase:base dark:NO], @"%@", base);
        XCTAssertNil([theme colorForBase:base dark:NO], @"%@", base);
        [theme setColor:VibeColorFromHexString(@"#12345680") forBase:base dark:NO];
        XCTAssertEqualObjects(VibeHexStringFromColor([theme displayColorForBase:base dark:NO]),
                              @"#12345680", @"%@", base);
    }
    XCTAssertEqual(theme.dictionaryRepresentation.count, bases.count);
}

static NSString *HexInAppearance(NSColor *color, NSAppearanceName name) {
    __block NSString *hex;
    [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
        hex = VibeHexStringFromColor([color colorUsingColorSpace:NSColorSpace.sRGBColorSpace]);
    }];
    return hex;
}

// Until its switch is on, a playlist column draws (and its wells show) the
// label pair, overrides included; the pair it holds survives switching off.
- (void)testPlaylistColumnColorsInheritTheLabelPairsUntilSwitchedOn {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    XCTAssertEqualObjects([theme displayColorForBase:kVibeThemeColorPlaylistTitle dark:YES],
                          [theme displayColorForBase:kVibeThemeColorTitle dark:YES]);
    XCTAssertEqualObjects([theme displayColorForBase:kVibeThemeColorPlaylistNumber dark:NO],
                          [theme displayColorForBase:kVibeThemeColorArtist dark:NO]);
    [theme setColor:VibeColorFromHexString(@"#FF0000") forBase:kVibeThemeColorTitle dark:YES];
    XCTAssertEqualObjects(VibeHexStringFromColor([theme displayColorForBase:kVibeThemeColorPlaylistTitle dark:YES]),
                          @"#FF0000");
    XCTAssertEqualObjects(HexInAppearance([theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistTitle],
                                          NSAppearanceNameDarkAqua), @"#FF0000");

    // A pair set while the switch is off is held, not drawn.
    [theme setColor:VibeColorFromHexString(@"#00FF00") forBase:kVibeThemeColorPlaylistTitle dark:YES];
    XCTAssertEqualObjects(HexInAppearance([theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistTitle],
                                          NSAppearanceNameDarkAqua), @"#FF0000");
    [theme setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistTitle];
    XCTAssertEqualObjects(HexInAppearance([theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistTitle],
                                          NSAppearanceNameDarkAqua), @"#00FF00");
    // The unset light side of an enabled pair still inherits.
    [theme setColor:VibeColorFromHexString(@"#0000FF") forBase:kVibeThemeColorTitle dark:NO];
    XCTAssertEqualObjects(HexInAppearance([theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistTitle],
                                          NSAppearanceNameAqua), @"#0000FF");
    [theme setPlaylistColorEnabled:NO forBase:kVibeThemeColorPlaylistTitle];
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorPlaylistTitle dark:YES]),
                          @"#00FF00");

    // The switch and the pair travel under the playlist section, the base
    // less its playlist prefix.
    NSDictionary *record = @{@"playlistNumberColorEnabled": @YES, @"playlistNumberColorDark": @"#123456"};
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:
            [AppTheme JSONDataForRecord:record name:@"Columns"] options:0 error:NULL];
    XCTAssertEqualObjects(json[@"playlist"], (@{@"numberColorEnabled": @YES, @"numberColorDark": @"#123456"}));
    XCTAssertEqualObjects([AppTheme recordFromJSONData:[AppTheme JSONDataForRecord:record name:@"Columns"]
                                                  name:NULL error:NULL], record);
}

#pragma mark Dice

- (void)testRandomizableFontFacesAreInstalled {
    NSArray<NSString *> *faces = AppTheme.randomizableFontFaces;
    XCTAssertEqual(faces.count, 7);
    for (NSString *face in faces) {
        XCTAssertNotNil([NSFont fontWithName:face size:12], @"%@", face);
    }
}

- (void)testRandomizeSettingsRollsTheLookAndLeavesTheRestAlone {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    [theme setColor:VibeColorFromHexString(@"#FF000080") forBase:kVibeThemeColorTitle dark:YES];
    [theme setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistTitle];
    theme.showFileInfo = NO;
    theme.waveformPlayheadLine = YES;
    theme.keyNotation = @"musical";
    theme.dockIcon = @"app_icon";
    [theme setImageReference:@"bundled:cupertino_dark.jpg" forKey:kVibeThemeImagePlayButtonDark];
    NSArray<NSString *> *styles = @[@"detailed", @"basic"];
    NSSet<NSString *> *faces = [NSSet setWithArray:AppTheme.randomizableFontFaces];
    NSSet<NSNumber *> *radii = [NSSet setWithArray:@[@0, @8, @12, @16, @20, @28, @36]];
    for (int roll = 0; roll < 40; roll++) {
        [theme randomizeSettingsWithWaveformStyles:styles];
        XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorTitle dark:YES]), @"#FF000080");
        XCTAssertTrue([theme playlistColorEnabledForBase:kVibeThemeColorPlaylistTitle]);
        XCTAssertFalse(theme.showFileInfo);
        XCTAssertTrue(theme.waveformPlayheadLine);
        XCTAssertEqualObjects(theme.keyNotation, @"musical");
        XCTAssertEqualObjects(theme.dockIcon, @"app_icon");
        XCTAssertEqualObjects([theme imageReferenceForKey:kVibeThemeImagePlayButtonDark],
                              @"bundled:cupertino_dark.jpg");
        XCTAssertTrue([styles containsObject:theme.waveformStyle]);
        XCTAssertNotEqualObjects(theme.waveformTheme, @"custom");
        XCTAssertNotEqualObjects(theme.windowTint, @"custom");
        XCTAssertNotEqualObjects(theme.playlistTint, @"custom");
        XCTAssertNotEqualObjects(theme.volumeBar, @"custom");
        XCTAssertTrue([radii containsObject:@(theme.windowCornerRadius)]);
        XCTAssertEqualObjects(theme.pauseButtonGlyph, VibePauseGlyphForPlayGlyph(theme.playButtonGlyph));
        XCTAssertTrue([faces containsObject:[theme fontFaceForSlot:VibeFontSlotTitle]], @"%@", [theme fontFaceForSlot:VibeFontSlotTitle]);
        XCTAssertEqualObjects([theme fontFaceForSlot:VibeFontSlotArtist], [theme fontFaceForSlot:VibeFontSlotTitle]);
        XCTAssertEqualObjects([theme fontFaceForSlot:VibeFontSlotPlaylist], [theme fontFaceForSlot:VibeFontSlotTitle]);
        XCTAssertTrue([faces containsObject:[theme fontFaceForSlot:VibeFontSlotInfo]], @"%@", [theme fontFaceForSlot:VibeFontSlotInfo]);
        XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotTitle], kVibeThemeTitleFontBaseSize);
        XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotArtist], kVibeThemeArtistFontBaseSize);
        XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotInfo], kVibeThemeInfoFontBaseSize);
        XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotPlaylist], kVibeThemePlaylistFontBaseSize);
        XCTAssertEqual([theme fontSizeForSlot:VibeFontSlotPlaylistDuration], kVibeThemePlaylistDurationFontBaseSize);
    }
}

- (void)testRandomizeColorsRollsAPaletteAndLeavesTheSettingsAlone {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    theme.waveformStyle = @"detailed";
    theme.windowCornerRadius = 8;
    theme.playlistButtonGlyph = @"list.dash";
    [theme setFontFace:@"Georgia" size:23 forSlot:VibeFontSlotTitle];
    [theme setColor:VibeColorFromHexString(@"#101010F0") forBase:kVibeThemeColorPlaylistBackground dark:YES];
    for (int roll = 0; roll < 40; roll++) {
        [theme randomizeColors];
        XCTAssertEqualObjects(theme.waveformStyle, @"detailed");
        XCTAssertEqual(theme.windowCornerRadius, 8);
        XCTAssertEqualObjects(theme.playlistButtonGlyph, @"list.dash");
        XCTAssertEqualObjects([theme fontFaceForSlot:VibeFontSlotTitle], @"Georgia");
        // No scheme paints the playlist cover, so a stale pair is cleared.
        XCTAssertNil([theme colorForBase:kVibeThemeColorPlaylistBackground dark:YES]);
        NSUInteger painted = 0;
        for (NSString *key in theme.dictionaryRepresentation) {
            if ([key hasSuffix:@"ColorDark"] || [key hasSuffix:@"ColorLight"]) {
                painted++;
                XCTAssertNotNil(VibeColorFromHexString(theme.dictionaryRepresentation[key]), @"%@", key);
            }
        }
        XCTAssertGreaterThan(painted, 0u);
        for (NSString *base in @[kVibeThemeColorTitle, kVibeThemeColorArtist, kVibeThemeColorWaveformPlayed,
                                 kVibeThemeColorWindowTint, kVibeThemeColorPlaylistPlayingRow]) {
            XCTAssertEqual([theme colorForBase:base dark:YES] != nil, [theme colorForBase:base dark:NO] != nil,
                           @"%@", base);
        }
        XCTAssertEqual([theme.waveformTheme isEqualToString:@"custom"],
                       [theme colorForBase:kVibeThemeColorWaveformPlayed dark:YES] != nil);
        XCTAssertEqual([theme.windowTint isEqualToString:@"custom"],
                       [theme colorForBase:kVibeThemeColorWindowTint dark:YES] != nil);
        XCTAssertEqual([theme playlistColorEnabledForBase:kVibeThemeColorPlaylistTitle],
                       [theme colorForBase:kVibeThemeColorPlaylistTitle dark:YES] != nil);
    }
}

static CGFloat Brightness(NSString *hex) {
    CGFloat brightness = 0;
    [[VibeColorFromHexString(hex) colorUsingColorSpace:NSColorSpace.sRGBColorSpace]
            getHue:NULL saturation:NULL brightness:&brightness alpha:NULL];
    return brightness;
}

// Single mode's one slot per appearance-keyed pair is the dark-keyed one the
// pinned-dark window draws, so it takes the dark palette. The art-keyed
// buttons keep both sides.
- (void)testRandomizeColorsPaintsSingleModesOneSlotWithTheDarkPalette {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"mode": @"single"}];
    BOOL sawButtons = NO;
    for (int roll = 0; roll < 60; roll++) {
        [theme randomizeColors];
        NSDictionary *record = theme.dictionaryRepresentation;
        for (NSString *key in record) {
            if ([key hasSuffix:@"ColorLight"]) {
                XCTAssertTrue([key hasSuffix:@"ButtonColorLight"],
                        @"%@: no light slot to paint under single mode", key);
                XCTAssertEqualWithAccuracy(Brightness(record[key]), 0.55, 0.03, @"%@", key);
                sawButtons = YES;
            } else if ([key hasSuffix:@"ColorDark"]) {
                XCTAssertEqualWithAccuracy(Brightness(record[key]), 0.95, 0.03, @"%@", key);
            }
        }
        XCTAssertEqual([theme colorForBase:kVibeThemeColorPlayButton dark:YES] != nil,
                       [theme colorForBase:kVibeThemeColorPlayButton dark:NO] != nil);
    }
    XCTAssertTrue(sawButtons, @"sixty rolls never reached the scheme that paints the buttons");

    theme.mode = @"dual";
    [theme randomizeColors];
    NSDictionary *record = theme.dictionaryRepresentation;
    for (NSString *key in record) {
        if ([key hasSuffix:@"ColorDark"]) {
            XCTAssertEqualWithAccuracy(Brightness(record[key]), 0.95, 0.03, @"%@", key);
            NSString *light = [[key substringToIndex:key.length - 4] stringByAppendingString:@"Light"];
            XCTAssertEqualWithAccuracy(Brightness(record[light]), 0.55, 0.03, @"%@", light);
        }
    }
}

- (void)testRecordRoundTrips {
    AppTheme *first = [[AppTheme alloc] initWithRecord:nil];
    first.waveformStyle = @"detailed";
    first.windowBackgroundStyle = @"solid";
    [first setFontFace:@"" size:11 forSlot:VibeFontSlotInfo];
    [first setColor:VibeColorFromHexString(@"#101014F0") forBase:kVibeThemeColorWindowBackground dark:YES];
    [first setColor:VibeColorFromHexString(@"#FFFFFF") forBase:kVibeThemeColorTitle dark:NO];
    AppTheme *second = [[AppTheme alloc] initWithRecord:first.dictionaryRepresentation];
    XCTAssertEqualObjects(second.dictionaryRepresentation, first.dictionaryRepresentation);
    XCTAssertEqualObjects(second.waveformStyle, @"detailed");
    XCTAssertEqual([second fontSizeForSlot:VibeFontSlotInfo], 11);
}

- (void)testReplaceWithRecordSwitchesEveryField {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"windowCornerRadius": @4}];
    [theme replaceWithRecord:@{@"waveformTheme": @"orange"}];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{@"waveformTheme": @"orange"});
    XCTAssertEqual(theme.windowCornerRadius, 16);
}

#pragma mark JSON

- (void)testJSONRoundTripCarriesNameAndVersionAndStripsIds {
    NSDictionary *record = @{@"waveformTheme": @"orange", @"waveformBarDensity": @1.75, @"waveformBarWidth": @0.65, @"windowCornerRadius": @6,
                             @"waveformPlayheadLine": @YES, @"waveformPlayheadColorDark": @"#FF0000",
                             @"id": @"SHOULD-NOT-TRAVEL"};
    NSData *data = [AppTheme JSONDataForRecord:record name:@"Exported"];
    XCTAssertNotNil(data);
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    XCTAssertEqualObjects(json[@"version"], @1);
    XCTAssertEqualObjects(json[@"name"], @"Exported");
    XCTAssertNil(json[@"id"]);
    // The fields travel nested under their editor sections, never flat, and
    // an untouched section is omitted rather than written empty.
    XCTAssertEqualObjects(json[@"waveform"], (@{@"theme": @"orange", @"barDensity": @1.75, @"barWidth": @0.65,
                                                @"playheadLine": @YES, @"playheadColorDark": @"#FF0000"}));
    XCTAssertEqualObjects(json[@"window"], (@{@"cornerRadius": @6, @"customCornerRadius": @YES}));
    XCTAssertNil(json[@"waveformTheme"]);
    XCTAssertNil(json[@"playlist"]);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    XCTAssertLessThan([text rangeOfString:@"\"version\""].location,
                      [text rangeOfString:@"\"name\""].location);
    XCTAssertLessThan([text rangeOfString:@"\"name\""].location,
                      [text rangeOfString:@"\"window\""].location);
    XCTAssertLessThan([text rangeOfString:@"\"window\""].location,
                      [text rangeOfString:@"\"waveform\""].location);
    NSString *name = nil;
    NSError *error = nil;
    NSDictionary *back = [AppTheme recordFromJSONData:data name:&name error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(back, (@{@"waveformTheme": @"orange", @"waveformBarDensity": @1.75, @"waveformBarWidth": @0.65, @"windowCornerRadius": @6,
                                   @"waveformPlayheadLine": @YES, @"waveformPlayheadColorDark": @"#FF0000",
                                   @"customCornerRadius": @YES}));
    XCTAssertEqualObjects(name, @"Exported");
}

- (void)testJSONImportSanitizesFields {
    // A flat pre-group key and an unknown group drop like any unknown field.
    NSData *data = [@"{\"name\": 42, \"windowCornerRadius\": 9,"
                     " \"window\": {\"cornerRadius\": 900, \"future\": [1,2]},"
                     " \"future\": {\"cornerRadius\": 1}}"
            dataUsingEncoding:NSUTF8StringEncoding];
    NSString *name = @"sentinel";
    NSError *error = nil;
    NSDictionary *record = [AppTheme recordFromJSONData:data name:&name error:&error];
    XCTAssertNil(error);
    XCTAssertNil(name);  // a non-string name does not travel
    XCTAssertEqualObjects(record, (@{@"windowCornerRadius": @36, @"customCornerRadius": @YES}));
}

- (void)testJSONImportRefusesJunk {
    NSError *error = nil;
    XCTAssertNil([AppTheme recordFromJSONData:[@"[1,2,3]" dataUsingEncoding:NSUTF8StringEncoding]
                                         name:NULL error:&error]);
    XCTAssertNotNil(error);
    error = nil;
    XCTAssertNil([AppTheme recordFromJSONData:[@"not json" dataUsingEncoding:NSUTF8StringEncoding]
                                         name:NULL error:&error]);
    XCTAssertNotNil(error);
    error = nil;
    XCTAssertNil([AppTheme recordFromJSONData:NSData.data name:NULL error:&error]);
    XCTAssertNotNil(error);
    error = nil;
    NSMutableData *huge = [NSMutableData dataWithLength:80 * 1024];
    XCTAssertNil([AppTheme recordFromJSONData:huge name:NULL error:&error]);
    XCTAssertNotNil(error);
}

- (void)testEmptyJSONObjectIsAValidDefaultTheme {
    NSError *error = nil;
    NSDictionary *record = [AppTheme recordFromJSONData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
                                                   name:NULL error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(record, @{});
}

// The volume slider's section: its ladders snap, and its JSON home is
// volume.* both ways.
- (void)testVolumeFieldsSnapAndRoundTripUnderTheVolumeSection {
    AppTheme *snapped = [[AppTheme alloc] initWithRecord:@{
        @"volumeBar": @"plaid", @"volumeKnob": @"plaid", @"volumeLocation": @"bottom_left",
        @"showVolumeLabels": @"no"}];
    XCTAssertEqualObjects(snapped.volumeBar, @"waveform");
    XCTAssertEqualObjects(snapped.volumeKnob, @"bar");
    XCTAssertEqualObjects(snapped.volumeLocation, @"top_right");
    XCTAssertTrue(snapped.showVolumeLabels);
    XCTAssertEqualObjects(snapped.dictionaryRepresentation, @{});
    for (NSString *bar in @[@"mono", @"artwork", @"custom"]) {
        snapped.volumeBar = bar;
        XCTAssertEqualObjects(snapped.volumeBar, bar);
    }
    for (NSString *knob in @[@"mono", @"waveform", @"artwork", @"custom"]) {
        snapped.volumeKnob = knob;
        XCTAssertEqualObjects(snapped.volumeKnob, knob);
    }
    snapped.volumeBar = @"bar";
    XCTAssertEqualObjects(snapped.volumeBar, @"waveform", @"only the knob can follow the bar");

    NSData *json = [@"{\"volume\":{\"bar\":\"custom\",\"barColorDark\":\"#FF0000\","
                     "\"knob\":\"custom\",\"knobColorDark\":\"#00FF00\","
                     "\"showLabels\":false,\"location\":\"bottom\"}}"
            dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *expected = @{@"volumeBar": @"custom", @"volumeBarColorDark": @"#FF0000",
                               @"volumeKnob": @"custom", @"volumeKnobColorDark": @"#00FF00",
                               @"showVolumeLabels": @NO, @"volumeLocation": @"bottom"};
    NSDictionary *record = [AppTheme recordFromJSONData:json name:NULL error:NULL];
    XCTAssertEqualObjects(record, expected);
    AppTheme *theme = [[AppTheme alloc] initWithRecord:record];
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorVolumeBar dark:YES]),
                          @"#FF0000");
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorVolumeKnob dark:YES]),
                          @"#00FF00");
    NSData *exported = [AppTheme JSONDataForRecord:record name:@"Volume"];
    NSDictionary *object = [NSJSONSerialization JSONObjectWithData:exported options:0 error:NULL];
    XCTAssertEqualObjects(object[@"volume"][@"location"], @"bottom");
    XCTAssertEqualObjects([AppTheme recordFromJSONData:exported name:NULL error:NULL], expected);
}

- (void)testButtonGradientModesAndLegacyBooleansRoundTrip {
    NSArray *cases = @[@[@YES, @"always"], @[@NO, @"none"], @[@"none", @"none"],
            @[@"hover", @"hover"], @[@"artwork", @"artwork"], @[@"always", @"always"], @[@"invalid", @"always"],
            @[@[], @"always"], @[NSNull.null, @"always"]];
    for (NSArray *pair in cases) {
        AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"buttonGradient": pair[0]}];
        XCTAssertEqualObjects(theme.buttonGradient, pair[1]);
        NSDictionary *expected = [pair[1] isEqual:@"always"] ? @{} : @{@"buttonGradient": pair[1]};
        XCTAssertEqualObjects(theme.dictionaryRepresentation, expected);
        NSData *legacy = [NSJSONSerialization dataWithJSONObject:@{@"player": @{@"buttonGradient": pair[0]}}
                options:0 error:NULL];
        XCTAssertEqualObjects([AppTheme recordFromJSONData:legacy name:NULL error:NULL], expected);
        NSData *exported = [AppTheme JSONDataForRecord:theme.dictionaryRepresentation name:@"Gradient"];
        XCTAssertEqualObjects([AppTheme recordFromJSONData:exported name:NULL error:NULL], expected);
        theme.buttonGradient = @"always";
        XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
    }
}

- (void)testGlassyUsesArtworkOnlyButtonGradient {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:[AppTheme builtInRecordForIdentifier:@"glassy"]];
    XCTAssertEqualObjects(theme.buttonGradient, @"artwork");
}

- (void)testHiddenControlsRoundTripWithoutLosingTheirAppearance {
    NSDictionary *record = @{
        @"showTransportButtons": @NO, @"showStatusIcons": @NO, @"showTimeLabels": @NO,
        @"playButtonGlyph": @"play.circle.fill", @"buttonGradient": @"none",
        @"showRemainingTime": @YES, @"timeColorDark": @"#123456", @"infoFontSize": @11,
    };
    NSData *data = [AppTheme JSONDataForRecord:record name:@"Hidden"];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    XCTAssertEqualObjects(json[@"player"][@"showTransportButtons"], @NO);
    XCTAssertEqualObjects(json[@"info"][@"showStatusIcons"], @NO);
    XCTAssertEqualObjects(json[@"info"][@"showTimeLabels"], @NO);
    NSDictionary *back = [AppTheme recordFromJSONData:data name:NULL error:NULL];
    XCTAssertEqualObjects(back, record);
    AppTheme *theme = [[AppTheme alloc] initWithRecord:back];
    theme.showTransportButtons = YES;
    theme.showStatusIcons = YES;
    theme.showTimeLabels = YES;
    XCTAssertEqualObjects(theme.dictionaryRepresentation, (@{
        @"playButtonGlyph": @"play.circle.fill", @"buttonGradient": @"none",
        @"showRemainingTime": @YES, @"timeColorDark": @"#123456", @"infoFontSize": @11,
    }));
}

// The export walks the groups the field table names, so a new group's fields
// export as surely as they import.
- (void)testEveryGroupExportsInEditorOrder {
    NSDictionary *record = @{@"mode": @"single", @"titleFontSize": @24, @"showBPM": @NO,
                             @"waveformTheme": @"orange", @"playlistFontSize": @12};
    NSString *text = [[NSString alloc] initWithData:[AppTheme JSONDataForRecord:record name:@"All"]
                                           encoding:NSUTF8StringEncoding];
    NSUInteger previous = 0;
    for (NSString *group in @[@"window", @"player", @"info", @"waveform", @"playlist"]) {
        NSUInteger at = [text rangeOfString:[NSString stringWithFormat:@"\"%@\" :", group]].location;
        XCTAssertNotEqual(at, NSNotFound, @"%@ did not export", group);
        XCTAssertGreaterThan(at, previous, @"%@ is out of the editor's order", group);
        previous = at;
    }
}

#pragma mark Built-ins

- (void)testBuiltInIdentifiers {
    XCTAssertTrue([AppTheme isBuiltInIdentifier:@"vibe"]);
    XCTAssertTrue([AppTheme isBuiltInIdentifier:@"technical"]);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:@"Vibe"]);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:nil]);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:NSUUID.UUID.UUIDString]);
    XCTAssertTrue([AppTheme isBuiltInIdentifier:@"snake"]);
    XCTAssertTrue([AppTheme isBuiltInIdentifier:@"sonic_cirrus"]);
    XCTAssertEqualObjects([AppTheme builtInThemeIdentifiers],
                          (@[@"vibe", @"cupertino", @"field", @"glassy", @"record_bin", @"snake",
                              @"sonic_cirrus", @"tangerine", @"technical"]));
}

- (void)testVibeBuiltInIsTheEmptyRecord {
    XCTAssertEqualObjects([AppTheme builtInRecordForIdentifier:@"vibe"], @{});
}

// Custom waveform colors are read only under the custom theme, so beside
// "orange" they would be inert fields.
- (void)testSonicCirrusBuiltInIsExactlyItsOverrides {
    NSDictionary *record = [AppTheme builtInRecordForIdentifier:@"sonic_cirrus"];
    XCTAssertEqualObjects(record, (@{
        @"windowTint": @"mono",
        @"waveformStyle": @"sonic_cirrus",
        @"waveformTheme": @"orange",
    }));
    AppTheme *theme = [[AppTheme alloc] initWithRecord:record];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, record);
}

// A dual built-in spells out both sides: the custom waveform theme falls back
// to mono unless its pair is complete.
- (void)testDualModeBuiltInsAreCompleteAndOwnTheirArtwork {
    NSDictionary *artworked = @{@"cupertino": @"jpg", @"field": @"png"};
    for (NSString *identifier in @[@"cupertino", @"field", @"technical"]) {
        NSDictionary *record = [AppTheme builtInRecordForIdentifier:identifier];
        AppTheme *theme = [[AppTheme alloc] initWithRecord:record];
        XCTAssertEqualObjects(theme.dictionaryRepresentation, record, @"%@", identifier);
        XCTAssertFalse(theme.isSingleMode, @"%@", identifier);

        for (NSNumber *dark in @[@NO, @YES]) {
            BOOL isDark = dark.boolValue;
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorWaveformPlayed dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorWaveformUnplayed dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorWindowBackground dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorPlaylistBackground dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorTitle dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorArtist dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorInfo dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorTime dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorPlaylistPlayingRow dark:isDark], @"%@", identifier);
            XCTAssertNotNil([theme colorForBase:kVibeThemeColorPlaylistSelectedRow dark:isDark], @"%@", identifier);
        }
        // Dual, so a solid background never outranks the appearance setting.
        XCTAssertNil(theme.requiredWindowAppearance, @"%@", identifier);

        NSString *ext = artworked[identifier];
        if (ext) {
            XCTAssertEqualObjects([theme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark],
                    ([NSString stringWithFormat:@"bundled:%@_dark.%@", identifier, ext]));
            XCTAssertEqualObjects([theme imageReferenceForKey:kVibeThemeImageDefaultArtworkLight],
                    ([NSString stringWithFormat:@"bundled:%@_light.%@", identifier, ext]));
        }
    }
}

#pragma mark Names

- (void)testThemeNamesTrimCapAndFallBack {
    XCTAssertEqualObjects([AppTheme dedupedThemeName:@"  My Theme  " fallback:@"Custom"
                                       existingNames:@[]], @"My Theme");
    XCTAssertEqualObjects([AppTheme dedupedThemeName:@"   " fallback:@"Custom"
                                       existingNames:@[]], @"Custom");
    XCTAssertEqualObjects([AppTheme dedupedThemeName:nil fallback:@"Custom"
                                       existingNames:@[]], @"Custom");
    NSString *longName = [@"" stringByPaddingToLength:200 withString:@"N" startingAtIndex:0];
    XCTAssertEqual([AppTheme dedupedThemeName:longName fallback:@"Custom"
                                existingNames:@[]].length, 64u);
}

- (void)testThemeNamesDedupWithSuffixes {
    NSArray *existing = @[@"Vibe", @"industrial", @"My Theme", @"My Theme 2"];
    XCTAssertEqualObjects([AppTheme dedupedThemeName:@"My Theme" fallback:@"Custom"
                                       existingNames:existing], @"My Theme 3");
    XCTAssertEqualObjects([AppTheme dedupedThemeName:@"Industrial" fallback:@"Custom"
                                       existingNames:existing], @"Industrial 2");
    XCTAssertEqualObjects([AppTheme dedupedThemeName:@"Fresh" fallback:@"Custom"
                                       existingNames:existing], @"Fresh");
}

- (void)testSingleModeUsesOneColorSlotFromEitherSide {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"mode": @"single"}];
    [theme setColor:VibeColorFromHexString(@"#FF2200") forBase:kVibeThemeColorTitle dark:NO];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, (@{
        @"mode": @"single",
        @"titleColorDark": @"#FF2200",
    }));
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorTitle dark:YES]), @"#FF2200");
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorTitle dark:NO]), @"#FF2200");
}

- (void)testModeFlipsPreserveBothPalettes {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"titleColorDark": @"#111111",
        @"titleColorLight": @"#EEEEEE",
    }];
    theme.mode = @"single";
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorTitle dark:NO]), @"#111111");
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"titleColorLight"], @"#EEEEEE");
    theme.mode = @"dual";
    XCTAssertEqualObjects(VibeHexStringFromColor([theme colorForBase:kVibeThemeColorTitle dark:NO]), @"#EEEEEE");
}

- (void)testSingleModeAlwaysPinsTheDarkAppearance {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"mode": @"single"}];
    XCTAssertEqualObjects(theme.requiredWindowAppearance.name, NSAppearanceNameDarkAqua);
    [theme setColor:VibeColorFromHexString(@"#FFFFFF") forBase:kVibeThemeColorWindowBackground dark:YES];
    theme.windowBackgroundStyle = @"solid";
    XCTAssertEqualObjects(theme.requiredWindowAppearance.name, NSAppearanceNameDarkAqua);
    theme.mode = @"dual";
    XCTAssertNil(theme.requiredWindowAppearance);
}

- (void)testModeSnapsToDual {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"mode": @"tri"}];
    XCTAssertEqualObjects(theme.mode, @"dual");
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
    theme.mode = @"single";
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{@"mode": @"single"});
}

- (void)testDefaultArtworkSanitizesByShape {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:
            @{@"defaultArtworkDark": @"bundled:cupertino_dark.jpg"}];
    XCTAssertEqualObjects([theme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark],
            @"bundled:cupertino_dark.jpg");
    [theme setImageReference:@"custom:0123456789abcdef0123456789abcdef01234567.png"
                       forKey:kVibeThemeImageDefaultArtworkLight];
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtworkLight"],
            @"custom:0123456789abcdef0123456789abcdef01234567.png");
    // Wrong shapes drop to the default.
    for (NSString *bad in @[@"vinyl_red", @"bundled:Vinyl.png", @"bundled:../etc.png",
                            @"bundled:cupertino.webp", @"custom:short.png",
                            @"custom:0123456789abcdef0123456789abcdef01234567.gif"]) {
        [theme setImageReference:bad forKey:kVibeThemeImageDefaultArtworkDark];
        XCTAssertNil(theme.dictionaryRepresentation[@"defaultArtworkDark"], @"%@", bad);
    }
    XCTAssertNotNil([AppTheme imageForReference:nil]);
    XCTAssertNotNil([AppTheme imageForReference:@"never_shipped"]);
    // Single mode writes the dark slot from either side; the light half lies
    // dormant.
    theme.mode = @"single";
    [theme setImageReference:@"bundled:cupertino_light.jpg" forKey:kVibeThemeImageDefaultArtworkLight];
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtworkDark"],
            @"bundled:cupertino_light.jpg");
    XCTAssertEqualObjects([theme imageReferenceForKey:kVibeThemeImageDefaultArtworkLight],
            @"bundled:cupertino_light.jpg");
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtworkLight"],
            @"custom:0123456789abcdef0123456789abcdef01234567.png");
}

static NSData *SquarePNG(NSInteger side) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

// Now Playing rasterizes outside any view, where the drawing appearance is
// the system's, so it asks for the side its window shows. Each side is one
// cached image: the identity is what its dirty check compares.
- (void)testDefaultArtworkSideFollowsTheAppearanceItIsAskedFor {
    NSString *dark = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    NSString *light = [AppTheme storeCustomImageData:SquarePNG(64) error:NULL];
    XCTAssertNotEqualObjects(dark, light);
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    [theme setImageReference:dark forKey:kVibeThemeImageDefaultArtworkDark];
    [theme setImageReference:light forKey:kVibeThemeImageDefaultArtworkLight];
    NSAppearance *darkAqua = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSAppearance *aqua = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    XCTAssertEqual([theme defaultArtworkImageForAppearance:darkAqua], [AppTheme imageForReference:dark]);
    XCTAssertEqual([theme defaultArtworkImageForAppearance:aqua], [AppTheme imageForReference:light]);
    XCTAssertEqual([theme defaultArtworkImageForAppearance:aqua], [theme defaultArtworkImageForAppearance:aqua]);
    // Single mode keeps one image, the dark slot's, for either appearance.
    theme.mode = @"single";
    XCTAssertEqual([theme defaultArtworkImageForAppearance:aqua], [AppTheme imageForReference:dark]);
}

- (void)testCustomImageStoreValidatesAndRoundTripsThroughTheArchive {
    NSError *error = nil;
    NSBitmapImageRep *wide = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:128 pixelsHigh:64
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    XCTAssertNil([AppTheme storeCustomImageData:
            [wide representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            error:&error]);
    XCTAssertNil([AppTheme storeCustomImageData:SquarePNG(32) error:NULL]);
    XCTAssertNil([AppTheme storeCustomImageData:
            [@"not an image" dataUsingEncoding:NSUTF8StringEncoding] error:NULL]);

    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(256) error:&error];
    XCTAssertTrue([stored hasPrefix:@"custom:"], @"%@", error);
    XCTAssertNotNil([AppTheme imageForReference:stored]);

    NSDictionary *record = @{@"defaultArtworkDark": stored, @"waveformTheme": @"orange"};
    NSData *zip = [AppTheme archiveDataForRecord:record name:@"Art Theme"];
    XCTAssertNotNil(zip);
    // A zeroed DOS date is legal but extracts as 1979-11-29. Checked loosely:
    // the field packing is what breaks, not the clock.
    const uint8_t *raw = zip.bytes;
    NSUInteger dosDate = raw[12] | (raw[13] << 8);
    XCTAssertGreaterThanOrEqual(1980 + (dosDate >> 9), 2020u, @"year");
    XCTAssertTrue((dosDate >> 5 & 0xF) >= 1 && (dosDate >> 5 & 0xF) <= 12, @"month");
    XCTAssertTrue((dosDate & 0x1F) >= 1 && (dosDate & 0x1F) <= 31, @"day");
    NSString *name = nil;
    NSDictionary *back = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:&error];
    XCTAssertEqualObjects(name, @"Art Theme");
    XCTAssertEqualObjects(back, record); // same bytes re-hash to the same reference

    NSString *light = [AppTheme storeCustomImageData:SquarePNG(128) error:&error];
    XCTAssertTrue([light hasPrefix:@"custom:"], @"%@", error);
    NSDictionary *pair = @{@"defaultArtworkDark": stored, @"defaultArtworkLight": light};
    NSDictionary *pairBack = [AppTheme recordFromJSONOrArchiveData:
            [AppTheme archiveDataForRecord:pair name:@"Pair"] name:NULL error:&error];
    XCTAssertEqualObjects(pairBack, pair);

    XCTAssertNil([AppTheme archiveDataForRecord:@{@"waveformTheme": @"orange"}
                                           name:@"Plain"]);
    NSDictionary *dangling = [AppTheme recordFromJSONOrArchiveData:
            [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"name": @"D",
                    @"player": @{@"defaultArtworkDark":
                            @"custom:ffffffffffffffffffffffffffffffffffffffff.png"},
                    @"waveform": @{@"theme": @"orange"}} options:0 error:NULL]
            name:NULL error:NULL];
    XCTAssertEqualObjects(dangling, @{@"waveformTheme": @"orange"});
}

// Renames every occurrence of an ASCII string inside a zip, SAME LENGTH so the
// stored name-length fields stay valid. The reader does not verify CRCs, which
// is what makes this a fixture rather than a second zip writer.
static NSData *ZipWithBytesReplaced(NSData *zip, NSString *from, NSString *to) {
    NSData *f = [from dataUsingEncoding:NSASCIIStringEncoding];
    NSData *t = [to dataUsingEncoding:NSASCIIStringEncoding];
    NSCAssert(f.length == t.length, @"same-length replacement only");
    NSMutableData *out = [zip mutableCopy];
    NSRange search = NSMakeRange(0, out.length);
    NSRange hit;
    while ((hit = [out rangeOfData:f options:0 range:search]).location != NSNotFound) {
        [out replaceBytesInRange:hit withBytes:t.bytes length:t.length];
        NSUInteger next = hit.location + t.length;
        search = NSMakeRange(next, out.length - next);
    }
    return out;
}

// Import is the one path for a file a person picked: every malformation must
// end in "not a theme", never a raise or a half-applied record.
- (void)testMalformedInputIsRefusedRatherThanCrashing {
    NSError *error = nil;
    NSString *name = @"untouched";
    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:nil name:&name error:&error]);
    XCTAssertNil(name, @"the out-name is cleared even when the parse fails");
    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:NSData.data name:NULL error:NULL]);

    for (NSString *bad in @[@"", @"\x00\x01\x02", @"{", @"{\"version\" : ", @"not json at all",
                            @"[1,2,3]", @"\"a string\"", @"42", @"null", @"true"]) {
        NSData *data = [bad dataUsingEncoding:NSUTF8StringEncoding];
        XCTAssertNil([AppTheme recordFromJSONOrArchiveData:data name:NULL error:NULL],
                @"must refuse: %@", bad);
    }

    // An object carrying nothing known is still a theme: an older or newer
    // build's file relies on that tolerance.
    NSDictionary *empty = [AppTheme recordFromJSONOrArchiveData:
            [@"{}" dataUsingEncoding:NSUTF8StringEncoding] name:NULL error:NULL];
    XCTAssertEqualObjects(empty, @{}, @"an unknown-but-valid object imports as the defaults");

    // Over the JSON cap: refused before parsing.
    NSMutableString *huge = [NSMutableString stringWithString:@"{\"name\":\""];
    while (huge.length < 80 * 1024) {
        [huge appendString:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"];
    }
    [huge appendString:@"\"}"];
    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:
            [huge dataUsingEncoding:NSUTF8StringEncoding] name:NULL error:NULL],
            @"an over-cap JSON must be refused");

    // Over the archive cap (one image per image field at the store's cap, plus
    // slack): refused on size alone, before any unzip.
    NSMutableData *bigZip = [NSMutableData dataWithLength:
            AppTheme.imageFieldKeys.count * 8 * 1024 * 1024 + 1024 * 1024];
    [bigZip replaceBytesInRange:NSMakeRange(0, 4) withBytes:"PK\x03\x04" length:4];
    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:bigZip name:NULL error:&error],
            @"an over-cap archive must be refused");

    for (NSNumber *length in @[@2, @21, @64, @4096]) {
        NSMutableData *stub = [NSMutableData dataWithLength:length.unsignedIntegerValue];
        NSUInteger head = MIN((NSUInteger)4, stub.length);
        [stub replaceBytesInRange:NSMakeRange(0, head) withBytes:"PK\x03\x04" length:head];
        XCTAssertNil([AppTheme recordFromJSONOrArchiveData:stub name:NULL error:NULL],
                @"a %@-byte zip stub must be refused", length);
    }
    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    NSData *zip = [AppTheme archiveDataForRecord:@{@"defaultArtworkDark": stored} name:@"Whole"];
    for (NSUInteger cut = 1; cut < 4; cut++) {
        NSData *piece = [zip subdataWithRange:NSMakeRange(0, zip.length * cut / 4)];
        XCTAssertNil([AppTheme recordFromJSONOrArchiveData:piece name:NULL error:NULL],
                @"a zip truncated to %lu/4 must be refused", (unsigned long)cut);
    }
}

// No theme JSON and a corrupt one are refusals; a missing image is not — the
// theme imports and falls back to the factory art.
- (void)testWellFormedArchiveWithBadContentsDegradesPerCase {
    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    NSData *zip = [AppTheme archiveDataForRecord:
            @{@"defaultArtworkDark": stored, @"waveformTheme": @"orange"} name:@"Art"];

    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:
            ZipWithBytesReplaced(zip, @"theme.json", @"theme.jsom") name:NULL error:NULL],
            @"an archive with no theme JSON must be refused");

    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:
            ZipWithBytesReplaced(zip, @"\"version\" : 1", @"\"version\" : X")
                                                  name:NULL error:NULL],
            @"an archive carrying corrupt JSON must be refused");

    // Only the JSON changes: the `: "` prefix appears in no entry name.
    NSString *missing = nil;
    NSDictionary *record = [AppTheme recordFromJSONOrArchiveData:
            ZipWithBytesReplaced(zip, @": \"artwork_default_front.png\"",
                                      @": \"artwork_default_zzzzz.png\"")
                                                            name:&missing error:NULL];
    XCTAssertNotNil(record, @"a missing image must not sink the whole theme");
    XCTAssertEqualObjects(missing, @"Art", @"and the rest of the file still applies");
    XCTAssertEqualObjects(record[@"waveformTheme"], @"orange");
    XCTAssertNil(record[@"defaultArtworkDark"], @"the dangling reference is dropped");
}

// A built-in's art ships in Resources/Themes, not the container, but still
// travels in the archive: as bare JSON it would land on the factory art on any
// build that does not ship that image.
- (void)testBuiltInArtworkTravelsInTheArchiveUnderSlotNames {
    NSDictionary *record = [AppTheme builtInRecordForIdentifier:@"cupertino"];
    XCTAssertEqualObjects(record[@"defaultArtworkDark"],
            @"bundled:cupertino_dark.jpg", @"the fixture this test rests on");

    NSData *zip = [AppTheme archiveDataForRecord:record name:@"Cupertino"];
    XCTAssertNotNil(zip, @"a built-in with bundled art must export as an archive");
    XCTAssertGreaterThan(zip.length, 50000u, @"the images themselves, not just their names");

    // Entries are named by slot, not by hash or this build's filename, and keep
    // the source image's extension.
    NSString *bytes = [[NSString alloc] initWithData:zip encoding:NSISOLatin1StringEncoding];
    XCTAssertTrue([bytes containsString:@"artwork_default_front.jpg"]);
    XCTAssertTrue([bytes containsString:@"artwork_default_back.jpg"]);
    XCTAssertFalse([bytes containsString:@"bundled:"], @"no prefix survives into the archive");
    XCTAssertFalse([bytes containsString:@"cupertino_dark.jpg"],
            @"nor the name this build happens to keep the image under");

    // Re-import lands both sides in the container under their content hashes,
    // independent of this build shipping the image.
    NSString *name = nil;
    NSDictionary *back = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:NULL];
    XCTAssertEqualObjects(name, @"Cupertino");
    XCTAssertTrue([back[@"defaultArtworkDark"] hasPrefix:@"custom:"], @"%@", back);
    XCTAssertTrue([back[@"defaultArtworkLight"] hasPrefix:@"custom:"], @"%@", back);
    XCTAssertNotEqualObjects(back[@"defaultArtworkDark"], back[@"defaultArtworkLight"],
            @"the two sides are different images and must not collapse");
    // Resolves to real art, not the placeholder a missing reference draws.
    XCTAssertNotEqual([AppTheme imageForReference:back[@"defaultArtworkDark"]],
            [AppTheme imageForReference:@""]);
    XCTAssertEqualObjects(back[@"waveformTheme"], record[@"waveformTheme"]);
    XCTAssertEqualObjects(back[@"mode"], record[@"mode"]);
}

- (void)testEveryImageFieldTravelsInTheArchiveUnderItsSlotName {
    NSString *icon = [AppTheme storeCustomImageData:SquarePNG(128) error:NULL];
    NSString *play = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    NSString *pause = [AppTheme storeCustomImageData:SquarePNG(80) error:NULL];
    NSDictionary *record = @{@"appIcon": icon, @"playButtonImageDark": play,
                             @"pauseButtonImageLight": pause, @"nextButtonGlyph": @"chevron.right"};
    NSData *zip = [AppTheme archiveDataForRecord:record name:@"Icons"];
    XCTAssertNotNil(zip);
    NSString *bytes = [[NSString alloc] initWithData:zip encoding:NSISOLatin1StringEncoding];
    XCTAssertTrue([bytes containsString:@"app_icon.png"]);
    XCTAssertTrue([bytes containsString:@"button_play_dark.png"]);
    XCTAssertTrue([bytes containsString:@"button_pause_light.png"]);
    XCTAssertFalse([bytes containsString:@"artwork_default"], @"no entry for an empty slot");
    NSString *name = nil;
    NSDictionary *back = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:NULL];
    XCTAssertEqualObjects(name, @"Icons");
    XCTAssertEqualObjects(back, record, @"same bytes, same hashes, glyph untouched");
}

// Single mode and both-sides-alike pairs would otherwise double the archive.
- (void)testOneImageOnBothSidesShipsOneEntry {
    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(256) error:NULL];
    NSData *zip = [AppTheme archiveDataForRecord:
            @{@"defaultArtworkDark": stored, @"defaultArtworkLight": stored} name:@"One"];
    NSString *bytes = [[NSString alloc] initWithData:zip encoding:NSISOLatin1StringEncoding];
    XCTAssertTrue([bytes containsString:@"artwork_default_front.png"]);
    XCTAssertFalse([bytes containsString:@"artwork_default_back.png"],
            @"the second slot reuses the first slot's entry");
    NSDictionary *back = [AppTheme recordFromJSONOrArchiveData:zip name:NULL error:NULL];
    XCTAssertEqualObjects(back[@"defaultArtworkDark"], stored, @"same bytes, same hash");
    XCTAssertEqualObjects(back[@"defaultArtworkLight"], stored);
}

// imageForReference: falls back to the factory image for a value it cannot
// resolve; the editor's warning badge needs to tell the two apart.
- (void)testMissingArtworkIsToldApartFromTheDefault {
    // The factory default and a malformed value (the sanitizer drops it) are
    // not "missing".
    XCTAssertFalse([AppTheme referenceIsMissing:nil]);
    XCTAssertFalse([AppTheme referenceIsMissing:@""]);
    XCTAssertFalse([AppTheme referenceIsMissing:@"nonsense"]);
    XCTAssertFalse([AppTheme referenceIsMissing:@"custom:short.png"]);

    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    XCTAssertFalse([AppTheme referenceIsMissing:stored]);
    [NSFileManager.defaultManager removeItemAtPath:
            [@(getenv("VIBE_THEME_ART_DIR")) stringByAppendingPathComponent:
                    [stored substringFromIndex:7]] error:NULL];
    XCTAssertTrue([AppTheme referenceIsMissing:stored]);
    XCTAssertNotNil([AppTheme imageForReference:stored]);

    XCTAssertFalse([AppTheme referenceIsMissing:@"bundled:cupertino_dark.jpg"]);
    XCTAssertTrue([AppTheme referenceIsMissing:@"bundled:not_in_any_build.png"]);
}

// The suite-wide redirect (TestFilesystemGuard.m) must be in force before
// setUp narrows it, and nothing may land where production writes.
- (void)testStoredArtworkStaysInTempAndNeverTouchesTheRealLibrary {
    XCTAssertTrue([_suiteArtDir hasPrefix:NSTemporaryDirectory()],
            @"the load-time guard must redirect the whole suite into the temp directory, got '%@'", _suiteArtDir);
    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    XCTAssertTrue([stored hasPrefix:@"custom:"]);

    NSString *file = [stored substringFromIndex:7];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[_artDir stringByAppendingPathComponent:file]],
            @"the image must be written under the redirect");
    NSString *real = [[NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier ?: @"Vibe"]
            stringByAppendingPathComponent:@"ThemeArt"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[real stringByAppendingPathComponent:file]],
            @"nothing may be written to the real Application Support");
}

- (void)testBundledThemesAreValid {
    // Import drops a typo'd key or malformed value rather than rejecting the
    // file, so validity means the raw file survives the sanitizer unchanged.
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSArray<NSURL *> *urls = [bundle URLsForResourcesWithExtension:@"json"
                                                      subdirectory:@"Themes"];
    XCTAssertGreaterThanOrEqual(urls.count, 3u, @"bundled themes missing from the test bundle");
    NSMutableSet *seen = [NSMutableSet set];
    NSRegularExpression *snake = [NSRegularExpression
            regularExpressionWithPattern:@"^[a-z0-9]+(_[a-z0-9]+)*$" options:0 error:NULL];
    for (NSURL *url in urls) {
        NSString *file = url.lastPathComponent;
        NSString *identifier = file.stringByDeletingPathExtension;
        XCTAssertEqual([snake numberOfMatchesInString:identifier options:0
                range:NSMakeRange(0, identifier.length)], 1,
                @"%@: the filename stem is the identifier and must be lowercase snake_case", file);
        XCTAssertFalse([seen containsObject:identifier], @"%@: duplicate identifier", file);
        [seen addObject:identifier];

        NSData *data = [NSData dataWithContentsOfURL:url];
        NSDictionary *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        XCTAssertTrue([raw isKindOfClass:NSDictionary.class], @"%@: not a JSON object", file);
        XCTAssertEqualObjects(raw[@"version"], @1, @"%@: version must be 1", file);
        XCTAssertTrue([raw[@"name"] isKindOfClass:NSString.class]
                && [raw[@"name"] length] > 0, @"%@: name missing", file);

        NSString *name = nil;
        NSDictionary *record = [AppTheme recordFromJSONData:data name:&name error:NULL];
        XCTAssertNotNil(record, @"%@: unreadable", file);
        NSDictionary *reexported = [NSJSONSerialization JSONObjectWithData:
                [AppTheme JSONDataForRecord:record name:name] options:0 error:NULL];
        NSMutableDictionary *expected = [raw mutableCopy];
        [expected removeObjectForKey:@"description"];
        XCTAssertEqualObjects(expected, reexported,
                @"%@: a group, field key or value did not survive the sanitizer — typo, "
                @"bad hex, or out-of-range value", file);
    }
    XCTAssertTrue([seen containsObject:@"vibe"], @"vibe.json must exist");

    // Every bundled image must pass the same validation as a picked image,
    // and every built-in bundled: reference must resolve to one of them.
    NSMutableSet<NSString *> *bundledArt = [NSMutableSet set];
    for (NSString *ext in @[@"png", @"jpg"]) {
        for (NSURL *url in [bundle URLsForResourcesWithExtension:ext
                subdirectory:@"Themes"]) {
            NSString *reference = [@"bundled:"
                    stringByAppendingString:url.lastPathComponent];
            [bundledArt addObject:reference];
            NSError *artError = nil;
            XCTAssertNotNil([AppTheme storeCustomImageData:
                    [NSData dataWithContentsOfURL:url] error:&artError],
                    @"%@: %@", url.lastPathComponent, artError);
        }
    }
    XCTAssertGreaterThanOrEqual(bundledArt.count, 2u, @"bundled theme artwork missing");
    for (NSString *identifier in [AppTheme builtInThemeIdentifiers]) {
        NSDictionary *record = [AppTheme builtInRecordForIdentifier:identifier];
        for (NSString *key in AppTheme.imageFieldKeys) {
            NSString *art = record[key];
            XCTAssertFalse([art hasPrefix:@"custom:"],
                    @"%@: a built-in must name bundled art, not a custom image", identifier);
            if (art.length) {
                XCTAssertTrue([bundledArt containsObject:art],
                        @"%@: names art the bundle does not carry (%@)", identifier, art);
            }
        }
        // Without the switch the gate adds it on import, and the round trip
        // above would drift.
        if (record[@"windowCornerRadius"]) {
            XCTAssertEqualObjects(record[@"customCornerRadius"], @YES,
                    @"%@: sets a radius without customCornerRadius", identifier);
        }
    }
}

#pragma mark Migration

- (void)testUntouchedLegacyValuesMigrateToNothing {
    XCTAssertNil([AppTheme migratedRecordFromLegacyValues:@{}]);
    // Stored-but-default values are no reason to mint a theme either.
    XCTAssertNil(([AppTheme migratedRecordFromLegacyValues:@{
        @"waveformTheme": @"mono",
        @"showFileInfo": @YES,
    }]));
}

- (void)testCustomizedLegacyValuesMigrateToTheirSparseDiff {
    NSDictionary *record = [AppTheme migratedRecordFromLegacyValues:@{
        @"waveformStyle": @"sonic_cirrus",
        @"waveformTheme": @"orange",
        @"windowTint": @"mono",
        @"showFileInfo": @NO,
        @"waveformPlayedColorDark": @"#FF7300",
    }];
    XCTAssertEqualObjects(record, (@{
        @"waveformStyle": @"sonic_cirrus",
        @"waveformTheme": @"orange",
        @"windowTint": @"mono",
        @"showFileInfo": @NO,
        @"waveformPlayedColorDark": @"#FF7300",
    }));
}

- (void)testJunkLegacyValuesMigrateToNothing {
    XCTAssertNil(([AppTheme migratedRecordFromLegacyValues:@{
        @"waveformTheme": @"never_a_theme",
        @"windowTintColorDark": @"not-hex",
    }]));
}


#pragma mark Album-art caps and ZIP safety

// A minimal stored (uncompressed) ZIP, so a test can shape entries the way a
// Finder archive or a crafted file would — VibeZipData is file-static to
// AppTheme+Archive.m.
static void PutLE(NSMutableData *d, uint64_t v, int n) {
    for (int i = 0; i < n; i++) { uint8_t b = (v >> (8 * i)) & 0xFF; [d appendBytes:&b length:1]; }
}
// VibeUnzipData reads no CRC field (and storeCustomImageData re-hashes the
// image by content), so the entries carry a zero CRC — nothing validates it.
static NSData *MakeStoredZip(NSArray<NSArray *> *entries) { // [ [name, NSData], ... ]
    NSMutableData *out = [NSMutableData data], *central = [NSMutableData data];
    for (NSArray *e in entries) {
        NSData *nameData = [e[0] dataUsingEncoding:NSUTF8StringEncoding], *data = e[1];
        uint32_t crc = 0; NSUInteger off = out.length;
        PutLE(out, 0x04034b50, 4); PutLE(out, 20, 2); PutLE(out, 0, 2); PutLE(out, 0, 2);
        PutLE(out, 0, 4); PutLE(out, crc, 4); PutLE(out, data.length, 4); PutLE(out, data.length, 4);
        PutLE(out, nameData.length, 2); PutLE(out, 0, 2); [out appendData:nameData]; [out appendData:data];
        PutLE(central, 0x02014b50, 4); PutLE(central, 20, 2); PutLE(central, 20, 2); PutLE(central, 0, 2);
        PutLE(central, 0, 2); PutLE(central, 0, 4); PutLE(central, crc, 4); PutLE(central, data.length, 4);
        PutLE(central, data.length, 4); PutLE(central, nameData.length, 2); PutLE(central, 0, 2);
        PutLE(central, 0, 2); PutLE(central, 0, 2); PutLE(central, 0, 2); PutLE(central, 0, 4);
        PutLE(central, off, 4); [central appendData:nameData];
    }
    NSUInteger cOff = out.length; [out appendData:central];
    PutLE(out, 0x06054b50, 4); PutLE(out, 0, 2); PutLE(out, 0, 2);
    PutLE(out, entries.count, 2); PutLE(out, entries.count, 2);
    PutLE(out, central.length, 4); PutLE(out, cOff, 4); PutLE(out, 0, 2);
    return out;
}

- (void)testAlbumArtValidationCaps {
    // The byte cap is checked before any decode.
    NSMutableData *huge = [NSMutableData dataWithLength:8 * 1024 * 1024 + 1];
    uint8_t jpeg[3] = {0xFF, 0xD8, 0xFF}; [huge replaceBytesInRange:NSMakeRange(0, 3) withBytes:jpeg];
    XCTAssertNil([AppTheme storeCustomImageData:huge error:NULL]);
    // The 64 px floor is covered above; the 4096 ceiling is the same check.
    XCTAssertNotNil([AppTheme storeCustomImageData:SquarePNG(64) error:NULL]);
}

- (void)testArchiveReaderIsSafeOnTruncatedAndGarbageInput {
    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(64) error:NULL];
    NSData *zip = [AppTheme archiveDataForRecord:@{@"defaultArtworkDark": stored} name:@"Z"];
    XCTAssertNotNil(zip);
    for (NSUInteger cut = 0; cut < zip.length; cut++) {
        NSData *piece = [zip subdataWithRange:NSMakeRange(0, cut)];
        XCTAssertNoThrow([AppTheme recordFromJSONOrArchiveData:piece name:NULL error:NULL]);
    }
    NSData *garbage = [@"PK\x03\x04 not a real zip at all" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:garbage name:NULL error:NULL]);
}

- (void)testArchiveReaderHandlesFinderShapedArchives {
    NSString *stored = [AppTheme storeCustomImageData:SquarePNG(64) error:NULL];
    NSString *file = [stored substringFromIndex:7]; // <sha1>.png
    NSData *image = [NSData dataWithContentsOfFile:
            [_artDir stringByAppendingPathComponent:file]];
    NSData *themeJSON = [AppTheme JSONDataForRecord:@{@"defaultArtworkDark": stored}
                                                name:@"Finder"];

    // The AppleDouble sidecar ends in .json but is not JSON; the image sits
    // under a folder prefix.
    NSData *zip = MakeStoredZip(@[
        @[@"__MACOSX/._theme.json", [@"garbage" dataUsingEncoding:NSUTF8StringEncoding]],
        @[@"My Theme/theme.json", themeJSON],
        @[[@"My Theme/" stringByAppendingString:file], image],
    ]);
    NSString *name = nil;
    NSDictionary *record = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:NULL];
    XCTAssertEqualObjects(name, @"Finder");
    XCTAssertEqualObjects(record[@"defaultArtworkDark"], stored); // art survived, re-hashed
}

// A hand-made archive names images by entry basename, custom: prefix
// optional, normalized to custom:<sha1> on import. Outside an archive there is
// nothing to resolve against, so those shapes stay refused; a name matching no
// entry drops without taking the theme.
- (void)testArchiveImportAcceptsHumanNamedCustomReferences {
    NSData *dark = SquarePNG(64), *light = SquarePNG(128);
    NSString *expectedDark = [AppTheme storeCustomImageData:dark error:NULL];
    NSString *expectedLight = [AppTheme storeCustomImageData:light error:NULL];
    NSData *themeJSON = [NSJSONSerialization dataWithJSONObject:@{
        @"version": @1, @"name": @"Named",
        @"player": @{@"defaultArtworkDark": @"cover_dark.png",
                     @"defaultArtworkLight": @"custom:cover_light.png"},
        @"waveform": @{@"theme": @"orange"},
    } options:0 error:NULL];
    NSData *zip = MakeStoredZip(@[
        @[@"theme.json", themeJSON],
        @[@"cover_dark.png", dark],
        @[@"cover_light.png", light],
    ]);
    NSString *name = nil;
    NSDictionary *record = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:NULL];
    XCTAssertEqualObjects(name, @"Named");
    XCTAssertEqualObjects(record[@"defaultArtworkDark"], expectedDark);
    XCTAssertEqualObjects(record[@"defaultArtworkLight"], expectedLight);
    XCTAssertEqualObjects(record[@"waveformTheme"], @"orange");

    NSData *danglingJSON = [NSJSONSerialization dataWithJSONObject:@{
        @"version": @1, @"name": @"Dangling",
        @"player": @{@"defaultArtworkDark": @"missing.png"},
        @"waveform": @{@"theme": @"orange"},
    } options:0 error:NULL];
    NSDictionary *dangling = [AppTheme recordFromJSONOrArchiveData:
            MakeStoredZip(@[@[@"theme.json", danglingJSON]]) name:NULL error:NULL];
    XCTAssertNil(dangling[@"defaultArtworkDark"]);
    XCTAssertEqualObjects(dangling[@"waveformTheme"], @"orange");

    NSDictionary *jsonOnly = [AppTheme recordFromJSONOrArchiveData:themeJSON
                                                              name:NULL error:NULL];
    XCTAssertNil(jsonOnly[@"defaultArtworkDark"]);
    XCTAssertNil(jsonOnly[@"defaultArtworkLight"]);

    // Under the 64 px floor: the field drops, the theme does not.
    NSError *error = nil;
    NSDictionary *badImage = [AppTheme recordFromJSONOrArchiveData:MakeStoredZip(@[
        @[@"theme.json", danglingJSON],
        @[@"missing.png", SquarePNG(32)],
    ]) name:NULL error:&error];
    XCTAssertNil(badImage[@"defaultArtworkDark"]);
    XCTAssertEqualObjects(badImage[@"waveformTheme"], @"orange");
    XCTAssertNil(error, @"a dropped image is not an import failure");
}

#pragma mark Store CRUD (AppSettings)

- (AppSettings *)editingSettings {
    _editingSettings = AppSettings.sharedInstance;
    [_editingSettings factoryReset];
    NSString *identifier = [_editingSettings addUserThemeWithRecord:@{} name:@"Editing"];
    [_editingSettings applyThemeWithIdentifier:identifier];
    return _editingSettings;
}

- (void)testUserThemeEditsPersistAndUndoRestoresTheSameWorkingObject {
    AppSettings *settings = self.editingSettings;
    AppTheme *working = settings.currentTheme;
    working.showFileInfo = NO;
    [settings currentThemeDidChange];
    XCTAssertTrue(settings.canUndoThemeEdit);
    AppSettings *reloaded = [AppSettings new];
    XCTAssertEqualObjects(reloaded.activeThemeIdentifier, settings.activeThemeIdentifier);
    XCTAssertFalse(reloaded.currentTheme.showFileInfo);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme, working);
    XCTAssertTrue(working.showFileInfo);
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:settings.activeThemeIdentifier], @{});
    XCTAssertTrue([AppSettings new].currentTheme.showFileInfo);
}

- (void)testRedoRestoresEditsAndRenamesInOrder {
    AppSettings *settings = self.editingSettings;
    NSString *identifier = settings.activeThemeIdentifier;
    AppTheme *working = settings.currentTheme;
    working.showFileInfo = NO;
    [settings currentThemeDidChange];
    [settings renameUserThemeWithIdentifier:identifier toName:@"Renamed"];
    [settings undoThemeEdit];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqual(settings.currentTheme, working);
    XCTAssertFalse(working.showFileInfo);
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Editing");
    [settings redoThemeEdit];
    XCTAssertEqualObjects([[AppSettings new] displayNameForThemeIdentifier:identifier], @"Renamed");
    XCTAssertFalse(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Renamed");
}

- (void)testAddingOrDuplicatingThemesDiscardsHistoryWithoutChangingCurrentTheme {
    for (NSNumber *duplicate in @[@NO, @YES]) {
        AppSettings *settings = self.editingSettings;
        [settings applyThemeWithIdentifier:@"vibe"];
        AppTheme *working = settings.currentTheme;
        working.showFileInfo = NO;
        [settings currentThemeDidChange];
        working.showTimeLabels = NO;
        [settings currentThemeDidChange];
        [settings undoThemeEdit];
        XCTAssertTrue(settings.canUndoThemeEdit);
        XCTAssertTrue(settings.canRedoThemeEdit);
        NSDictionary *record = working.dictionaryRepresentation;
        NSString *added = duplicate.boolValue
                ? [settings duplicateThemeWithIdentifier:@"vibe"]
                : [settings addUserThemeWithRecord:record name:@"Imported"];
        NSArray *order = settings.orderedThemeIdentifiers;
        XCTAssertFalse(settings.canUndoThemeEdit);
        XCTAssertFalse(settings.canRedoThemeEdit);
        [settings undoThemeEdit];
        [settings redoThemeEdit];
        XCTAssertEqualObjects(settings.orderedThemeIdentifiers, order);
        XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
        XCTAssertEqual(settings.currentTheme, working);
        XCTAssertEqualObjects(working.dictionaryRepresentation, record);
        XCTAssertTrue(settings.currentThemeIsModified);
        XCTAssertEqualObjects([[AppSettings new] recordForThemeIdentifier:added], record);
    }
}

- (void)testThemeDragCoalescesFromTheFirstEditAndExtendsItsQuietPeriod {
    AppSettings *settings = self.editingSettings;
    for (NSUInteger i = 0; i < 4; i++) {
        settings.currentTheme.windowCornerRadius = 20 + i;
        [settings currentThemeDidChangeContinuous:YES atTime:100 + i * 1.5];
    }
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, kVibeThemeCornerRadiusDefault);
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 23);
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testThemeDragAtTwoSecondsStartsAnotherUndoEntry {
    AppSettings *settings = self.editingSettings;
    settings.currentTheme.windowCornerRadius = 20;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    settings.currentTheme.windowCornerRadius = 24;
    [settings currentThemeDidChangeContinuous:YES atTime:102];
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 20);
    XCTAssertTrue(settings.canUndoThemeEdit);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, kVibeThemeCornerRadiusDefault);
    XCTAssertFalse(settings.canUndoThemeEdit);
}

- (void)testDifferentThemeFieldsNeverCoalesce {
    AppSettings *settings = self.editingSettings;
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    settings.currentTheme.showBPM = NO;
    [settings currentThemeDidChangeContinuous:YES atTime:100.1];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showBPM);
    XCTAssertFalse(settings.currentTheme.showFileInfo);
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showFileInfo);
    XCTAssertFalse(settings.canUndoThemeEdit);
}

- (void)testUnchangedThemeWriteDoesNotCreateOrExtendAnUndoEntry {
    AppSettings *settings = self.editingSettings;
    [settings currentThemeDidChangeContinuous:YES atTime:99];
    XCTAssertFalse(settings.canUndoThemeEdit);
    settings.currentTheme.windowCornerRadius = 20;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    [settings currentThemeDidChangeContinuous:YES atTime:101.9];
    settings.currentTheme.windowCornerRadius = 24;
    [settings currentThemeDidChangeContinuous:YES atTime:102];
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 20);
    XCTAssertTrue(settings.canUndoThemeEdit);
}

- (void)testEditingAfterUndoStartsFreshHistory {
    AppSettings *settings = self.editingSettings;
    settings.currentTheme.windowCornerRadius = 20;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    settings.currentTheme.windowCornerRadius = 24;
    [settings currentThemeDidChangeContinuous:YES atTime:103];
    [settings undoThemeEdit];
    settings.currentTheme.windowCornerRadius = 28;
    [settings currentThemeDidChangeContinuous:YES atTime:103.1];
    XCTAssertFalse(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 28);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 20);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, kVibeThemeCornerRadiusDefault);
    XCTAssertFalse(settings.canUndoThemeEdit);
}

- (void)testThemeHistoryKeepsOnlyFiftyEdits {
    AppSettings *settings = self.editingSettings;
    for (NSUInteger i = 0; i < 55; i++) {
        settings.currentTheme.showFileInfo = !settings.currentTheme.showFileInfo;
        [settings currentThemeDidChangeContinuous:YES atTime:100 + i * 3];
    }
    for (NSUInteger i = 0; i < 50; i++) {
        XCTAssertTrue(settings.canUndoThemeEdit);
        [settings undoThemeEdit];
    }
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertFalse(settings.currentTheme.showFileInfo); // five edits remain
    [settings undoThemeEdit];
    XCTAssertFalse(settings.currentTheme.showFileInfo);
    for (NSUInteger i = 0; i < 50; i++) {
        XCTAssertTrue(settings.canRedoThemeEdit);
        [settings redoThemeEdit];
    }
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testApplyingAnotherThemeClearsUndoWithoutChangingTheOldRecord {
    AppSettings *settings = self.editingSettings;
    NSString *edited = settings.activeThemeIdentifier;
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    [settings applyThemeWithIdentifier:@"vibe"];
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showFileInfo);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:edited][@"showFileInfo"], @NO);
}

- (void)testBuiltInDivergencePersistsAndUndoKeepsTheBuiltInPristine {
    AppSettings *settings = self.editingSettings;
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    XCTAssertTrue(settings.canUndoThemeEdit);
    XCTAssertTrue(settings.currentThemeIsModified);
    XCTAssertFalse([AppSettings new].currentTheme.showFileInfo);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:@"vibe"], @{});
    [settings undoThemeEdit];
    XCTAssertFalse(settings.currentThemeIsModified);
    XCTAssertTrue([AppSettings new].currentTheme.showFileInfo);
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertTrue(settings.currentThemeIsModified);
    XCTAssertFalse([AppSettings new].currentTheme.showFileInfo);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:@"vibe"], @{});
}

- (void)testDuplicateAndRenamePreserveRecordsAndDeduplicateNames {
    AppSettings *settings = self.editingSettings;
    NSString *original = settings.activeThemeIdentifier;
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    NSString *duplicate = [settings duplicateThemeWithIdentifier:original];
    XCTAssertNotEqualObjects(duplicate, original);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:duplicate],
                          [settings recordForThemeIdentifier:original]);
    XCTAssertNotEqualObjects([settings displayNameForThemeIdentifier:duplicate], @"Editing");
    [settings renameUserThemeWithIdentifier:duplicate toName:@"  Renamed  "];
    XCTAssertEqualObjects([[AppSettings new] displayNameForThemeIdentifier:duplicate], @"Renamed");
    [settings renameUserThemeWithIdentifier:duplicate toName:@"Editing"];
    XCTAssertNotEqualObjects([settings displayNameForThemeIdentifier:duplicate], @"Editing");
    XCTAssertEqualObjects(settings.activeThemeIdentifier, original);
    XCTAssertNil([settings duplicateThemeWithIdentifier:@"missing"]);
}

- (void)testBuiltInsRefuseRenameAndRemovalButCanBeDuplicated {
    AppSettings *settings = self.editingSettings;
    NSString *name = [settings displayNameForThemeIdentifier:@"vibe"];
    [settings renameUserThemeWithIdentifier:@"vibe" toName:@"Changed"];
    [settings removeUserThemeWithIdentifier:@"vibe" fallingBackTo:nil];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:@"vibe"], name);
    XCTAssertTrue([settings.orderedThemeIdentifiers containsObject:@"vibe"]);
    NSString *duplicate = [settings duplicateThemeWithIdentifier:@"vibe"];
    XCTAssertNotNil(duplicate);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:duplicate]);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:duplicate], @{});
}

- (void)testDuplicatingTheActiveBuiltInPreservesItsWorkingAppearance {
    AppSettings *settings = self.editingSettings;
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.waveformStyle = @"detailed";
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    NSDictionary *workingRecord = settings.currentTheme.dictionaryRepresentation;

    NSString *duplicate = [settings duplicateThemeWithIdentifier:@"vibe"];
    XCTAssertNotNil(duplicate);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:duplicate], workingRecord);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:@"vibe"], @{});
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    XCTAssertTrue(settings.currentThemeIsModified);

    [settings applyThemeWithIdentifier:duplicate];
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, workingRecord);
    XCTAssertEqualObjects([AppSettings new].currentTheme.dictionaryRepresentation, workingRecord);
    XCTAssertFalse(settings.currentThemeIsModified);
}

- (void)testRemovingAnActiveThemeUsesOnlyASurvivingFallback {
    AppSettings *settings = self.editingSettings;
    NSString *first = settings.activeThemeIdentifier;
    NSString *second = [settings addUserThemeWithRecord:@{@"showFileInfo": @NO} name:@"Second"];
    [settings removeUserThemeWithIdentifier:first fallingBackTo:second];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, second);
    XCTAssertFalse(settings.currentTheme.showFileInfo);
    [settings removeUserThemeWithIdentifier:second fallingBackTo:second];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    XCTAssertTrue(settings.currentTheme.showFileInfo);
}

- (NSString *)installEditingImageInSettings:(AppSettings *)settings {
    NSString *reference = [AppTheme storeCustomImageData:SquarePNG(64) error:NULL];
    XCTAssertNotNil(reference);
    [settings.currentTheme setImageReference:reference forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    [settings applyThemeWithIdentifier:settings.activeThemeIdentifier]; // begin with clean history
    return [_artDir stringByAppendingPathComponent:[reference substringFromIndex:7]];
}

- (void)testInactiveRenameDiscardsHistoryButUnchangedNameKeepsIt {
    AppSettings *settings = self.editingSettings;
    NSString *other = [settings addUserThemeWithRecord:@{} name:@"Other"];
    NSString *active = settings.activeThemeIdentifier;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    NSDictionary *working = settings.currentTheme.dictionaryRepresentation;
    [settings renameUserThemeWithIdentifier:other toName:@"Other"];
    XCTAssertTrue(settings.canUndoThemeEdit);
    XCTAssertTrue(settings.canRedoThemeEdit);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings renameUserThemeWithIdentifier:other toName:@"Renamed"];
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertFalse(settings.canRedoThemeEdit);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    [settings redoThemeEdit];
    XCTAssertEqualObjects([[AppSettings new] displayNameForThemeIdentifier:other], @"Renamed");
    XCTAssertEqualObjects(settings.activeThemeIdentifier, active);
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, working);
}

- (void)testAddingThemeSweepsDiscardedHistoryAfterRetainingImportedImages {
    AppSettings *settings = self.editingSettings;
    NSString *oldPath = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:oldPath]);
    NSString *imported = [AppTheme storeCustomImageData:SquarePNG(128) error:NULL];
    XCTAssertNotNil(imported);
    NSString *importedPath = [_artDir stringByAppendingPathComponent:[imported substringFromIndex:7]];
    XCTAssertNotEqualObjects(oldPath, importedPath);
    NSString *added = [settings addUserThemeWithRecord:@{@"defaultArtworkDark": imported} name:@"Imported"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:oldPath]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:importedPath]);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:added][@"defaultArtworkDark"], imported);
}

- (void)testRemovalUndoRestoresIdentityOrderImagesAndEarlierEdits {
    AppSettings *settings = self.editingSettings;
    NSString *first = settings.activeThemeIdentifier;
    NSString *path = [self installEditingImageInSettings:settings];
    NSString *second = [settings addUserThemeWithRecord:@{} name:@"Second"];
    NSArray *order = settings.orderedThemeIdentifiers;
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    [settings removeUserThemeWithIdentifier:first fallingBackTo:second];
    XCTAssertTrue(settings.themeUndoRemovesTheme);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings removeUserThemeWithIdentifier:second fallingBackTo:nil];
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, second);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, order);
    XCTAssertEqualObjects(settings.activeThemeIdentifier, first);
    XCTAssertFalse(settings.currentTheme.showFileInfo);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showFileInfo);
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings removeUserThemeWithIdentifier:first fallingBackTo:nil];
    [settings applyThemeWithIdentifier:@"vibe"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testRemovalUndoRestoresInactiveThemeWithoutLosingBuiltInDivergence {
    AppSettings *settings = self.editingSettings;
    NSString *removed = settings.activeThemeIdentifier;
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.showTimeLabels = NO;
    [settings currentThemeDidChange];
    [settings removeUserThemeWithIdentifier:removed fallingBackTo:nil];
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    XCTAssertFalse(settings.currentTheme.showTimeLabels);
    XCTAssertTrue(settings.currentThemeIsModified);
    XCTAssertTrue([settings.orderedThemeIdentifiers containsObject:removed]);
    [settings redoThemeEdit];
    XCTAssertFalse([settings.orderedThemeIdentifiers containsObject:removed]);
    XCTAssertFalse(settings.currentTheme.showTimeLabels);
    [settings undoThemeEdit];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showTimeLabels);
}

- (void)testRemovalRedoKeepsFallbackOrderImagesAndPreviousEdits {
    AppSettings *settings = self.editingSettings;
    NSString *removed = settings.activeThemeIdentifier;
    NSString *path = [self installEditingImageInSettings:settings];
    NSString *fallback = [settings addUserThemeWithRecord:@{@"showFileInfo": @NO} name:@"Fallback"];
    NSArray *order = settings.orderedThemeIdentifiers;
    settings.currentTheme.showTimeLabels = NO;
    [settings currentThemeDidChange];
    [settings removeUserThemeWithIdentifier:removed fallingBackTo:fallback];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.themeRedoRemovesTheme);
    [settings undoThemeEdit];
    XCTAssertFalse(settings.themeRedoRemovesTheme);
    [settings redoThemeEdit];
    [settings redoThemeEdit];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, fallback);
    XCTAssertFalse(settings.currentTheme.showFileInfo);
    XCTAssertFalse([settings.orderedThemeIdentifiers containsObject:removed]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, order);
    XCTAssertEqualObjects(settings.activeThemeIdentifier, removed);
    XCTAssertFalse(settings.currentTheme.showTimeLabels);
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testRedoRetainsAddedImagesUntilHistoryBranchesOrClears {
    AppSettings *settings = self.editingSettings;
    NSString *reference = [AppTheme storeCustomImageData:SquarePNG(64) error:NULL];
    NSString *path = [_artDir stringByAppendingPathComponent:[reference substringFromIndex:7]];
    [settings.currentTheme setImageReference:reference forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings currentThemeDidChange]; // an unchanged write keeps redo
    XCTAssertTrue(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark], reference);
    [settings undoThemeEdit];
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    XCTAssertFalse(settings.canRedoThemeEdit);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    [settings applyThemeWithIdentifier:@"vibe"];
    XCTAssertFalse(settings.canRedoThemeEdit);
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    [settings factoryReset];
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testClearedThemeImageSurvivesUntilUndoHistoryIsDiscarded {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    NSString *reference = [settings.currentTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark], reference);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChangeContinuous:YES atTime:103];
    [settings applyThemeWithIdentifier:settings.activeThemeIdentifier];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testHistoryEvictionSweepsImagesEvenWhenOnlyDisplayFlagsChange {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    for (NSUInteger i = 0; i < 49; i++) {
        settings.currentTheme.showFileInfo = !settings.currentTheme.showFileInfo;
        [settings currentThemeDidChangeContinuous:YES atTime:103 + i * 3];
    }
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    settings.currentTheme.showFileInfo = !settings.currentTheme.showFileInfo;
    [settings currentThemeDidChangeContinuous:YES atTime:250];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testFactoryResetRetiresThemeUndoImagesAndAppearancePreview {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    settings.windowAppearancePreviewStyle = @"light";
    XCTAssertTrue(settings.canUndoThemeEdit);
    [settings factoryReset];
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertNil(settings.windowAppearancePreviewStyle);
    XCTAssertNil(settings.windowAppearance);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, @{});
}

- (void)testRenameEvictionSweepsImagesFromUndoHistory {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    for (NSUInteger i = 0; i < 50; i++) {
        XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
        [settings renameUserThemeWithIdentifier:settings.activeThemeIdentifier
                                        toName:[NSString stringWithFormat:@"Name %lu", i]];
    }
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testFactoryResetClearsTheUserThemesCache {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *identifier = [settings addUserThemeWithRecord:@{@"waveformTheme": @"orange"}
                                                       name:@"CacheProbe"];
    (void)[settings orderedThemeIdentifiers];          // populate the memo
    [settings factoryReset];
    XCTAssertFalse([[settings orderedThemeIdentifiers] containsObject:identifier],
            @"reset must not leave the deleted theme resurrectable");
}

- (void)testResetKeepsCustomThemesAndImagesUntilFactoryReset {
    AppSettings *settings = self.editingSettings;
    NSString *imagePath = [self installEditingImageInSettings:settings];
    NSString *identifier = settings.activeThemeIdentifier;
    NSDictionary *record = [settings recordForThemeIdentifier:identifier];
    NSString *name = [settings displayNameForThemeIdentifier:identifier];
    NSArray *identifiers = settings.orderedThemeIdentifiers;
    settings.waveformGainDB = 6;
    settings.windowAppearancePreviewStyle = @"light";

    [settings resetToDefaults];
    XCTAssertTrue(settings.allSettingsAtDefaults);
    XCTAssertEqual(settings.waveformGainDB, 0);
    XCTAssertEqualObjects(settings.activeThemeIdentifier, kVibeThemeIdentifierVibe);
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, @{});
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, identifiers);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:identifier], record);
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], name);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:imagePath]);
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertFalse(settings.canRedoThemeEdit);
    XCTAssertNil(settings.windowAppearancePreviewStyle);
    XCTAssertEqualObjects([[AppSettings new] recordForThemeIdentifier:identifier], record);

    [settings factoryReset];
    XCTAssertTrue(settings.allSettingsAtDefaults);
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, AppTheme.builtInThemeIdentifiers);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:imagePath]);
    XCTAssertFalse([[[AppSettings new] orderedThemeIdentifiers] containsObject:identifier]);
}

- (void)testDivergenceBlobAndDeletedActiveFallback {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    // A casual edit over a built-in diverges the working record, not the built-in.
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    XCTAssertFalse(settings.currentTheme.showFileInfo);
    XCTAssertEqualObjects([AppTheme builtInRecordForIdentifier:@"vibe"], @{});

    NSString *identifier = [settings addUserThemeWithRecord:@{} name:@"Doomed"];
    [settings applyThemeWithIdentifier:identifier];
    [settings removeUserThemeWithIdentifier:identifier fallingBackTo:nil];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    [settings factoryReset];
}

// Two picks of one menu are two undos. A restore lands in the stored entry,
// not only the working record.
- (void)testUndoKeepsDiscreteEditsApartAndFoldsAGesture {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    NSString *identifier = [settings addUserThemeWithRecord:@{} name:@"Undo"];
    [settings applyThemeWithIdentifier:identifier];
    XCTAssertFalse(settings.canUndoThemeEdit);

    settings.currentTheme.playButtonGlyph = @"play";
    [settings currentThemeDidChange];
    settings.currentTheme.playButtonGlyph = @"play.circle";
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.playButtonGlyph, @"play");
    XCTAssertEqualObjects([settings recordForThemeIdentifier:identifier][@"playButtonGlyph"], @"play");
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.playButtonGlyph, @"play.fill");
    XCTAssertFalse(settings.canUndoThemeEdit);

    for (NSNumber *radius in @[@8, @9, @10]) {
        settings.currentTheme.windowCornerRadius = radius.doubleValue;
        [settings currentThemeDidChangeContinuous:YES];
    }
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 10);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 16, @"one drag, one undo");
    XCTAssertFalse(settings.canUndoThemeEdit);

    settings.currentTheme.windowCornerRadius = 8;
    [settings currentThemeDidChangeContinuous:YES];
    settings.currentTheme.customCornerRadius = NO;
    [settings currentThemeDidChange];
    settings.currentTheme.waveformTheme = @"orange";
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertFalse(settings.currentTheme.customCornerRadius);
    XCTAssertEqual(settings.currentTheme.resolvedWindowCornerRadius, 16);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:identifier],
                          (@{@"windowCornerRadius": @8, @"customCornerRadius": @NO}));

    // A rename is its own entry, undone in order with the field edits.
    [settings renameUserThemeWithIdentifier:identifier toName:@"Renamed"];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Renamed");
    [settings renameUserThemeWithIdentifier:identifier toName:@"Renamed"];
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showFileInfo);
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Renamed",
                          @"the field edit undone, the rename still stands");
    [settings undoThemeEdit];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Undo",
                          @"a same-name rename pushed nothing");
    XCTAssertFalse(settings.currentTheme.customCornerRadius, @"the fields rode along untouched");
    [settings factoryReset];
}

// Written straight to the defaults key, as an external `defaults write` would,
// and read back by a fresh instance so no memoized list hides it.
- (void)testStoredUserThemesDropsJunkAndBuiltInSpoofs {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    NSString *real = [settings addUserThemeWithRecord:@{} name:@"Real"];
    NSString *key = @"Appearance.userThemes";
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:key];
    XCTAssertEqual(stored.count, 1u, @"the key the store writes is the one this test forges");
    NSMutableArray *forged = [stored mutableCopy];
    [forged addObjectsFromArray:@[
        @"not a dictionary",
        @42,
        @{kVibeThemeRecordNameKey: @"No id"},
        @{kVibeThemeRecordIdentifierKey: @"", kVibeThemeRecordNameKey: @"Empty id"},
        @{kVibeThemeRecordIdentifierKey: @7, kVibeThemeRecordNameKey: @"Numeric id"},
        @{kVibeThemeRecordIdentifierKey: @"user-nameless"},
        @{kVibeThemeRecordIdentifierKey: @"user-empty-name", kVibeThemeRecordNameKey: @""},
        @{kVibeThemeRecordIdentifierKey: kVibeThemeIdentifierVibe,
          kVibeThemeRecordNameKey: @"Spoofed Vibe"},
    ]];
    [NSUserDefaults.standardUserDefaults setObject:forged forKey:key];

    AppSettings *reloaded = [AppSettings new];
    NSArray *expected = [[AppTheme builtInThemeIdentifiers] arrayByAddingObject:real];
    XCTAssertEqualObjects([reloaded orderedThemeIdentifiers], expected);
    [settings factoryReset];
}



- (void)testGlyphSelectionClearsOnlyItsImagesAndPairsPlayPause {
    NSArray *buttons = @[kVibeThemeImagePlaylistButtonDark, kVibeThemeImageNextButtonDark, kVibeThemeImagePlayButtonDark];
    for (NSString *button in buttons) {
        AppTheme *theme = [[AppTheme alloc] initWithRecord:@{}];
        for (NSString *other in buttons) for (NSString *slot in [AppTheme imageKeysForButton:other]) {
            [theme setImageReference:@"bundled:cupertino_dark.jpg" forKey:slot];
        }
        NSString *glyph = [button isEqualToString:kVibeThemeImagePlayButtonDark] ? @"play.circle.fill" : @"star.fill";
        [theme setGlyph:glyph forButtonImageKey:button];
        for (NSString *other in buttons) for (NSString *slot in [AppTheme imageKeysForButton:other]) {
            XCTAssertEqual([theme imageReferenceForKey:slot].length > 0, ![other isEqual:button]);
        }
        if ([button isEqualToString:kVibeThemeImagePlayButtonDark]) {
            XCTAssertEqualObjects(theme.playButtonGlyph, glyph);
            XCTAssertEqualObjects(theme.pauseButtonGlyph, @"pause.circle.fill");
        } else if ([button isEqualToString:kVibeThemeImageNextButtonDark]) {
            XCTAssertEqualObjects(theme.nextButtonGlyph, glyph);
        } else {
            XCTAssertEqualObjects(theme.playlistButtonGlyph, glyph);
        }
    }
}

- (void)testGlyphSelectionIsOneUndoableEditIncludingItsRetiredImage {
    AppSettings *settings = self.editingSettings;
    NSString *reference = [AppTheme storeCustomImageData:SquarePNG(96) error:NULL];
    [settings.currentTheme setImageReference:reference forKey:kVibeThemeImagePauseButtonLight];
    [settings currentThemeDidChange];
    NSDictionary *before = settings.currentTheme.dictionaryRepresentation;
    [settings.currentTheme setGlyph:@"play.circle.fill" forButtonImageKey:kVibeThemeImagePlayButtonDark];
    [settings currentThemeDidChange];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImagePauseButtonLight], @"");
    XCTAssertFalse([AppTheme referenceIsMissing:reference]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, before);
}

- (void)testSupersededOrBuiltInImagePickerDoesNotEvenReadThePickedData {
    AppSettings *settings = self.editingSettings;
    NSString *original = settings.activeThemeIdentifier;
    NSString *other = [settings addUserThemeWithRecord:@{} name:@"Other"];
    [settings applyThemeWithIdentifier:other];
    __block NSUInteger reads = 0;
    NSData *(^data)(void) = ^{ reads++; return SquarePNG(96); };
    NSError *error = nil;
    XCTAssertFalse([settings setCurrentThemeImageForKey:kVibeThemeImageAppIcon themeIdentifier:original data:data error:&error]);
    XCTAssertNil(error);
    [settings applyThemeWithIdentifier:kVibeThemeIdentifierVibe];
    XCTAssertFalse([settings setCurrentThemeImageForKey:kVibeThemeImageAppIcon themeIdentifier:kVibeThemeIdentifierVibe data:data error:&error]);
    XCTAssertEqual(reads, 0u);
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertEqual(settings.currentTheme.dictionaryRepresentation.count, 0u);
}

- (void)testImagePickerInstallsOnlyItsSlotAndInvalidDataLeavesThemeUntouched {
    AppSettings *settings = self.editingSettings;
    NSString *identifier = settings.activeThemeIdentifier;
    NSError *error = nil;
    XCTAssertTrue([settings setCurrentThemeImageForKey:kVibeThemeImageNextButtonLight themeIdentifier:identifier
            data:^{ return SquarePNG(96); } error:&error]);
    [settings currentThemeDidChange];
    XCTAssertNil(error);
    XCTAssertTrue([[settings.currentTheme imageReferenceForKey:kVibeThemeImageNextButtonLight] hasPrefix:@"custom:"]);
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageNextButtonDark], @"");
    NSDictionary *before = settings.currentTheme.dictionaryRepresentation;
    XCTAssertFalse([settings setCurrentThemeImageForKey:kVibeThemeImageNextButtonLight themeIdentifier:identifier
            data:^{ return [@"not an image" dataUsingEncoding:NSUTF8StringEncoding]; } error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, before);
    [settings undoThemeEdit];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageNextButtonLight], @"");
}

- (void)testImageEditsRequestTheirOwnLiveEffects {
    XCTAssertEqual(VibeThemeImageEditEffect(kVibeThemeImageAppIcon), VibeSettingsLiveEffectAppIcon);
    for (NSString *key in @[kVibeThemeImageDefaultArtworkDark, kVibeThemeImageDefaultArtworkLight]) {
        XCTAssertEqual(VibeThemeImageEditEffect(key), VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance);
    }
    for (NSString *button in @[kVibeThemeImagePlayButtonDark, kVibeThemeImageNextButtonDark, kVibeThemeImagePlaylistButtonDark]) {
        for (NSString *key in [AppTheme imageKeysForButton:button]) {
            XCTAssertEqual(VibeThemeImageEditEffect(key), VibeSettingsLiveEffectTransportButtons);
        }
    }
}

@end
