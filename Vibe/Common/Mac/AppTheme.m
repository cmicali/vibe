//
//  AppTheme.m
//  Vibe
//

#import "AppTheme.h"
#import <AppKit/AppKit.h>
#import <compression.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import "PlatformImage.h"
#import "AppSettings.h"
#import "SettingsRules.h"
#import "PlatformColor.h"

NSString *const kVibeThemeIdentifierVibe = @"vibe";

static const CGFloat kCornerRadiusMin = 0;

NSString *const kVibeThemeRecordNameKey = @"name";
NSString *const kVibeThemeRecordVersionKey = @"version";
NSString *const kVibeThemeRecordIdentifierKey = @"id";

// The record field keys ARE the accessor names, which is what makes a record
// self-describing in a theme JSON. Never renamed: they are persisted.
static NSString *const kFieldWaveformStyle = @"waveformStyle";
static NSString *const kFieldMode = @"mode";
static NSString *const kFieldWaveformTheme = @"waveformTheme";
static NSString *const kFieldWaveformGradient = @"waveformGradient";
static NSString *const kFieldWindowTint = @"windowTint";
static NSString *const kFieldPlaylistTint = @"playlistTint";
static NSString *const kFieldWindowBackgroundStyle = @"windowBackgroundStyle";
static NSString *const kFieldPlaylistBackgroundStyle = @"playlistBackgroundStyle";
static NSString *const kFieldWindowCornerRadius = @"windowCornerRadius";
static NSString *const kFieldShowFileInfo = @"showFileInfo";
static NSString *const kFieldShowRemainingTime = @"showRemainingTime";
static NSString *const kFieldShowBPM = @"showBPM";
static NSString *const kFieldShowKey = @"showKey";
static NSString *const kFieldKeyColorsEnabled = @"keyColorsEnabled";
static NSString *const kFieldKeyNotation = @"keyNotation";
static NSString *const kFieldMainFontFace = @"mainFontFace";
static NSString *const kFieldMainFontSize = @"mainFontSize";
static NSString *const kFieldInfoFontFace = @"infoFontFace";
static NSString *const kFieldInfoFontSize = @"infoFontSize";
static NSString *const kFieldPlaylistFontFace = @"playlistFontFace";
static NSString *const kFieldPlaylistFontSize = @"playlistFontSize";
static NSString *const kFieldPlaylistDurationFontFace = @"playlistDurationFontFace";
static NSString *const kFieldPlaylistDurationFontSize = @"playlistDurationFontSize";
static NSString *const kFieldDefaultAlbumArt = @"defaultAlbumArt";

static BOOL VibeIsValidDefaultAlbumArtValue(NSString *_Nullable value);
static NSString *const kFieldShowPlaylistArtwork = @"showPlaylistArtwork";
static NSString *const kFieldShowPlaylistDuration = @"showPlaylistDuration";

// The color pairs' base names; Dark/Light is appended per appearance.
static NSString *const kColorWaveformPlayed = @"waveformPlayedColor";
static NSString *const kColorWaveformUnplayed = @"waveformUnplayedColor";
static NSString *const kColorWindowTint = @"windowTintColor";
static NSString *const kColorPlaylistTint = @"playlistTintColor";
static NSString *const kColorWindowBackground = @"windowBackgroundColor";
static NSString *const kColorTitle = @"titleColor";
static NSString *const kColorArtist = @"artistColor";
static NSString *const kColorInfo = @"infoColor";
static NSString *const kColorTime = @"timeColor";
static NSString *const kColorPlaylistBackground = @"playlistBackgroundColor";
static NSString *const kColorPlaylistPlayingRow = @"playlistPlayingRowColor";
static NSString *const kColorPlaylistSelectedRow = @"playlistSelectedRowColor";

static NSString *ColorFieldKey(NSString *base, BOOL isDark) {
    return [base stringByAppendingString:isDark ? @"Dark" : @"Light"];
}

static NSArray<NSString *> *ColorFieldBases(void) {
    return @[kColorWaveformPlayed, kColorWaveformUnplayed, kColorWindowTint,
             kColorPlaylistTint, kColorWindowBackground, kColorTitle, kColorArtist,
             kColorInfo, kColorTime, kColorPlaylistBackground, kColorPlaylistPlayingRow,
             kColorPlaylistSelectedRow];
}

static NSSet<NSString *> *ColorFieldKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *set = [NSMutableSet set];
        for (NSString *base in ColorFieldBases()) {
            [set addObject:ColorFieldKey(base, YES)];
            [set addObject:ColorFieldKey(base, NO)];
        }
        keys = set;
    });
    return keys;
}

static NSSet<NSString *> *BoolFieldKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[kFieldShowFileInfo, kFieldShowRemainingTime,
                                     kFieldShowBPM, kFieldShowKey, kFieldKeyColorsEnabled,
                                     kFieldShowPlaylistArtwork, kFieldShowPlaylistDuration,
                                     kFieldWaveformGradient]];
    });
    return keys;
}

static NSSet<NSString *> *FaceFieldKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[kFieldMainFontFace, kFieldInfoFontFace,
                                     kFieldPlaylistFontFace,
                                     kFieldPlaylistDurationFontFace]];
    });
    return keys;
}

// A font slot's clamp is narrow on purpose: the labels sit in fixed frames,
// and call sites derive their own size as an offset from the slot's base.
static BOOL FontSizeClamp(NSString *key, CGFloat *min, CGFloat *max) {
    if ([key isEqualToString:kFieldMainFontSize])     { *min = 20; *max = 26; return YES; }
    if ([key isEqualToString:kFieldInfoFontSize])     { *min = 10; *max = 15; return YES; }
    if ([key isEqualToString:kFieldPlaylistFontSize]) { *min = 11; *max = 16; return YES; }
    if ([key isEqualToString:kFieldPlaylistDurationFontSize]) { *min = 10; *max = 14; return YES; }
    return NO;
}

