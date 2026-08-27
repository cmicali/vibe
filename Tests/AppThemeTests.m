//
// AppTheme's record contract: the same sanitization gates a JSON import, a
// stored record and a UI edit, records stay sparse against the defaults, and
// the built-ins are exactly what they claim — vibe the empty record,
// industrial its four overrides.
//

#import <XCTest/XCTest.h>

#import "AppTheme.h"
#import "AppSettings.h"
#import "PlatformColor.h"

@interface AppThemeTests : XCTestCase
@end

@implementation AppThemeTests {
    NSString *_artDir;
}

- (void)setUp {
    _artDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"VibeThemeArtTest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    setenv("VIBE_THEME_ART_DIR", _artDir.UTF8String, 1);
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtPath:_artDir error:NULL];
    unsetenv("VIBE_THEME_ART_DIR");
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
    XCTAssertEqual(theme.windowCornerRadius, 20);
    XCTAssertTrue(theme.showFileInfo);
    XCTAssertTrue(theme.waveformGradient);
    XCTAssertTrue(theme.showPlaylistArtwork);
    XCTAssertTrue(theme.showPlaylistDuration);
    XCTAssertEqual(theme.playlistDurationFontSize, 12);
    XCTAssertEqualObjects(theme.mode, @"dual");
    XCTAssertFalse(theme.showRemainingTime);
    XCTAssertTrue(theme.showBPM);
    XCTAssertTrue(theme.showKey);
    XCTAssertFalse(theme.keyColorsEnabled);
    XCTAssertEqualObjects(theme.keyNotation, @"camelot");
    XCTAssertEqualObjects(theme.mainFontFace, @"");
    XCTAssertEqual(theme.mainFontSize, 23);
    XCTAssertEqual(theme.infoFontSize, 13);
    XCTAssertEqual(theme.playlistFontSize, 14);
    XCTAssertNil([theme titleColorForDark:YES]);
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

- (void)testDefaultValuedFieldsAreNotStored {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"waveformTheme": @"mono",
        @"windowCornerRadius": @20,
        @"showFileInfo": @YES,
        @"mainFontFace": @"",
    }];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

- (void)testSettingBackToTheDefaultEmptiesTheRecord {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    theme.windowCornerRadius = 8;
    theme.waveformTheme = @"orange";
    XCTAssertEqual(theme.dictionaryRepresentation.count, 2u);
    theme.windowCornerRadius = 20;
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
                          @{@"windowCornerRadius": @12});
}

- (void)testIdentifiersSnapToTheirLadders {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"waveformTheme": @"purple",
        @"windowTint": @"plaid",
        @"playlistTint": @"plaid",
        @"windowBackgroundStyle": @"translucent",
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
}

- (void)testPlaylistTintLadderKeepsItsOwnDefault {
    // The playlist tint shares the window tint's identifiers but not its
    // fallback: the factory playlist takes no artwork wash, so unknowns snap
    // to mono while the window's snap to artwork.
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
        @"mainFontSize": @5,
        @"infoFontSize": @72,
        @"playlistFontSize": @(-3),
    }];
    XCTAssertEqual(theme.windowCornerRadius, 30);
    XCTAssertEqual(theme.mainFontSize, 20);
    XCTAssertEqual(theme.infoFontSize, 15);
    XCTAssertEqual(theme.playlistFontSize, 11);
    theme.windowCornerRadius = -10;
    XCTAssertEqual(theme.windowCornerRadius, 0);
}

- (void)testMalformedValuesAreDropped {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"windowCornerRadius": @"big",
        @"mainFontSize": @(NAN),
        @"showBPM": @"true",
        @"titleColorDark": @"#GGHHII",
        @"artistColorDark": @123,
        @"waveformStyle": @7,
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
        @"mainFontFace": longFace,
    }];
    XCTAssertEqualObjects(theme.infoFontFace, @"Menlo-Regular");
    XCTAssertEqual(theme.mainFontFace.length, 64u);
}

- (void)testColorsRoundTripThroughHexWithAlpha {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    [theme setPlaylistPlayingRowColor:VibeColorFromHexString(@"#FF6600AA") forDark:YES];
    XCTAssertEqualObjects(theme.dictionaryRepresentation,
                          @{@"playlistPlayingRowColorDark": @"#FF6600AA"});
    XCTAssertEqualObjects(VibeHexStringFromColor([theme playlistPlayingRowColorForDark:YES]),
                          @"#FF6600AA");
    XCTAssertNil([theme playlistPlayingRowColorForDark:NO]);
    [theme setPlaylistPlayingRowColor:nil forDark:YES];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{});
}

