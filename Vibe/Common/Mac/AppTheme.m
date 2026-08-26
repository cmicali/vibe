//
//  AppTheme.m
//  Vibe
//

#import "AppTheme.h"
#import "AppSettings.h"
#import "SettingsRules.h"
#import "PlatformColor.h"

NSString *const kVibeThemeIdentifierVibe = @"vibe";
NSString *const kVibeThemeIdentifierIndustrial = @"industrial";

static const CGFloat kCornerRadiusMin = 0;
static const CGFloat kCornerRadiusDefault = 20;

NSString *const kVibeThemeRecordNameKey = @"name";
NSString *const kVibeThemeRecordVersionKey = @"version";
NSString *const kVibeThemeRecordIdentifierKey = @"id";

// The record field keys ARE the accessor names, which is what makes a record
// self-describing in a theme JSON. Never renamed: they are persisted.
static NSString *const kFieldWaveformStyle = @"waveformStyle";
static NSString *const kFieldWaveformTheme = @"waveformTheme";
static NSString *const kFieldWindowTint = @"windowTint";
static NSString *const kFieldWindowBackgroundStyle = @"windowBackgroundStyle";
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

// The color pairs' base names; Dark/Light is appended per appearance.
static NSString *const kColorWaveformPlayed = @"waveformPlayedColor";
static NSString *const kColorWaveformUnplayed = @"waveformUnplayedColor";
static NSString *const kColorWindowTint = @"windowTintColor";
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
             kColorWindowBackground, kColorTitle, kColorArtist, kColorInfo, kColorTime,
             kColorPlaylistBackground, kColorPlaylistPlayingRow, kColorPlaylistSelectedRow];
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
                                     kFieldShowBPM, kFieldShowKey, kFieldKeyColorsEnabled]];
    });
    return keys;
}

static NSSet<NSString *> *FaceFieldKeys(void) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[kFieldMainFontFace, kFieldInfoFontFace,
                                     kFieldPlaylistFontFace]];
    });
    return keys;
}

// A font slot's clamp is narrow on purpose: the labels sit in fixed frames,
// and call sites derive their own size as an offset from the slot's base.
static BOOL FontSizeClamp(NSString *key, CGFloat *min, CGFloat *max) {
    if ([key isEqualToString:kFieldMainFontSize])     { *min = 20; *max = 26; return YES; }
    if ([key isEqualToString:kFieldInfoFontSize])     { *min = 10; *max = 15; return YES; }
    if ([key isEqualToString:kFieldPlaylistFontSize]) { *min = 11; *max = 16; return YES; }
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
            kFieldWaveformStyle:         SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT,
            kFieldWaveformTheme:         SETTINGS_VALUE_WAVEFORM_THEME_MONO,
            kFieldWindowTint:            SETTINGS_VALUE_WINDOW_TINT_ARTWORK,
            kFieldWindowBackgroundStyle: SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS,
            kFieldWindowCornerRadius:    @(kCornerRadiusDefault),
            kFieldShowFileInfo:          @(YES),
            kFieldShowRemainingTime:     @(NO),
            kFieldShowBPM:               @(YES),
            kFieldShowKey:               @(YES),
            kFieldKeyColorsEnabled:      @(NO),
            kFieldKeyNotation:           SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
            kFieldMainFontFace:          @"",
            kFieldMainFontSize:          @(23),
            kFieldInfoFontFace:          @"",
            kFieldInfoFontSize:          @(13),
            kFieldPlaylistFontFace:      @"",
            kFieldPlaylistFontSize:      @(14),
        };
    });
    return defaults;
}

static NSString *VibeNormalizedWindowBackgroundStyle(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID]
            ? SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID
            : SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS;
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
    if ([key isEqualToString:kFieldWaveformTheme]) {
        return VibeNormalizedWaveformTheme(raw);
    }
    if ([key isEqualToString:kFieldWindowTint]) {
        return VibeNormalizedWindowTint(raw);
    }
    if ([key isEqualToString:kFieldWindowBackgroundStyle]) {
        return VibeNormalizedWindowBackgroundStyle(raw);
    }
    if ([key isEqualToString:kFieldKeyNotation]) {
        return VibeNormalizedKeyNotation(raw);
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
}

#pragma mark Built-ins

+ (NSArray<NSString *> *)builtInThemeIdentifiers {
    return @[kVibeThemeIdentifierVibe, kVibeThemeIdentifierIndustrial];
}

+ (BOOL)isBuiltInIdentifier:(NSString *)identifier {
    return identifier && [[self builtInThemeIdentifiers] containsObject:identifier];
}

+ (NSDictionary<NSString *, id> *)builtInRecordForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:kVibeThemeIdentifierIndustrial]) {
        return @{
            kFieldWaveformStyle: @"detailed",
            kFieldWaveformTheme: SETTINGS_VALUE_WAVEFORM_THEME_ORANGE,
            kFieldInfoFontFace:  @"Menlo-Regular",
        };
    }
    return @{};
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

- (NSString *)waveformTheme { return [self stringForKey:kFieldWaveformTheme]; }
- (void)setWaveformTheme:(NSString *)v { [self storeSanitized:v forKey:kFieldWaveformTheme]; }

- (NSString *)windowTint { return [self stringForKey:kFieldWindowTint]; }
- (void)setWindowTint:(NSString *)v { [self storeSanitized:v forKey:kFieldWindowTint]; }

- (NSString *)windowBackgroundStyle { return [self stringForKey:kFieldWindowBackgroundStyle]; }
- (void)setWindowBackgroundStyle:(NSString *)v { [self storeSanitized:v forKey:kFieldWindowBackgroundStyle]; }

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

#pragma mark Color pairs

- (VibeColor *)colorForBase:(NSString *)base dark:(BOOL)isDark {
    return VibeColorFromHexString(_fields[ColorFieldKey(base, isDark)]);
}

- (void)setColor:(VibeColor *)color forBase:(NSString *)base dark:(BOOL)isDark {
    [self storeSanitized:VibeHexStringFromColor(color) forKey:ColorFieldKey(base, isDark)];
}

- (VibeColor *)waveformPlayedColorForDark:(BOOL)isDark { return [self colorForBase:kColorWaveformPlayed dark:isDark]; }
- (void)setWaveformPlayedColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorWaveformPlayed dark:isDark]; }

- (VibeColor *)waveformUnplayedColorForDark:(BOOL)isDark { return [self colorForBase:kColorWaveformUnplayed dark:isDark]; }
- (void)setWaveformUnplayedColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorWaveformUnplayed dark:isDark]; }

- (VibeColor *)windowTintColorForDark:(BOOL)isDark { return [self colorForBase:kColorWindowTint dark:isDark]; }
- (void)setWindowTintColor:(VibeColor *)c forDark:(BOOL)isDark { [self setColor:c forBase:kColorWindowTint dark:isDark]; }

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