// The defaults are today's hardcoded look, which is what keeps the empty
// record — the built-in Vibe theme — pixel-identical to the app before
// themes existed. Color pairs default by absence.
static NSDictionary<NSString *, id> *FieldDefaults(void) {
    static NSDictionary<NSString *, id> *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = @{
            kFieldMode:                  SETTINGS_VALUE_THEME_MODE_DUAL,
            kFieldWaveformStyle:         SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT,
            kFieldWaveformTheme:         SETTINGS_VALUE_WAVEFORM_THEME_MONO,
            kFieldWaveformGradient:      @(YES),
            kFieldWindowTint:            SETTINGS_VALUE_WINDOW_TINT_ARTWORK,
            kFieldPlaylistTint:          SETTINGS_VALUE_WINDOW_TINT_MONO,
            kFieldWindowBackgroundStyle: SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS,
            kFieldPlaylistBackgroundStyle: SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS,
            kFieldWindowCornerRadius:    @(kVibeThemeCornerRadiusDefault),
            kFieldShowFileInfo:          @(YES),
            kFieldShowRemainingTime:     @(NO),
            kFieldShowBPM:               @(YES),
            kFieldShowKey:               @(YES),
            kFieldKeyColorsEnabled:      @(NO),
            kFieldKeyNotation:           SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
            kFieldMainFontFace:          @"",
            kFieldMainFontSize:          @(kVibeThemeMainFontBaseSize),
            kFieldInfoFontFace:          @"",
            kFieldInfoFontSize:          @(kVibeThemeInfoFontBaseSize),
            kFieldPlaylistFontFace:      @"",
            kFieldPlaylistFontSize:      @(kVibeThemePlaylistFontBaseSize),
            kFieldPlaylistDurationFontFace: @"",
            kFieldPlaylistDurationFontSize: @(kVibeThemePlaylistDurationFontBaseSize),
            kFieldDefaultAlbumArt:       @"",
            kFieldShowPlaylistArtwork:   @(YES),
            kFieldShowPlaylistDuration:  @(YES),
        };
    });
    return defaults;
}

static NSString *VibeNormalizedThemeMode(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_THEME_MODE_SINGLE]
            ? SETTINGS_VALUE_THEME_MODE_SINGLE
            : SETTINGS_VALUE_THEME_MODE_DUAL;
}

static NSString *VibeNormalizedWindowBackgroundStyle(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID]
            ? SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID
            : SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS;
}

// The window tint's ladder with the playlist's own default: the factory
// playlist takes no artwork wash, so unknowns snap to mono rather than the
// window's artwork.
static NSString *VibeNormalizedPlaylistTint(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_ARTWORK] ||
        [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        return identifier;
    }
    return SETTINGS_VALUE_WINDOW_TINT_MONO;
}

static NSString *VibeNormalizedKeyNotation(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]
            ? SETTINGS_VALUE_KEY_NOTATION_MUSICAL
            : SETTINGS_VALUE_KEY_NOTATION_CAMELOT;
}

static NSString *_Nullable TrimmedCappedString(id _Nullable raw) {
    if (![raw isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)raw stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 64 ? [trimmed substringToIndex:64] : trimmed;
}

// The one gate. A raw record value comes out normalized, clamped and typed,
// or nil — dropped, so the default takes over. Bools are numbers only, never
// strings; numbers must be finite; colors must round-trip as hex.
static id _Nullable SanitizedFieldValue(NSString *key, id _Nullable raw) {
    if ([ColorFieldKeys() containsObject:key]) {
        if (![raw isKindOfClass:NSString.class]) {
            return nil;
        }
        return VibeHexStringFromColor(VibeColorFromHexString(raw));
    }
    if ([BoolFieldKeys() containsObject:key]) {
        return [raw isKindOfClass:NSNumber.class] ? @([raw boolValue]) : nil;
    }
    if ([key isEqualToString:kFieldWindowCornerRadius]) {
        if (![raw isKindOfClass:NSNumber.class] || !isfinite([raw doubleValue])) {
            return nil;
        }
        return @(MIN(MAX([raw doubleValue], kCornerRadiusMin), kVibeThemeCornerRadiusMax));
    }
    CGFloat sizeMin, sizeMax;
    if (FontSizeClamp(key, &sizeMin, &sizeMax)) {
        if (![raw isKindOfClass:NSNumber.class] || !isfinite([raw doubleValue])) {
            return nil;
        }
        return @(MIN(MAX([raw doubleValue], sizeMin), sizeMax));
    }
    if ([FaceFieldKeys() containsObject:key] || [key isEqualToString:kFieldWaveformStyle]) {
        return TrimmedCappedString(raw);
    }
    if (![raw isKindOfClass:NSString.class]) {
        return nil;
    }
    if ([key isEqualToString:kFieldMode]) {
        return VibeNormalizedThemeMode(raw);
    }
    if ([key isEqualToString:kFieldWaveformTheme]) {
        return VibeNormalizedWaveformTheme(raw);
    }
    if ([key isEqualToString:kFieldWindowTint]) {
        return VibeNormalizedWindowTint(raw);
    }
    if ([key isEqualToString:kFieldPlaylistTint]) {
        return VibeNormalizedPlaylistTint(raw);
    }
    if ([key isEqualToString:kFieldWindowBackgroundStyle] ||
        [key isEqualToString:kFieldPlaylistBackgroundStyle]) {
        return VibeNormalizedWindowBackgroundStyle(raw);
    }
    if ([key isEqualToString:kFieldKeyNotation]) {
        return VibeNormalizedKeyNotation(raw);
    }
    if ([key isEqualToString:kFieldDefaultAlbumArt]) {
        NSString *value = TrimmedCappedString(raw);
        return VibeIsValidDefaultAlbumArtValue(value) ? value : nil;
    }
    return nil;
}

static NSArray<NSString *> *KnownFieldKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *all = [FieldDefaults().allKeys mutableCopy];
        [all addObjectsFromArray:ColorFieldKeys().allObjects];
        keys = all;
    });
    return keys;
}