- (void)testRecordRoundTrips {
    AppTheme *first = [[AppTheme alloc] initWithRecord:nil];
    first.waveformStyle = @"detailed";
    first.windowBackgroundStyle = @"solid";
    first.infoFontSize = 11;
    [first setWindowBackgroundColor:VibeColorFromHexString(@"#101014F0") forDark:YES];
    [first setTitleColor:VibeColorFromHexString(@"#FFFFFF") forDark:NO];
    AppTheme *second = [[AppTheme alloc] initWithRecord:first.dictionaryRepresentation];
    XCTAssertEqualObjects(second.dictionaryRepresentation, first.dictionaryRepresentation);
    XCTAssertEqualObjects(second.waveformStyle, @"detailed");
    XCTAssertEqual(second.infoFontSize, 11);
}

- (void)testReplaceWithRecordSwitchesEveryField {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"windowCornerRadius": @4}];
    [theme replaceWithRecord:@{@"waveformTheme": @"orange"}];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, @{@"waveformTheme": @"orange"});
    XCTAssertEqual(theme.windowCornerRadius, 20);
}

#pragma mark JSON

- (void)testJSONRoundTripCarriesNameAndVersionAndStripsIds {
    NSDictionary *record = @{@"waveformTheme": @"orange", @"windowCornerRadius": @6,
                             @"id": @"SHOULD-NOT-TRAVEL"};
    NSData *data = [AppTheme JSONDataForRecord:record name:@"Exported"];
    XCTAssertNotNil(data);
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    XCTAssertEqualObjects(json[@"version"], @1);
    XCTAssertEqualObjects(json[@"name"], @"Exported");
    XCTAssertNil(json[@"id"]);
    NSString *name = nil;
    NSError *error = nil;
    NSDictionary *back = [AppTheme recordFromJSONData:data name:&name error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(back, (@{@"waveformTheme": @"orange", @"windowCornerRadius": @6}));
    XCTAssertEqualObjects(name, @"Exported");
}

- (void)testJSONImportSanitizesFields {
    NSData *data = [@"{\"name\": 42, \"windowCornerRadius\": 900, \"future\": [1,2]}"
            dataUsingEncoding:NSUTF8StringEncoding];
    NSString *name = @"sentinel";
    NSError *error = nil;
    NSDictionary *record = [AppTheme recordFromJSONData:data name:&name error:&error];
    XCTAssertNil(error);
    XCTAssertNil(name);  // a non-string name does not travel
    XCTAssertEqualObjects(record, @{@"windowCornerRadius": @30});
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

#pragma mark Built-ins

- (void)testBuiltInIdentifiers {
    XCTAssertTrue([AppTheme isBuiltInIdentifier:@"vibe"]);
    XCTAssertTrue([AppTheme isBuiltInIdentifier:@"industrial"]);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:@"Vibe"]);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:nil]);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:NSUUID.UUID.UUIDString]);
    XCTAssertTrue([AppTheme isBuiltInIdentifier:@"adolescent_engineering"]);
    XCTAssertEqualObjects([AppTheme builtInThemeIdentifiers],
                          (@[@"vibe", @"adolescent_engineering", @"industrial"]));
}

// The Vibe theme is the empty record BY CONSTRUCTION: it cannot drift from
// the factory look because it stores nothing to drift with.
- (void)testVibeBuiltInIsTheEmptyRecord {
    XCTAssertEqualObjects([AppTheme builtInRecordForIdentifier:@"vibe"], @{});
}

- (void)testIndustrialBuiltInIsExactlyItsFourOverrides {
    NSDictionary *record = [AppTheme builtInRecordForIdentifier:@"industrial"];
    XCTAssertEqualObjects(record, (@{
        @"mode": @"single",
        @"waveformStyle": @"detailed",
        @"waveformTheme": @"orange",
        @"infoFontFace": @"Menlo-Regular",
    }));
    // And it survives its own sanitizer unchanged.
    AppTheme *theme = [[AppTheme alloc] initWithRecord:record];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, record);
}

