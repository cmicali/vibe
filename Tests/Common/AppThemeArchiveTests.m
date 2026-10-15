//
// AppTheme's artwork and its archive: default and custom images, the
// archive's slot names, the bundled themes, and the ZIP reader's caps and
// safety on malformed input.
//

#import "AppThemeTestCase.h"

@interface AppThemeArchiveTests : AppThemeTestCase
@end

@implementation AppThemeArchiveTests

#pragma mark Artwork and the archive

- (void)testDefaultArtworkSanitizesByShape {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:
            @{@"defaultArtworkDark": @"bundled:field_dark.png"}];
    XCTAssertEqualObjects([theme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark],
            @"bundled:field_dark.png");
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
    [theme setImageReference:@"bundled:field_light.png" forKey:kVibeThemeImageDefaultArtworkLight];
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtworkDark"],
            @"bundled:field_light.png");
    XCTAssertEqualObjects([theme imageReferenceForKey:kVibeThemeImageDefaultArtworkLight],
            @"bundled:field_light.png");
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtworkLight"],
            @"custom:0123456789abcdef0123456789abcdef01234567.png");
}

// Now Playing rasterizes outside any view, where the drawing appearance is
// the system's, so it asks for the side its window shows. Each side is one
// cached image: the identity is what its dirty check compares.
- (void)testDefaultArtworkSideFollowsTheAppearanceItIsAskedFor {
    NSString *dark = [AppTheme storeCustomImageData:VibeSquarePNG(96) error:NULL];
    NSString *light = [AppTheme storeCustomImageData:VibeSquarePNG(64) error:NULL];
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

// Clear and window share one transparent square, so a mode switch between
// them reinstalls nothing. Custom is its color pair as a square, a new
// image per color. Neither is artwork, so Now Playing gets none.
- (void)testDefaultArtworkModesResolveToOneSquareEach {
    AppTheme *theme = [[AppTheme alloc] initWithRecord:nil];
    NSImage *factory = theme.resolvedDefaultArtworkImage;
    NSAppearance *aqua = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    XCTAssertNotNil([theme defaultArtworkImageForAppearance:aqua]);
    theme.defaultArtwork = @"clear";
    NSImage *clear = theme.resolvedDefaultArtworkImage;
    XCTAssertNotEqual(clear, factory);
    XCTAssertNil([theme defaultArtworkImageForAppearance:aqua]);
    theme.defaultArtwork = @"window";
    XCTAssertEqual(theme.resolvedDefaultArtworkImage, clear);
    XCTAssertNil([theme defaultArtworkImageForAppearance:aqua]);
    theme.defaultArtwork = @"custom";
    NSImage *neutral = theme.resolvedDefaultArtworkImage;
    XCTAssertNotEqual(neutral, clear);
    XCTAssertNil([theme defaultArtworkImageForAppearance:aqua]);
    [theme setColor:VibeColorFromHexString(@"#FF0000") forBase:kVibeThemeColorDefaultArtwork dark:YES];
    NSImage *red = theme.resolvedDefaultArtworkImage;
    XCTAssertNotEqual(red, neutral);
    XCTAssertEqual(theme.resolvedDefaultArtworkImage, red, @"the same colors are the same image");
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtwork"], @"custom");
    XCTAssertEqualObjects(theme.dictionaryRepresentation[@"defaultArtworkColorDark"], @"#FF0000");
    theme.defaultArtwork = @"glyph";
    NSImage *note = theme.resolvedDefaultArtworkImage;
    XCTAssertNotEqual(note, clear);
    XCTAssertNotEqual(note, red);
    XCTAssertNil([theme defaultArtworkImageForAppearance:aqua]);
    XCTAssertEqual(theme.resolvedDefaultArtworkImage, note);
    theme.defaultArtworkGlyphSize = 0.3;
    XCTAssertNotEqual(theme.resolvedDefaultArtworkImage, note, @"a size is a new image");
    theme.defaultArtworkGlyphSize = 5;
    XCTAssertEqual(theme.defaultArtworkGlyphSize, kVibeThemeDefaultArtworkGlyphSizeMax);
    theme.defaultArtworkGlyph = @"Not A Symbol!";
    XCTAssertEqualObjects(theme.defaultArtworkGlyph, kVibeThemeDefaultArtworkGlyphDefault, @"shape only");
    theme.defaultArtworkGlyph = @"no.such.symbol.anywhere";
    XCTAssertEqualObjects(theme.defaultArtworkGlyph, @"no.such.symbol.anywhere", @"the record keeps the name");
    XCTAssertEqualObjects(theme.resolvedDefaultArtworkGlyph, kVibeThemeDefaultArtworkGlyphDefault);
    XCTAssertNotNil(theme.resolvedDefaultArtworkImage, @"an unknown name draws the factory glyph");
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
    XCTAssertNil([AppTheme storeCustomImageData:VibeSquarePNG(32) error:NULL]);
    XCTAssertNil([AppTheme storeCustomImageData:
            [@"not an image" dataUsingEncoding:NSUTF8StringEncoding] error:NULL]);

    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(256) error:&error];
    XCTAssertTrue([stored hasPrefix:@"custom:"], @"%@", error);
    XCTAssertNotNil([AppTheme imageForReference:stored]);

    NSDictionary *record = @{@"defaultArtworkDark": stored, @"waveformTheme": @"orange"};
    NSData *zip = [AppTheme archiveDataForRecord:record name:@"Art Theme"];
    XCTAssertNotNil(zip);
    // Check date packing without tying the assertion to the current day.
    const uint8_t *raw = zip.bytes;
    NSUInteger dosDate = raw[12] | (raw[13] << 8);
    XCTAssertGreaterThanOrEqual(1980 + (dosDate >> 9), 2020u, @"year");
    XCTAssertTrue((dosDate >> 5 & 0xF) >= 1 && (dosDate >> 5 & 0xF) <= 12, @"month");
    XCTAssertTrue((dosDate & 0x1F) >= 1 && (dosDate & 0x1F) <= 31, @"day");
    NSString *name = nil;
    NSDictionary *back = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:&error];
    XCTAssertEqualObjects(name, @"Art Theme");
    XCTAssertEqualObjects(back, record); // same bytes re-hash to the same reference

    NSString *light = [AppTheme storeCustomImageData:VibeSquarePNG(128) error:&error];
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
    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(96) error:NULL];
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
    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(96) error:NULL];
    NSData *zip = [AppTheme archiveDataForRecord:
            @{@"defaultArtworkDark": stored, @"waveformTheme": @"orange"} name:@"Art"];

    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:
            ZipWithBytesReplaced(zip, @"theme.json", @"theme.jsom") name:NULL error:NULL],
            @"an archive with no theme JSON must be refused");

    XCTAssertNil([AppTheme recordFromJSONOrArchiveData:
            ZipWithBytesReplaced(zip, @"\"version\" : 2", @"\"version\" : X")
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
    NSDictionary *record = [AppTheme builtInRecordForIdentifier:@"field"];
    XCTAssertEqualObjects(record[@"defaultArtworkDark"],
            @"bundled:field_dark.png", @"the fixture this test rests on");

    NSData *zip = [AppTheme archiveDataForRecord:record name:@"Field"];
    XCTAssertNotNil(zip, @"a built-in with bundled art must export as an archive");
    XCTAssertGreaterThan(zip.length, 50000u, @"the images themselves, not just their names");

    // Entries are named by slot, not by hash or this build's filename, and keep
    // the source image's extension.
    NSString *bytes = [[NSString alloc] initWithData:zip encoding:NSISOLatin1StringEncoding];
    XCTAssertTrue([bytes containsString:@"artwork_default_front.png"]);
    XCTAssertTrue([bytes containsString:@"artwork_default_back.png"]);
    XCTAssertFalse([bytes containsString:@"bundled:"], @"no prefix survives into the archive");
    XCTAssertFalse([bytes containsString:@"field_dark.png"],
            @"nor the name this build happens to keep the image under");

    // Re-import lands both sides in the container under their content hashes,
    // independent of this build shipping the image.
    NSString *name = nil;
    NSDictionary *back = [AppTheme recordFromJSONOrArchiveData:zip name:&name error:NULL];
    XCTAssertEqualObjects(name, @"Field");
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
    NSString *icon = [AppTheme storeCustomImageData:VibeSquarePNG(128) error:NULL];
    NSString *play = [AppTheme storeCustomImageData:VibeSquarePNG(96) error:NULL];
    NSString *pause = [AppTheme storeCustomImageData:VibeSquarePNG(80) error:NULL];
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
    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(256) error:NULL];
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

    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(96) error:NULL];
    XCTAssertFalse([AppTheme referenceIsMissing:stored]);
    [NSFileManager.defaultManager removeItemAtPath:
            [@(getenv("VIBE_THEME_ART_DIR")) stringByAppendingPathComponent:
                    [stored substringFromIndex:7]] error:NULL];
    XCTAssertTrue([AppTheme referenceIsMissing:stored]);
    XCTAssertNotNil([AppTheme imageForReference:stored]);

    XCTAssertFalse([AppTheme referenceIsMissing:@"bundled:field_dark.png"]);
    XCTAssertTrue([AppTheme referenceIsMissing:@"bundled:not_in_any_build.png"]);
}