@implementation AppTheme {
    // Only sanitized values differing from the defaults — the sparse record.
    NSMutableDictionary<NSString *, id> *_fields;
    // Parsed colors keyed by their hex VALUE, so the cache can never go
    // stale and needs no invalidation hook — an edited field is a new hex.
    // Rows read their fills per draw; without this every draw re-parses.
    NSMutableDictionary<NSString *, VibeColor *> *_parsedColors;
}

+ (VibeColor *)dynamicColorWithDark:(VibeColor *)dark
                              light:(VibeColor *)light
                           fallback:(VibeColor *)fallback {
    if (!dark && !light) {
        return fallback;
    }
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSAppearanceName matched = [appearance bestMatchFromAppearancesWithNames:@[
            NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
        ]];
        BOOL isDark = [matched isEqualToString:NSAppearanceNameDarkAqua];
        return (isDark ? dark : light) ?: fallback;
    }];
}

- (VibeColor *)resolvedTitleColor {
    return [AppTheme dynamicColorWithDark:[self titleColorForDark:YES]
                                    light:[self titleColorForDark:NO]
                                 fallback:NSColor.labelColor];
}

- (VibeColor *)resolvedArtistColor {
    return [AppTheme dynamicColorWithDark:[self artistColorForDark:YES]
                                    light:[self artistColorForDark:NO]
                                 fallback:NSColor.secondaryLabelColor];
}

- (VibeColor *)resolvedInfoColor {
    return [AppTheme dynamicColorWithDark:[self infoColorForDark:YES]
                                    light:[self infoColorForDark:NO]
                                 fallback:NSColor.tertiaryLabelColor];
}

- (VibeColor *)resolvedTimeColor {
    return [AppTheme dynamicColorWithDark:[self timeColorForDark:YES]
                                    light:[self timeColorForDark:NO]
                                 fallback:NSColor.secondaryLabelColor];
}

#pragma mark Built-ins

// The built-ins ship as Resources/Themes/<identifier>.json — the filename
// stem is the stable identifier, the name key the English display name, and
// the fields go through the same recordFromJSONData: gate as an import, so a
// bundled theme is held to the import's clamps. Adding a built-in is adding
// a file; testBundledThemesAreValid is the gate a theme PR runs against.
// Order: vibe pinned first, the rest alphabetical by identifier.
static NSArray<NSString *> *builtInOrder;
static NSDictionary<NSString *, NSDictionary *> *builtInRecords;
static NSDictionary<NSString *, NSString *> *builtInNames;

static void VibeLoadBuiltInThemes(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *order = [NSMutableArray array];
        NSMutableDictionary *records = [NSMutableDictionary dictionary];
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        NSBundle *bundle = [NSBundle bundleForClass:AppTheme.class];
        NSArray<NSURL *> *urls = [bundle URLsForResourcesWithExtension:@"json"
                                                          subdirectory:@"Themes"];
        for (NSURL *url in [urls sortedArrayUsingComparator:^(NSURL *a, NSURL *b) {
            return [a.lastPathComponent compare:b.lastPathComponent];
        }]) {
            NSString *identifier = url.lastPathComponent.stringByDeletingPathExtension;
            NSString *name = nil;
            NSError *error = nil;
            NSDictionary *record = [AppTheme
                    recordFromJSONData:[NSData dataWithContentsOfURL:url]
                                  name:&name
                                 error:&error];
            if (!record || name.length == 0 || identifier.length == 0) {
                LogError(@"Bundled theme %@ is unreadable: %@",
                        url.lastPathComponent, error);
                continue;
            }
            [order addObject:identifier];
            records[identifier] = record;
            names[identifier] = name;
        }
        // vibe is the store's snap-back anchor (unknown ids, deleted-active
        // themes) and must never dangle, whatever happened to the bundle.
        if (records[kVibeThemeIdentifierVibe]) {
            [order removeObject:kVibeThemeIdentifierVibe];
        } else {
            records[kVibeThemeIdentifierVibe] = @{};
            names[kVibeThemeIdentifierVibe] = @"Vibe";
        }
        [order insertObject:kVibeThemeIdentifierVibe atIndex:0];
        builtInOrder = [order copy];
        builtInRecords = [records copy];
        builtInNames = [names copy];
    });
}

+ (NSArray<NSString *> *)builtInThemeIdentifiers {
    VibeLoadBuiltInThemes();
    return builtInOrder;
}

+ (BOOL)isBuiltInIdentifier:(NSString *)identifier {
    return identifier && [[self builtInThemeIdentifiers] containsObject:identifier];
}

+ (NSDictionary<NSString *, id> *)builtInRecordForIdentifier:(NSString *)identifier {
    VibeLoadBuiltInThemes();
    return builtInRecords[identifier] ?: @{};
}

+ (NSString *)builtInNameForIdentifier:(NSString *)identifier {
    VibeLoadBuiltInThemes();
    return builtInNames[identifier];
}

#pragma mark Default album art