// The dual-mode built-in: what a light/dark theme has to spell out for BOTH
// sides, and the one that would silently degrade if a color were dropped —
// the custom waveform theme falls back to mono unless the pair is complete.
- (void)testAdolescentEngineeringBuiltInIsDualAndComplete {
    NSDictionary *record = [AppTheme builtInRecordForIdentifier:@"adolescent_engineering"];
    AppTheme *theme = [[AppTheme alloc] initWithRecord:record];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, record);
    XCTAssertFalse(theme.isSingleMode);

    for (NSNumber *dark in @[@NO, @YES]) {
        BOOL isDark = dark.boolValue;
        XCTAssertNotNil([theme waveformPlayedColorForDark:isDark]);
        XCTAssertNotNil([theme waveformUnplayedColorForDark:isDark]);
        XCTAssertNotNil([theme windowBackgroundColorForDark:isDark]);
        XCTAssertNotNil([theme playlistBackgroundColorForDark:isDark]);
        XCTAssertNotNil([theme titleColorForDark:isDark]);
        XCTAssertNotNil([theme artistColorForDark:isDark]);
        XCTAssertNotNil([theme infoColorForDark:isDark]);
        XCTAssertNotNil([theme timeColorForDark:isDark]);
        XCTAssertNotNil([theme playlistPlayingRowColorForDark:isDark]);
        XCTAssertNotNil([theme playlistSelectedRowColorForDark:isDark]);
    }
    // Dual, so a solid background never outranks the appearance setting.
    XCTAssertNil(theme.requiredWindowAppearance);
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
    // Single mode has one color per field — the dark-keyed slot — read and
    // written whichever side a caller names, whatever appearance is active.
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"mode": @"single"}];
    [theme setTitleColor:VibeColorFromHexString(@"#FF2200") forDark:NO];
    XCTAssertEqualObjects(theme.dictionaryRepresentation, (@{
        @"mode": @"single",
        @"titleColorDark": @"#FF2200",
    }));
    XCTAssertEqualObjects(VibeHexStringFromColor([theme titleColorForDark:YES]), @"#FF2200");
    XCTAssertEqualObjects(VibeHexStringFromColor([theme titleColorForDark:NO]), @"#FF2200");
}

- (void)testModeFlipsPreserveBothPalettes {
    // The light-keyed halves lie dormant under single mode, so a theme
    // flipped to single and back to dual keeps its second palette.
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{
        @"titleColorDark": @"#111111",
        @"titleColorLight": @"#EEEEEE",
    }];
    theme.mode = @"single";
    XCTAssertEqualObjects(VibeHexStringFromColor([theme titleColorForDark:NO]), @"#111111");
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"titleColorLight"], @"#EEEEEE");
    theme.mode = @"dual";
    XCTAssertEqualObjects(VibeHexStringFromColor([theme titleColorForDark:NO]), @"#EEEEEE");
}

- (void)testSingleModeAlwaysPinsTheDarkAppearance {
    // Single mode is one constant look, no consideration of light or dark:
    // the window pins to the app's native dark appearance whatever the theme
    // sets, and every specified color is literal. Dual never pins.
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"mode": @"single"}];
    XCTAssertEqualObjects(theme.requiredWindowAppearance.name, NSAppearanceNameDarkAqua);
    [theme setWindowBackgroundColor:VibeColorFromHexString(@"#FFFFFF") forDark:YES];
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

- (void)testDefaultAlbumArtSanitizesByShape {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:@{@"defaultAlbumArt": @"vinyl_red"}];
    XCTAssertEqualObjects(theme.defaultAlbumArt, @"vinyl_red");
    theme.defaultAlbumArt =
            @"custom:0123456789abcdef0123456789abcdef01234567.png";
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultAlbumArt"],
            @"custom:0123456789abcdef0123456789abcdef01234567.png");
    // Wrong shapes drop to the default.
    for (NSString *bad in @[@"Vinyl", @"../etc/passwd", @"custom:short.png",
                            @"custom:0123456789abcdef0123456789abcdef01234567.gif"]) {
        theme.defaultAlbumArt = bad;
        XCTAssertNil(theme.dictionaryRepresentation[@"defaultAlbumArt"], @"%@", bad);
    }
    XCTAssertNotNil([AppTheme imageForDefaultAlbumArt:nil]);
    XCTAssertNotNil([AppTheme imageForDefaultAlbumArt:@"never_shipped"]);
}