// The suite-wide redirect (TestFilesystemGuard.m) must be in force before
// setUp narrows it, and nothing may land where production writes.
- (void)testStoredArtworkStaysInTempAndNeverTouchesTheRealLibrary {
    XCTAssertTrue([_suiteArtDir hasPrefix:NSTemporaryDirectory()],
            @"the load-time guard must redirect the whole suite into the temp directory, got '%@'", _suiteArtDir);
    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(96) error:NULL];
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
        XCTAssertEqualObjects(raw[@"version"], @2, @"%@: version must be 2", file);
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
    XCTAssertNotNil([AppTheme storeCustomImageData:VibeSquarePNG(64) error:NULL]);
}

- (void)testArchiveReaderIsSafeOnTruncatedAndGarbageInput {
    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(64) error:NULL];
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
    NSString *stored = [AppTheme storeCustomImageData:VibeSquarePNG(64) error:NULL];
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
    NSData *dark = VibeSquarePNG(64), *light = VibeSquarePNG(128);
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
        @[@"missing.png", VibeSquarePNG(32)],
    ]) name:NULL error:&error];
    XCTAssertNil(badImage[@"defaultArtworkDark"]);
    XCTAssertEqualObjects(badImage[@"waveformTheme"], @"orange");
    XCTAssertNil(error, @"a dropped image is not an import failure");
}

@end