// A bundled stem (lowercase snake, matching the theme identifiers' shape) or
// a container reference whose name is the content hash — which is also what
// makes the lifetime image cache below safe: a changed image is a new key.
static BOOL VibeIsValidDefaultAlbumArtValue(NSString *_Nullable value) {
    if (value.length == 0) {
        return NO;
    }
    static NSRegularExpression *shape;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shape = [NSRegularExpression regularExpressionWithPattern:
                @"^([a-z0-9]+(_[a-z0-9]+)*|custom:[0-9a-f]{40}\\.(png|jpg))$"
                options:0 error:NULL];
    });
    return [shape numberOfMatchesInString:value options:0
                                    range:NSMakeRange(0, value.length)] == 1;
}

static NSString *VibeCustomAlbumArtDirectory(void) {
    // A test seam: the host-less suite is unsandboxed, so without a redirect
    // it would write into the developer's real ~/Library. Shipping reads no
    // such variable.
    const char *override = getenv("VIBE_THEME_ART_DIR");
    if (override) {
        return [NSString stringWithUTF8String:override];
    }
    NSString *support = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"ThemeArt"];
}

// JPEG or PNG by magic, square by pixel counts, bounded in bytes and pixels.
// Returns the extension, or nil with the failed expectation in outReason.
static const NSUInteger kAlbumArtByteCap = 8 * 1024 * 1024;
static const NSInteger kAlbumArtPixelCap = 4096;
static const NSInteger kAlbumArtPixelFloor = 64;

static NSString *VibeValidatedAlbumArtExtension(NSData *data, NSString **outReason) {
    *outReason = nil;
    if (data.length == 0 || data.length > kAlbumArtByteCap) {
        *outReason = @"the image is empty or over 8 MB";
        return nil;
    }
    const uint8_t *b = data.bytes;
    NSString *ext = nil;
    if (data.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
        ext = @"jpg";
    } else if (data.length > 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') {
        ext = @"png";
    } else {
        *outReason = @"the image must be a JPEG or PNG";
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    NSDictionary *props = source ? CFBridgingRelease(
            CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
    if (source) {
        CFRelease(source);
    }
    NSInteger width = [props[(__bridge NSString *)kCGImagePropertyPixelWidth] integerValue];
    NSInteger height = [props[(__bridge NSString *)kCGImagePropertyPixelHeight] integerValue];
    if (width < kAlbumArtPixelFloor || width > kAlbumArtPixelCap || width != height) {
        *outReason = @"the image must be square, between 64 and 4096 pixels";
        return nil;
    }
    return ext;
}

+ (NSString *)storeCustomAlbumArtData:(NSData *)data error:(NSError **)error {
    NSString *reason = nil;
    NSString *ext = VibeValidatedAlbumArtExtension(data, &reason);
    if (!ext) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:3
                    userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return nil;
    }
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    NSString *directory = VibeCustomAlbumArtDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *file = [NSString stringWithFormat:@"%@.%@", hex, ext];
    NSString *path = [directory stringByAppendingPathComponent:file];
    if (![NSFileManager.defaultManager fileExistsAtPath:path] &&
        ![data writeToFile:path atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:4
                    userInfo:@{NSLocalizedDescriptionKey: @"could not save the image"}];
        }
        return nil;
    }
    return [@"custom:" stringByAppendingString:file];
}