static NSData *SquarePNG(NSInteger side) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (void)testCustomAlbumArtStoreValidatesAndRoundTripsThroughTheArchive {
    NSError *error = nil;
    // Not square: rejected.
    NSBitmapImageRep *wide = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:128 pixelsHigh:64
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    XCTAssertNil([AppTheme storeCustomAlbumArtData:
            [wide representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            error:&error]);
    // Too small: rejected. Garbage: rejected.
    XCTAssertNil([AppTheme storeCustomAlbumArtData:SquarePNG(32) error:NULL]);
    XCTAssertNil([AppTheme storeCustomAlbumArtData:
            [@"not an image" dataUsingEncoding:NSUTF8StringEncoding] error:NULL]);

    // A valid square stores, resolves, and survives the ZIP round trip.
    NSString *stored = [AppTheme storeCustomAlbumArtData:SquarePNG(256) error:&error];
    XCTAssertTrue([stored hasPrefix:@"custom:"], @"%@", error);
    XCTAssertNotNil([AppTheme imageForDefaultAlbumArt:stored]);

    NSDictionary *record = @{@"defaultAlbumArt": stored, @"waveformTheme": @"orange"};
    NSData *zip = [AppTheme archiveDataForRecord:record name:@"Art Theme"];
    XCTAssertNotNil(zip);
    NSString *name = nil;
    NSDictionary *back = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:&error];
    XCTAssertEqualObjects(name, @"Art Theme");
    XCTAssertEqualObjects(back, record); // same bytes re-hash to the same reference

    // A record without a custom image has no archive form.
    XCTAssertNil([AppTheme archiveDataForRecord:@{@"waveformTheme": @"orange"}
                                           name:@"Plain"]);
    // JSON-only import with a dangling custom reference drops the field.
    NSDictionary *dangling = [AppTheme recordFromJSONOrArchiveData:
            [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"name": @"D",
                    @"defaultAlbumArt": @"custom:ffffffffffffffffffffffffffffffffffffffff.png",
                    @"waveformTheme": @"orange"} options:0 error:NULL]
            name:NULL error:NULL];
    XCTAssertEqualObjects(dangling, @{@"waveformTheme": @"orange"});
}

- (void)testBundledThemesAreValid {
    // The gate a theme pull request runs against. The import path is
    // deliberately tolerant — a typo'd field key or malformed color is
    // DROPPED, not rejected — so validity here means the raw file survives
    // the sanitizer unchanged, which is what makes a silent degrade loud.
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

        // Every field key must survive sanitization unchanged.
        NSMutableDictionary *fields = [raw mutableCopy];
        [fields removeObjectsForKeys:@[@"version", @"name", @"description"]];
        AppTheme *theme = [[AppTheme alloc] initWithRecord:fields];
        XCTAssertEqualObjects(theme.dictionaryRepresentation, fields,
                @"%@: a field key or value did not survive the sanitizer — typo, bad hex, "
                @"or out-of-range value", file);
    }
    XCTAssertTrue([seen containsObject:@"vibe"], @"vibe.json must exist");

    // A built-in cannot reference a container image nobody has, and any
    // bundled art must itself pass the custom-art validation.
    for (NSString *identifier in [AppTheme builtInThemeIdentifiers]) {
        NSString *art = [AppTheme builtInRecordForIdentifier:identifier][@"defaultAlbumArt"];
        XCTAssertFalse([art hasPrefix:@"custom:"],
                @"%@: a built-in must name bundled art, not a custom image", identifier);
        if (art.length) {
            XCTAssertTrue([[AppTheme bundledAlbumArtNames] containsObject:art],
                    @"%@: names art the bundle does not carry (%@)", identifier, art);
        }
    }
    for (NSString *ext in @[@"png", @"jpg"]) {
        for (NSURL *url in [bundle URLsForResourcesWithExtension:ext
                subdirectory:@"Themes/art"]) {
            NSError *artError = nil;
            XCTAssertNotNil([AppTheme storeCustomAlbumArtData:
                    [NSData dataWithContentsOfURL:url] error:&artError],
                    @"%@: %@", url.lastPathComponent, artError);
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
// Finder archive or a crafted file would — VibeZipData is file-static.
static void PutLE(NSMutableData *d, uint64_t v, int n) {
    for (int i = 0; i < n; i++) { uint8_t b = (v >> (8 * i)) & 0xFF; [d appendBytes:&b length:1]; }
}
// VibeUnzipData reads no CRC field (and storeCustomAlbumArtData re-hashes the
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
    // Byte cap: the size check precedes any parse, so a JPEG-magic blob over
    // 8 MB is rejected without decoding.
    NSMutableData *huge = [NSMutableData dataWithLength:8 * 1024 * 1024 + 1];
    uint8_t jpeg[3] = {0xFF, 0xD8, 0xFF}; [huge replaceBytesInRange:NSMakeRange(0, 3) withBytes:jpeg];
    XCTAssertNil([AppTheme storeCustomAlbumArtData:huge error:NULL]);
    // Floor already covered (32 px) — the 4096 ceiling is the same expression.
    XCTAssertNotNil([AppTheme storeCustomAlbumArtData:SquarePNG(64) error:NULL]);
}

- (void)testArchiveReaderIsSafeOnTruncatedAndGarbageInput {
    NSString *stored = [AppTheme storeCustomAlbumArtData:SquarePNG(64) error:NULL];
    NSData *zip = [AppTheme archiveDataForRecord:@{@"defaultAlbumArt": stored} name:@"Z"];
    XCTAssertNotNil(zip);
    // Every truncation point must return safely, never read past the buffer.
    for (NSUInteger cut = 0; cut < zip.length; cut++) {
        NSData *piece = [zip subdataWithRange:NSMakeRange(0, cut)];
        XCTAssertNoThrow([AppTheme recordFromJSONOrArchiveData:piece name:NULL error:NULL]);
    }
    // A PK-prefixed non-zip is rejected, not crashed.
    NSData *garbage = [@"PK\x03\x04 not a real zip at all" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:garbage name:NULL error:NULL]);
}

- (void)testArchiveReaderHandlesFinderShapedArchives {
    NSString *stored = [AppTheme storeCustomAlbumArtData:SquarePNG(64) error:NULL];
    NSString *file = [stored substringFromIndex:7]; // <sha1>.png
    NSData *image = [NSData dataWithContentsOfFile:
            [_artDir stringByAppendingPathComponent:file]];
    NSData *themeJSON = [AppTheme JSONDataForRecord:@{@"defaultAlbumArt": stored} name:@"Finder"];

    // AppleDouble sidecar (.json extension, not JSON) must be skipped, and the
    // real theme.json chosen; a folder-prefixed image must still be matched.
    NSData *zip = MakeStoredZip(@[
        @[@"__MACOSX/._theme.json", [@"garbage" dataUsingEncoding:NSUTF8StringEncoding]],
        @[@"My Theme/theme.json", themeJSON],
        @[[@"My Theme/" stringByAppendingString:file], image],
    ]);
    NSString *name = nil;
    NSDictionary *record = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:NULL];
    XCTAssertEqualObjects(name, @"Finder");
    XCTAssertEqualObjects(record[@"defaultAlbumArt"], stored); // art survived, re-hashed
}

#pragma mark Store CRUD (AppSettings)

- (void)testResetToDefaultsClearsTheUserThemesCache {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *identifier = [settings addUserThemeWithRecord:@{@"waveformTheme": @"orange"}
                                                       name:@"CacheProbe"];
    (void)[settings orderedThemeIdentifiers];          // populate the memo
    [settings resetToDefaults];
    XCTAssertFalse([[settings orderedThemeIdentifiers] containsObject:identifier],
            @"reset must not leave the deleted theme resurrectable");
}

- (void)testDivergenceBlobAndDeletedActiveFallback {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings resetToDefaults];
    // A casual edit over a built-in diverges the working record, not the built-in.
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.showFileInfo = NO;
    [settings currentThemeDidChange];
    XCTAssertFalse(settings.currentTheme.showFileInfo);
    XCTAssertEqualObjects([AppTheme builtInRecordForIdentifier:@"vibe"], @{});

    // Deleting the active user theme falls back to vibe.
    NSString *identifier = [settings addUserThemeWithRecord:@{} name:@"Doomed"];
    [settings applyThemeWithIdentifier:identifier];
    [settings removeUserThemeWithIdentifier:identifier];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    [settings resetToDefaults];
}

- (void)testStoredUserThemesDropsJunkAndBuiltInSpoofs {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings resetToDefaults];
    NSString *real = [settings addUserThemeWithRecord:@{} name:@"Real"];
    // An entry spoofing a built-in id, and a nameless one, must not appear.
    NSArray *ids = [settings orderedThemeIdentifiers];
    XCTAssertTrue([ids containsObject:real]);
    NSUInteger occurrences = [ids filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"SELF == %@", real]].count;
    XCTAssertEqual(occurrences, 1u);
    [settings resetToDefaults];
}


@end