+ (NSArray<NSString *> *)bundledAlbumArtNames {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *ext in @[@"png", @"jpg"]) {
        for (NSURL *url in [[NSBundle bundleForClass:self]
                URLsForResourcesWithExtension:ext subdirectory:@"Themes/art"]) {
            [names addObject:url.lastPathComponent.stringByDeletingPathExtension];
        }
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSImage *)imageForDefaultAlbumArt:(NSString *)value {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *key = VibeIsValidDefaultAlbumArtValue(value) ? value : @"";
    @synchronized (cache) {
        NSImage *cached = cache[key];
        if (cached) {
            return cached;
        }
        // The bounded decode (Common/PlatformImage.h): the draw sites are the
        // header panel and thumbnail cells, and a 4096px original must never
        // be materialized into a lifetime-cached full bitmap.
        NSData *data = nil;
        if ([key hasPrefix:@"custom:"]) {
            data = [NSData dataWithContentsOfFile:[VibeCustomAlbumArtDirectory()
                    stringByAppendingPathComponent:[key substringFromIndex:7]]];
            // One custom image is live at a time; auditioned predecessors
            // would otherwise stay pinned by their content-hash keys.
            for (NSString *stale in [cache.allKeys copy]) {
                if ([stale hasPrefix:@"custom:"]) {
                    [cache removeObjectForKey:stale];
                }
            }
        } else if (key.length) {
            for (NSString *ext in @[@"png", @"jpg"]) {
                NSURL *url = [[NSBundle bundleForClass:self] URLForResource:key
                        withExtension:ext subdirectory:@"Themes/art"];
                if (url) {
                    data = [NSData dataWithContentsOfURL:url];
                    break;
                }
            }
        }
        NSImage *image = data ? VibeDecodedImageWithData(data, kVibeDisplayArtDimension) : nil;
        // The factory record image; the blank square is for the host-less
        // test bundle, which carries no asset catalog.
        image = image ?: [NSImage imageNamed:@"record-bg"]
                ?: [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        cache[key] = image;
        return image;
    }
}

#pragma mark Theme archives

// Minimal ZIP, self-contained: the writer emits stored (uncompressed)
// entries; the reader takes stored and raw-deflate ones, which covers both
// our own exports and a zip a person made by hand (Finder compresses).

static uint32_t VibeCRC32(NSData *data) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) {
                c = (c & 1) ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            }
            table[i] = c;
        }
    });
    uint32_t crc = 0xFFFFFFFF;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        crc = table[(crc ^ bytes[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

static void VibeAppendLE(NSMutableData *out, uint64_t value, int bytes) {
    for (int i = 0; i < bytes; i++) {
        uint8_t byte = (value >> (8 * i)) & 0xFF;
        [out appendBytes:&byte length:1];
    }
}

static NSData *VibeZipData(NSDictionary<NSString *, NSData *> *entries) {
    NSMutableData *out = [NSMutableData data];
    NSMutableData *central = [NSMutableData data];
    NSUInteger count = 0;
    for (NSString *name in [entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *data = entries[name];
        NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = VibeCRC32(data);
        NSUInteger offset = out.length;
        VibeAppendLE(out, 0x04034b50, 4);
        VibeAppendLE(out, 20, 2);              // version needed
        VibeAppendLE(out, 0, 2);               // flags
        VibeAppendLE(out, 0, 2);               // method: stored
        VibeAppendLE(out, 0, 4);               // dos time/date
        VibeAppendLE(out, crc, 4);
        VibeAppendLE(out, data.length, 4);     // compressed
        VibeAppendLE(out, data.length, 4);     // uncompressed
        VibeAppendLE(out, nameData.length, 2);
        VibeAppendLE(out, 0, 2);               // extra
        [out appendData:nameData];
        [out appendData:data];

        VibeAppendLE(central, 0x02014b50, 4);
        VibeAppendLE(central, 20, 2);          // made by
        VibeAppendLE(central, 20, 2);          // needed
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 4);
        VibeAppendLE(central, crc, 4);
        VibeAppendLE(central, data.length, 4);
        VibeAppendLE(central, data.length, 4);
        VibeAppendLE(central, nameData.length, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 2);
        VibeAppendLE(central, 0, 4);
        VibeAppendLE(central, offset, 4);
        [central appendData:nameData];
        count++;
    }
    NSUInteger centralOffset = out.length;
    [out appendData:central];
    VibeAppendLE(out, 0x06054b50, 4);
    VibeAppendLE(out, 0, 2);
    VibeAppendLE(out, 0, 2);
    VibeAppendLE(out, count, 2);
    VibeAppendLE(out, count, 2);
    VibeAppendLE(out, central.length, 4);
    VibeAppendLE(out, centralOffset, 4);
    VibeAppendLE(out, 0, 2);
    return out;
}

static uint32_t VibeReadLE(const uint8_t *bytes, int width) {
    uint32_t value = 0;
    for (int i = width - 1; i >= 0; i--) {
        value = (value << 8) | bytes[i];
    }
    return value;
}

// nil when the data is not a zip this reader can walk. Entries it cannot
// decode (an unsupported method) are skipped rather than fatal.
static NSDictionary<NSString *, NSData *> *VibeUnzipData(NSData *zip) {
    const uint8_t *bytes = zip.bytes;
    NSUInteger length = zip.length;
    if (length < 22) {
        return nil;
    }
    // Find the end-of-central-directory record from the tail (comment ≤ 64KB).
    NSInteger eocd = -1;
    NSInteger floor = MAX(0, (NSInteger)length - 22 - 65535);
    for (NSInteger i = (NSInteger)length - 22; i >= floor; i--) {
        if (VibeReadLE(bytes + i, 4) == 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) {
        return nil;
    }
    NSUInteger count = VibeReadLE(bytes + eocd + 10, 2);
    NSUInteger offset = VibeReadLE(bytes + eocd + 16, 4);
    // A total budget across all entries, so deflate's ~1000:1 ratio cannot
    // aim thousands of central-directory entries at one small stream and
    // exhaust memory. One JSON plus one image is all the caller needs.
    NSUInteger budget = 2 * kAlbumArtByteCap + kThemeJSONByteCap;
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        if (offset + 46 > length || VibeReadLE(bytes + offset, 4) != 0x02014b50) {
            return nil;
        }
        NSUInteger method = VibeReadLE(bytes + offset + 10, 2);
        NSUInteger csize = VibeReadLE(bytes + offset + 20, 4);
        NSUInteger usize = VibeReadLE(bytes + offset + 24, 4);
        NSUInteger nameLength = VibeReadLE(bytes + offset + 28, 2);
        NSUInteger extraLength = VibeReadLE(bytes + offset + 30, 2);
        NSUInteger commentLength = VibeReadLE(bytes + offset + 32, 2);
        NSUInteger local = VibeReadLE(bytes + offset + 42, 4);
        // TRAP: the fixed 46-byte header is bounds-checked above, but the
        // variable-length name that follows is NOT — a crafted nameLength
        // (≤65535) would read past the buffer. Guard the name AND the offset
        // advance before touching either.
        if (offset + 46 + nameLength + extraLength + commentLength > length) {
            return nil;
        }
        NSString *name = [[NSString alloc] initWithBytes:bytes + offset + 46
                length:nameLength encoding:NSUTF8StringEncoding];
        offset += 46 + nameLength + extraLength + commentLength;
        if (local + 30 > length || VibeReadLE(bytes + local, 4) != 0x04034b50) {
            return nil;
        }
        NSUInteger localName = VibeReadLE(bytes + local + 26, 2);
        NSUInteger localExtra = VibeReadLE(bytes + local + 28, 2);
        NSUInteger dataStart = local + 30 + localName + localExtra;
        if (dataStart + csize > length || !name || [name hasSuffix:@"/"]) {
            continue;
        }
        NSData *raw = [zip subdataWithRange:NSMakeRange(dataStart, csize)];
        if (method == 0 && raw.length <= budget) {
            budget -= raw.length;
            entries[name] = raw;
        } else if (method == 8 && usize > 0 && usize <= budget) {
            NSMutableData *inflated = [NSMutableData dataWithLength:usize];
            size_t written = compression_decode_buffer(inflated.mutableBytes, usize,
                    raw.bytes, raw.length, NULL, COMPRESSION_ZLIB);
            if (written == usize) {
                budget -= usize;
                entries[name] = inflated;
            }
        }
    }
    return entries;
}

+ (NSData *)archiveDataForRecord:(NSDictionary<NSString *, id> *)record
                            name:(NSString *)name {
    NSString *art = [[[AppTheme alloc] initWithRecord:record] defaultAlbumArt];
    if (![art hasPrefix:@"custom:"]) {
        return nil;
    }
    NSString *file = [art substringFromIndex:7];
    NSData *image = [NSData dataWithContentsOfFile:
            [VibeCustomAlbumArtDirectory() stringByAppendingPathComponent:file]];
    if (!image) {
        return nil;
    }
    return VibeZipData(@{
        @"theme.json": [self JSONDataForRecord:record name:name],
        file: image,
    });
}

+ (NSDictionary<NSString *, id> *)recordFromJSONOrArchiveData:(NSData *)data
                                                         name:(NSString **)outName
                                                        error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    BOOL isZip = data.length > 4 && bytes[0] == 'P' && bytes[1] == 'K';
    if (!isZip) {
        NSMutableDictionary *record =
                [[self recordFromJSONData:data name:outName error:error] mutableCopy];
        // JSON alone cannot carry the image: a custom reference that names
        // nothing already stored here is dangling — drop it, keep the theme.
        NSString *art = record[kFieldDefaultAlbumArt];
        if ([art hasPrefix:@"custom:"]) {
            NSString *path = [VibeCustomAlbumArtDirectory()
                    stringByAppendingPathComponent:[art substringFromIndex:7]];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                [record removeObjectForKey:kFieldDefaultAlbumArt];
            }
        }
        return record;
    }
    if (data.length > 2 * kAlbumArtByteCap + kThemeJSONByteCap) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:1 userInfo:nil];
        }
        return nil;
    }
    NSDictionary<NSString *, NSData *> *entries = VibeUnzipData(data);
    // Skip a Finder zip's AppleDouble sidecars — __MACOSX/._theme.json has a
    // .json extension but is not JSON, and would nondeterministically win.
    NSData *json = nil;
    NSMutableDictionary<NSString *, NSData *> *byBaseName = [NSMutableDictionary dictionary];
    for (NSString *entry in entries) {
        NSString *base = entry.lastPathComponent;
        if ([entry hasPrefix:@"__MACOSX/"] || [base hasPrefix:@"._"]) {
            continue;
        }
        byBaseName[base] = entries[entry];
        if ([base.pathExtension isEqualToString:@"json"] && !json) {
            json = entries[entry];
        }
    }
    if (!json) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:5 userInfo:
                    @{NSLocalizedDescriptionKey: @"the archive carries no theme JSON"}];
        }
        return nil;
    }
    NSMutableDictionary *record =
            [[self recordFromJSONData:json name:outName error:error] mutableCopy];
    if (!record) {
        return nil;
    }
    NSString *art = record[kFieldDefaultAlbumArt];
    if ([art hasPrefix:@"custom:"]) {
        // The image ships beside the JSON under its reference name. It is
        // re-validated and re-hashed here — the filename is not trusted —
        // and the record rewritten to the stored copy.
        NSData *image = byBaseName[[art substringFromIndex:7]];
        NSString *stored = image ? [self storeCustomAlbumArtData:image error:error] : nil;
        if (stored) {
            record[kFieldDefaultAlbumArt] = stored;
        } else {
            [record removeObjectForKey:kFieldDefaultAlbumArt];
        }
    }
    return record;
}

#pragma mark Names and migration

+ (NSString *)dedupedThemeName:(NSString *)candidate
                      fallback:(NSString *)fallback
                 existingNames:(NSArray<NSString *> *)existingNames {
    NSString *base = TrimmedCappedString(candidate);
    if (base.length == 0) {
        base = fallback;
    }
    NSString *name = base;
    NSUInteger suffix = 2;
    while ([existingNames indexOfObjectPassingTest:^BOOL(NSString *other, NSUInteger i, BOOL *stop) {
        return [other caseInsensitiveCompare:name] == NSOrderedSame;
    }] != NSNotFound) {
        name = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)suffix++];
    }
    return name;
}

+ (NSDictionary<NSString *, id> *)migratedRecordFromLegacyValues:
        (NSDictionary<NSString *, id> *)legacyValues {
    NSDictionary *record =
            [[[AppTheme alloc] initWithRecord:legacyValues] dictionaryRepresentation];
    return record.count ? record : nil;
}

#pragma mark JSON

// Far above any real theme, low enough that a mispicked video file fails
// before the parser sees it.
static const NSUInteger kThemeJSONByteCap = 64 * 1024;

+ (NSDictionary<NSString *, id> *)recordFromJSONData:(NSData *)data
                                                name:(NSString **)outName
                                               error:(NSError **)error {
    if (outName) {
        *outName = nil;
    }
    if (data.length == 0 || data.length > kThemeJSONByteCap) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:1 userInfo:nil];
        }
        return nil;
    }
    NSError *parseError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:2 userInfo:
                    parseError ? @{NSUnderlyingErrorKey: parseError} : nil];
        }
        return nil;
    }
    if (outName && [parsed[kVibeThemeRecordNameKey] isKindOfClass:NSString.class]) {
        *outName = parsed[kVibeThemeRecordNameKey];
    }
    return [[[AppTheme alloc] initWithRecord:parsed] dictionaryRepresentation];
}

+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record name:(NSString *)name {
    NSMutableDictionary *json =
            [[[[AppTheme alloc] initWithRecord:record] dictionaryRepresentation] mutableCopy];
    json[kVibeThemeRecordVersionKey] = @1;
    json[kVibeThemeRecordNameKey] = name;
    return [NSJSONSerialization dataWithJSONObject:json
                                           options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                             error:NULL];
}

#pragma mark Record

- (instancetype)init {
    return [self initWithRecord:nil];
}

- (instancetype)initWithRecord:(NSDictionary<NSString *, id> *)record {
    self = [super init];
    if (self) {
        _fields = [NSMutableDictionary dictionary];
        [self replaceWithRecord:record];
    }
    return self;
}

- (void)replaceWithRecord:(NSDictionary<NSString *, id> *)record {
    [_fields removeAllObjects];
    for (NSString *key in KnownFieldKeys()) {
        [self storeSanitized:record[key] forKey:key];
    }
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    return [_fields copy];
}

// Sanitize, then keep only a value that differs from the default — the
// record stays sparse whatever a setter or file hands it.
- (void)storeSanitized:(id)raw forKey:(NSString *)key {
    id value = SanitizedFieldValue(key, raw);
    if (!value || [value isEqual:FieldDefaults()[key]]) {
        [_fields removeObjectForKey:key];
    } else {
        _fields[key] = value;
    }
}

- (NSString *)stringForKey:(NSString *)key {
    return _fields[key] ?: FieldDefaults()[key];
}

- (CGFloat)floatForKey:(NSString *)key {
    return [(NSNumber *)(_fields[key] ?: FieldDefaults()[key]) doubleValue];
}

- (BOOL)boolForKey:(NSString *)key {
    return [(NSNumber *)(_fields[key] ?: FieldDefaults()[key]) boolValue];
}

#pragma mark Scalar fields

- (NSString *)waveformStyle { return [self stringForKey:kFieldWaveformStyle]; }
- (void)setWaveformStyle:(NSString *)v { [self storeSanitized:v forKey:kFieldWaveformStyle]; }

- (NSString *)mode { return [self stringForKey:kFieldMode]; }
- (void)setMode:(NSString *)v { [self storeSanitized:v forKey:kFieldMode]; }

- (NSString *)waveformTheme { return [self stringForKey:kFieldWaveformTheme]; }
- (void)setWaveformTheme:(NSString *)v { [self storeSanitized:v forKey:kFieldWaveformTheme]; }

- (BOOL)waveformGradient { return [self boolForKey:kFieldWaveformGradient]; }
- (void)setWaveformGradient:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldWaveformGradient]; }

- (NSString *)windowTint { return [self stringForKey:kFieldWindowTint]; }
- (void)setWindowTint:(NSString *)v { [self storeSanitized:v forKey:kFieldWindowTint]; }

- (NSString *)playlistTint { return [self stringForKey:kFieldPlaylistTint]; }
- (void)setPlaylistTint:(NSString *)v { [self storeSanitized:v forKey:kFieldPlaylistTint]; }

- (NSString *)windowBackgroundStyle { return [self stringForKey:kFieldWindowBackgroundStyle]; }
- (void)setWindowBackgroundStyle:(NSString *)v { [self storeSanitized:v forKey:kFieldWindowBackgroundStyle]; }

- (NSString *)playlistBackgroundStyle { return [self stringForKey:kFieldPlaylistBackgroundStyle]; }
- (void)setPlaylistBackgroundStyle:(NSString *)v { [self storeSanitized:v forKey:kFieldPlaylistBackgroundStyle]; }

- (CGFloat)windowCornerRadius { return [self floatForKey:kFieldWindowCornerRadius]; }
- (void)setWindowCornerRadius:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldWindowCornerRadius]; }

- (BOOL)showFileInfo { return [self boolForKey:kFieldShowFileInfo]; }
- (void)setShowFileInfo:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowFileInfo]; }

- (BOOL)showRemainingTime { return [self boolForKey:kFieldShowRemainingTime]; }
- (void)setShowRemainingTime:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowRemainingTime]; }

- (BOOL)showBPM { return [self boolForKey:kFieldShowBPM]; }
- (void)setShowBPM:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowBPM]; }

- (BOOL)showKey { return [self boolForKey:kFieldShowKey]; }
- (void)setShowKey:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowKey]; }

- (BOOL)keyColorsEnabled { return [self boolForKey:kFieldKeyColorsEnabled]; }
- (void)setKeyColorsEnabled:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldKeyColorsEnabled]; }

- (NSString *)keyNotation { return [self stringForKey:kFieldKeyNotation]; }
- (void)setKeyNotation:(NSString *)v { [self storeSanitized:v forKey:kFieldKeyNotation]; }

- (NSString *)mainFontFace { return [self stringForKey:kFieldMainFontFace]; }
- (void)setMainFontFace:(NSString *)v { [self storeSanitized:v forKey:kFieldMainFontFace]; }

- (CGFloat)mainFontSize { return [self floatForKey:kFieldMainFontSize]; }
- (void)setMainFontSize:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldMainFontSize]; }

- (NSString *)infoFontFace { return [self stringForKey:kFieldInfoFontFace]; }
- (void)setInfoFontFace:(NSString *)v { [self storeSanitized:v forKey:kFieldInfoFontFace]; }

- (CGFloat)infoFontSize { return [self floatForKey:kFieldInfoFontSize]; }
- (void)setInfoFontSize:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldInfoFontSize]; }

- (NSString *)playlistFontFace { return [self stringForKey:kFieldPlaylistFontFace]; }
- (void)setPlaylistFontFace:(NSString *)v { [self storeSanitized:v forKey:kFieldPlaylistFontFace]; }

- (CGFloat)playlistFontSize { return [self floatForKey:kFieldPlaylistFontSize]; }
- (void)setPlaylistFontSize:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldPlaylistFontSize]; }

- (NSString *)playlistDurationFontFace { return [self stringForKey:kFieldPlaylistDurationFontFace]; }
- (void)setPlaylistDurationFontFace:(NSString *)v { [self storeSanitized:v forKey:kFieldPlaylistDurationFontFace]; }

- (CGFloat)playlistDurationFontSize { return [self floatForKey:kFieldPlaylistDurationFontSize]; }
- (void)setPlaylistDurationFontSize:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldPlaylistDurationFontSize]; }

- (NSString *)defaultAlbumArt { return [self stringForKey:kFieldDefaultAlbumArt]; }
- (NSImage *)resolvedDefaultAlbumArtImage { return [AppTheme imageForDefaultAlbumArt:self.defaultAlbumArt]; }
- (void)setDefaultAlbumArt:(NSString *)v { [self storeSanitized:v forKey:kFieldDefaultAlbumArt]; }

- (BOOL)showPlaylistArtwork { return [self boolForKey:kFieldShowPlaylistArtwork]; }
- (void)setShowPlaylistArtwork:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowPlaylistArtwork]; }

- (BOOL)showPlaylistDuration { return [self boolForKey:kFieldShowPlaylistDuration]; }
- (void)setShowPlaylistDuration:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowPlaylistDuration]; }

#pragma mark Color pairs

- (VibeColor *)colorForBase:(NSString *)base dark:(BOOL)isDark {
    NSString *hex = _fields[ColorFieldKey(base, self.isSingleMode ? YES : isDark)];
    if (!hex) {
        return nil;
    }
    VibeColor *color = _parsedColors[hex];
    if (!color) {
        color = VibeColorFromHexString(hex);
        if (!_parsedColors) {
            _parsedColors = [NSMutableDictionary dictionary];
        }
        _parsedColors[hex] = color;
    }
    return color;
}

// Single mode has ONE color per field, used whatever the appearance is. The
// dark-keyed half is its canonical slot: reads and writes from either side
// land there, and the light-keyed halves lie dormant — preserved, so a theme
// flipped to single and back to dual keeps its second palette.
- (BOOL)isSingleMode {
    return [self.mode isEqualToString:SETTINGS_VALUE_THEME_MODE_SINGLE];
}

- (void)setColor:(VibeColor *)color forBase:(NSString *)base dark:(BOOL)isDark {
    [self storeSanitized:VibeHexStringFromColor(color)
                  forKey:ColorFieldKey(base, self.isSingleMode ? YES : isDark)];
}

- (NSAppearance *)requiredWindowAppearance {
    return self.isSingleMode
            ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
}

- (VibeColor *)waveformPlayedColorForDark:(BOOL)isDark { return [self colorForBase:kColorWaveformPlayed dark:isDark]; }
- (void)setWaveformPlayedColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorWaveformPlayed dark:isDark]; }

- (VibeColor *)waveformUnplayedColorForDark:(BOOL)isDark { return [self colorForBase:kColorWaveformUnplayed dark:isDark]; }
- (void)setWaveformUnplayedColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorWaveformUnplayed dark:isDark]; }

- (VibeColor *)windowTintColorForDark:(BOOL)isDark { return [self colorForBase:kColorWindowTint dark:isDark]; }
- (void)setWindowTintColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorWindowTint dark:isDark]; }

- (VibeColor *)playlistTintColorForDark:(BOOL)isDark { return [self colorForBase:kColorPlaylistTint dark:isDark]; }
- (void)setPlaylistTintColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorPlaylistTint dark:isDark]; }

- (VibeColor *)windowBackgroundColorForDark:(BOOL)isDark { return [self colorForBase:kColorWindowBackground dark:isDark]; }
- (void)setWindowBackgroundColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorWindowBackground dark:isDark]; }

- (VibeColor *)titleColorForDark:(BOOL)isDark { return [self colorForBase:kColorTitle dark:isDark]; }
- (void)setTitleColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorTitle dark:isDark]; }

- (VibeColor *)artistColorForDark:(BOOL)isDark { return [self colorForBase:kColorArtist dark:isDark]; }
- (void)setArtistColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorArtist dark:isDark]; }

- (VibeColor *)infoColorForDark:(BOOL)isDark { return [self colorForBase:kColorInfo dark:isDark]; }
- (void)setInfoColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorInfo dark:isDark]; }

- (VibeColor *)timeColorForDark:(BOOL)isDark { return [self colorForBase:kColorTime dark:isDark]; }
- (void)setTimeColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorTime dark:isDark]; }

- (VibeColor *)playlistBackgroundColorForDark:(BOOL)isDark { return [self colorForBase:kColorPlaylistBackground dark:isDark]; }
- (void)setPlaylistBackgroundColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorPlaylistBackground dark:isDark]; }

- (VibeColor *)playlistPlayingRowColorForDark:(BOOL)isDark { return [self colorForBase:kColorPlaylistPlayingRow dark:isDark]; }
- (void)setPlaylistPlayingRowColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorPlaylistPlayingRow dark:isDark]; }

- (VibeColor *)playlistSelectedRowColorForDark:(BOOL)isDark { return [self colorForBase:kColorPlaylistSelectedRow dark:isDark]; }
- (void)setPlaylistSelectedRowColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorPlaylistSelectedRow dark:isDark]; }

@end
