//
//  AppTheme.m
//  Vibe
//

#import "AppTheme.h"
#import <AppKit/AppKit.h>
#import <compression.h>
#import <CommonCrypto/CommonDigest.h>
#import "PlatformImage.h"
#import "AppSettings.h"
#import "SettingsRules.h"
#import "PlatformColor.h"
#import "NSView+DarkMode.h"
#import "NSURL+Hash.h"

NSString *const kVibeThemeIdentifierVibe = @"vibe";

static const CGFloat kCornerRadiusMin = 0;

NSString *const kVibeThemeRecordNameKey = @"name";
NSString *const kVibeThemeRecordIdentifierKey = @"id";

// The record field keys ARE the accessor names — the stored form under
// Appearance.userThemes and the working record. A theme JSON carries the
// same values nested under the editor's section names; ThemeJSONGroups()
// is the whole mapping. Never renamed: they are persisted.
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
static NSString *const kFieldTitleFontFace = @"titleFontFace";
static NSString *const kFieldTitleFontSize = @"titleFontSize";
static NSString *const kFieldArtistFontFace = @"artistFontFace";
static NSString *const kFieldArtistFontSize = @"artistFontSize";
static NSString *const kFieldInfoFontFace = @"infoFontFace";
static NSString *const kFieldInfoFontSize = @"infoFontSize";
static NSString *const kFieldPlaylistFontFace = @"playlistFontFace";
static NSString *const kFieldPlaylistFontSize = @"playlistFontSize";
static NSString *const kFieldPlaylistDurationFontFace = @"playlistDurationFontFace";
static NSString *const kFieldPlaylistDurationFontSize = @"playlistDurationFontSize";
static NSString *const kFieldDefaultArtworkDark  = @"defaultArtworkDark";
static NSString *const kFieldDefaultArtworkLight = @"defaultArtworkLight";

static BOOL VibeIsValidDefaultArtworkValue(NSString *_Nullable value);
static NSDictionary<NSString *, NSArray<NSString *> *> *ThemeJSONFieldLocations(void);
static NSString *const kFieldShowPlaylistArtworkColumn = @"showPlaylistArtworkColumn";
static NSString *const kFieldShowPlaylistDurationColumn = @"showPlaylistDurationColumn";

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

static NSString *_Nullable TrimmedCappedString(id _Nullable raw) {
    if (![raw isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)raw stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 64 ? [trimmed substringToIndex:64] : trimmed;
}

// One row per field: the record key (the accessor name), its JSON home — the
// editor section and the section-local key — the default, and the sanitizer
// for its kind. Every other table here derives from the rows, so a field is
// added in one place and cannot lack a JSON home or a clamp. The defaults are
// today's hardcoded look, which is what keeps the empty record — the built-in
// Vibe theme — pixel-identical to the app before themes existed; color pairs
// default by absence.
typedef id _Nullable (^FieldSanitizer)(id _Nullable raw);

static NSString *const kSpecKey = @"key";
static NSString *const kSpecGroup = @"group";
static NSString *const kSpecJSONKey = @"json";
static NSString *const kSpecDefault = @"default";
static NSString *const kSpecColorBase = @"colorBase";
static NSString *const kSpecSanitize = @"sanitize";

// The kinds — the one gate's rules. A raw value comes out normalized, clamped
// and typed, or nil: dropped, so the default takes over. Bools are numbers
// only, never strings; numbers must be finite; colors must round-trip as
// hex; identifiers snap to their ladders.
static FieldSanitizer BoolField(void) {
    return ^id(id raw) {
        return [raw isKindOfClass:NSNumber.class] ? @([raw boolValue]) : nil;
    };
}

static FieldSanitizer NumberField(double min, double max, BOOL wholePoints) {
    return ^id(id raw) {
        if (![raw isKindOfClass:NSNumber.class] || !isfinite([raw doubleValue])) {
            return nil;
        }
        double clamped = MIN(MAX([raw doubleValue], min), max);
        return @(wholePoints ? round(clamped) : clamped);
    };
}

static FieldSanitizer TextField(void) {
    return ^id(id raw) { return TrimmedCappedString(raw); };
}

static FieldSanitizer LadderField(NSString *(*normalize)(NSString *_Nullable)) {
    return ^id(id raw) {
        return [raw isKindOfClass:NSString.class] ? normalize(raw) : nil;
    };
}

static FieldSanitizer ColorField(void) {
    return ^id(id raw) {
        return [raw isKindOfClass:NSString.class]
                ? VibeHexStringFromColor(VibeColorFromHexString(raw)) : nil;
    };
}

static FieldSanitizer ArtworkField(void) {
    return ^id(id raw) {
        NSString *value = TrimmedCappedString(raw);
        return VibeIsValidDefaultArtworkValue(value) ? value : nil;
    };
}

static NSMutableDictionary *Field(NSString *key, NSString *group, NSString *jsonKey,
                                  id _Nullable defaultValue, FieldSanitizer sanitize) {
    NSMutableDictionary *spec = [NSMutableDictionary dictionaryWithDictionary:@{
        kSpecKey: key, kSpecGroup: group, kSpecJSONKey: jsonKey, kSpecSanitize: [sanitize copy],
    }];
    spec[kSpecDefault] = defaultValue;
    return spec;
}

// A color pair is two rows — Dark, then Light — under one JSON base.
static void AddColorPair(NSMutableArray *rows, NSString *base, NSString *group, NSString *jsonBase) {
    for (NSString *side in @[@"Dark", @"Light"]) {
        NSMutableDictionary *spec = Field([base stringByAppendingString:side], group,
                                          [jsonBase stringByAppendingString:side], nil,
                                          ColorField());
        spec[kSpecColorBase] = base;
        [rows addObject:spec];
    }
}

static NSArray<NSDictionary *> *FieldSpecs(void) {
    static NSArray<NSDictionary *> *specs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *rows = [NSMutableArray array];
        NSString *window = @"window", *player = @"player", *info = @"info",
                 *waveform = @"waveform", *playlist = @"playlist";

        [rows addObject:Field(kFieldMode, window, @"mode", SETTINGS_VALUE_THEME_MODE_DUAL,
                              LadderField(VibeNormalizedThemeMode))];
        [rows addObject:Field(kFieldWindowBackgroundStyle, window, @"backgroundStyle",
                              SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS,
                              LadderField(VibeNormalizedWindowBackgroundStyle))];
        AddColorPair(rows, kColorWindowBackground, window, @"backgroundColor");
        [rows addObject:Field(kFieldWindowTint, window, @"tint", SETTINGS_VALUE_WINDOW_TINT_ARTWORK,
                              LadderField(VibeNormalizedWindowTint))];
        AddColorPair(rows, kColorWindowTint, window, @"tintColor");
        // Whole points: the editor's px readout is integral, so a stored
        // fraction would draw a radius no surface can display. Rounding in
        // the gate heals imports and pre-round stored records alike; the
        // slider merely re-syncs to what landed.
        [rows addObject:Field(kFieldWindowCornerRadius, window, @"cornerRadius",
                              @(kVibeThemeCornerRadiusDefault),
                              NumberField(kCornerRadiusMin, kVibeThemeCornerRadiusMax, YES))];

        [rows addObject:Field(kFieldDefaultArtworkDark, player, @"defaultArtworkDark", @"", ArtworkField())];
        [rows addObject:Field(kFieldDefaultArtworkLight, player, @"defaultArtworkLight", @"", ArtworkField())];
        // The font clamps are narrow on purpose: the labels sit in fixed frames.
        [rows addObject:Field(kFieldTitleFontFace, player, @"titleFontFace", @"", TextField())];
        [rows addObject:Field(kFieldTitleFontSize, player, @"titleFontSize",
                              @(kVibeThemeTitleFontBaseSize), NumberField(20, 26, NO))];
        AddColorPair(rows, kColorTitle, player, @"titleColor");
        [rows addObject:Field(kFieldArtistFontFace, player, @"artistFontFace", @"", TextField())];
        [rows addObject:Field(kFieldArtistFontSize, player, @"artistFontSize",
                              @(kVibeThemeArtistFontBaseSize), NumberField(12, 20, NO))];
        AddColorPair(rows, kColorArtist, player, @"artistColor");

        [rows addObject:Field(kFieldShowFileInfo, info, @"showFileInfo", @YES, BoolField())];
        [rows addObject:Field(kFieldInfoFontFace, info, @"fontFace", @"", TextField())];
        [rows addObject:Field(kFieldInfoFontSize, info, @"fontSize",
                              @(kVibeThemeInfoFontBaseSize), NumberField(10, 15, NO))];
        AddColorPair(rows, kColorInfo, info, @"color");
        AddColorPair(rows, kColorTime, info, @"timeColor");
        [rows addObject:Field(kFieldShowRemainingTime, info, @"showRemainingTime", @NO, BoolField())];
        [rows addObject:Field(kFieldShowBPM, info, @"showBPM", @YES, BoolField())];
        [rows addObject:Field(kFieldShowKey, info, @"showKey", @YES, BoolField())];
        [rows addObject:Field(kFieldKeyNotation, info, @"keyNotation", SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
                              LadderField(VibeNormalizedKeyNotation))];
        [rows addObject:Field(kFieldKeyColorsEnabled, info, @"keyColorsEnabled", @NO, BoolField())];

        [rows addObject:Field(kFieldWaveformStyle, waveform, @"style",
                              SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT, TextField())];
        [rows addObject:Field(kFieldWaveformTheme, waveform, @"theme", SETTINGS_VALUE_WAVEFORM_THEME_MONO,
                              LadderField(VibeNormalizedWaveformTheme))];
        [rows addObject:Field(kFieldWaveformGradient, waveform, @"gradient", @YES, BoolField())];
        AddColorPair(rows, kColorWaveformPlayed, waveform, @"playedColor");
        AddColorPair(rows, kColorWaveformUnplayed, waveform, @"unplayedColor");

        [rows addObject:Field(kFieldPlaylistBackgroundStyle, playlist, @"backgroundStyle",
                              SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS,
                              LadderField(VibeNormalizedWindowBackgroundStyle))];
        AddColorPair(rows, kColorPlaylistBackground, playlist, @"backgroundColor");
        [rows addObject:Field(kFieldPlaylistTint, playlist, @"tint", SETTINGS_VALUE_WINDOW_TINT_MONO,
                              LadderField(VibeNormalizedPlaylistTint))];
        AddColorPair(rows, kColorPlaylistTint, playlist, @"tintColor");
        [rows addObject:Field(kFieldPlaylistFontFace, playlist, @"fontFace", @"", TextField())];
        [rows addObject:Field(kFieldPlaylistFontSize, playlist, @"fontSize",
                              @(kVibeThemePlaylistFontBaseSize), NumberField(11, 16, NO))];
        [rows addObject:Field(kFieldPlaylistDurationFontFace, playlist, @"durationFontFace", @"", TextField())];
        [rows addObject:Field(kFieldPlaylistDurationFontSize, playlist, @"durationFontSize",
                              @(kVibeThemePlaylistDurationFontBaseSize), NumberField(10, 14, NO))];
        [rows addObject:Field(kFieldShowPlaylistArtworkColumn, playlist, @"showArtworkColumn", @YES, BoolField())];
        [rows addObject:Field(kFieldShowPlaylistDurationColumn, playlist, @"showDurationColumn", @YES, BoolField())];
        AddColorPair(rows, kColorPlaylistPlayingRow, playlist, @"playingRowColor");
        AddColorPair(rows, kColorPlaylistSelectedRow, playlist, @"selectedRowColor");
        specs = [rows copy];
    });
    return specs;
}

static NSDictionary<NSString *, NSDictionary *> *FieldSpecsByKey(void) {
    static NSDictionary<NSString *, NSDictionary *> *byKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in FieldSpecs()) {
            NSCAssert(!map[spec[kSpecKey]], @"field %@ listed twice", spec[kSpecKey]);
            map[spec[kSpecKey]] = spec;
        }
        byKey = [map copy];
    });
    return byKey;
}

static NSDictionary<NSString *, id> *FieldDefaults(void) {
    static NSDictionary<NSString *, id> *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in FieldSpecs()) {
            map[spec[kSpecKey]] = spec[kSpecDefault];
        }
        defaults = [map copy];
    });
    return defaults;
}

static NSArray<NSString *> *KnownFieldKeys(void) {
    return [FieldSpecs() valueForKey:kSpecKey];
}

static id _Nullable SanitizedFieldValue(NSString *key, id _Nullable raw) {
    FieldSanitizer sanitize = FieldSpecsByKey()[key][kSpecSanitize];
    return sanitize ? sanitize(raw) : nil;
}

// base → [darkKey, lightKey], built once: every color read — each row draw,
// each corner-line recomposition — goes through a key, and none should
// allocate one.
static NSDictionary<NSString *, NSArray<NSString *> *> *ColorFieldKeysByBase(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSMutableArray *> *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in FieldSpecs()) {
            NSString *base = spec[kSpecColorBase];
            if (base) {
                [(map[base] ?: (map[base] = [NSMutableArray array])) addObject:spec[kSpecKey]];
            }
        }
        keys = [map copy];
    });
    return keys;
}

static NSString *ColorFieldKey(NSString *base, BOOL isDark) {
    return ColorFieldKeysByBase()[base][isDark ? 0 : 1];
}

@interface AppTheme ()
// The archive writer's form of JSONDataForRecord:name:. Inside a ZIP an image
// reference is the bare name of the entry beside the JSON, so artworkNames
// maps an artwork field to the entry the archive wrote for it. The rewrite
// cannot happen in the record the caller hands over: the sanitizer this runs
// first admits only the prefixed shapes and would drop a bare name entirely.
+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                  artworkNames:(nullable NSDictionary<NSString *, NSString *> *)artworkNames;
@end

@implementation AppTheme {
    // Only sanitized values differing from the defaults — the sparse record.
    NSMutableDictionary<NSString *, id> *_fields;
    // Parsed colors keyed by their hex VALUE, so the cache can never go
    // stale and needs no invalidation hook — an edited field is a new hex.
    // Rows read their fills per draw; without this every draw re-parses.
    NSMutableDictionary<NSString *, VibeColor *> *_parsedColors;
}

// A per-appearance override pair over a semantic fallback, as one dynamic
// color: a nil override resolves to the fallback in that appearance.
static VibeColor *DynamicColor(VibeColor *dark, VibeColor *light, VibeColor *fallback) {
    if (!dark && !light) {
        return fallback;
    }
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return (appearance.isDark ? dark : light) ?: fallback;
    }];
}

// The fallback pinned to one side, for the display* accessors: a dynamic
// semantic color resolves under whatever appearance is current, which for an
// editor well is the pane's, not the side's.
static VibeColor *ResolvedForDark(VibeColor *color, BOOL isDark) {
    __block NSColor *resolved = color;
    NSAppearance *appearance = [NSAppearance appearanceNamed:
            isDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    [appearance performAsCurrentDrawingAppearance:^{
        resolved = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    return resolved ?: color;
}

// Each slot's semantic fallback is spelled once, in its resolved accessor,
// and the display accessor beside it reads the same constant — so the
// surfaces and the editor's wells cannot disagree about an unset slot.
- (VibeColor *)resolvedTitleColor {
    return DynamicColor([self titleColorForDark:YES], [self titleColorForDark:NO],
                        NSColor.labelColor);
}

- (VibeColor *)displayTitleColorForDark:(BOOL)isDark {
    return [self titleColorForDark:isDark] ?: ResolvedForDark(NSColor.labelColor, isDark);
}

- (VibeColor *)resolvedArtistColor {
    return DynamicColor([self artistColorForDark:YES], [self artistColorForDark:NO],
                        NSColor.secondaryLabelColor);
}

- (VibeColor *)displayArtistColorForDark:(BOOL)isDark {
    return [self artistColorForDark:isDark] ?: ResolvedForDark(NSColor.secondaryLabelColor, isDark);
}

- (VibeColor *)resolvedInfoColor {
    return DynamicColor([self infoColorForDark:YES], [self infoColorForDark:NO],
                        NSColor.tertiaryLabelColor);
}

- (VibeColor *)displayInfoColorForDark:(BOOL)isDark {
    return [self infoColorForDark:isDark] ?: ResolvedForDark(NSColor.tertiaryLabelColor, isDark);
}

- (VibeColor *)resolvedTimeColor {
    return DynamicColor([self timeColorForDark:YES], [self timeColorForDark:NO],
                        NSColor.secondaryLabelColor);
}

- (VibeColor *)displayTimeColorForDark:(BOOL)isDark {
    return [self timeColorForDark:isDark] ?: ResolvedForDark(NSColor.secondaryLabelColor, isDark);
}

// The remaining pairs' constants for an unset slot, each beside its pair
// rather than at the surface that draws it.

// The solid covers: a near-opaque neutral in each appearance's register.
static VibeColor *DefaultSolidBackgroundColor(BOOL isDark) {
    return isDark ? [NSColor colorWithWhite:0.11 alpha:0.95]
                  : [NSColor colorWithWhite:0.93 alpha:0.95];
}

// The custom washes: neutral grays in the middle of each appearance's clamp
// band, at the alpha the artwork wash uses there — a starting point to pick
// a hue from.
static VibeColor *DefaultTintColor(BOOL isDark) {
    return isDark ? [NSColor colorWithWhite:0.14 alpha:0.40]
                  : [NSColor colorWithWhite:0.88 alpha:0.55];
}

// The row fills: white in dark and black in light at low opacity, a quiet
// lift over the playlist frost in both appearances, independent of key state
// like the rest of the window chrome.
static VibeColor *DefaultRowFillColor(BOOL isDark) {
    return [(isDark ? NSColor.whiteColor : NSColor.blackColor) colorWithAlphaComponent:0.09];
}

// The custom waveform pair: Mono's resting levels, the played hue the
// appearance's own base.
static VibeColor *DefaultWaveformPlayedColor(BOOL isDark) {
    return isDark ? [NSColor colorWithRed:1 green:1 blue:1 alpha:0.75]
                  : [NSColor colorWithRed:0 green:0 blue:0 alpha:0.75];
}

static VibeColor *DefaultWaveformUnplayedColor(void) {
    return [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.75];
}

- (VibeColor *)displayWindowBackgroundColorForDark:(BOOL)isDark {
    return [self windowBackgroundColorForDark:isDark] ?: DefaultSolidBackgroundColor(isDark);
}

- (VibeColor *)displayPlaylistBackgroundColorForDark:(BOOL)isDark {
    return [self playlistBackgroundColorForDark:isDark] ?: DefaultSolidBackgroundColor(isDark);
}

- (VibeColor *)displayWindowTintColorForDark:(BOOL)isDark {
    return [self windowTintColorForDark:isDark] ?: DefaultTintColor(isDark);
}

- (VibeColor *)displayPlaylistTintColorForDark:(BOOL)isDark {
    return [self playlistTintColorForDark:isDark] ?: DefaultTintColor(isDark);
}

- (VibeColor *)displayPlaylistPlayingRowColorForDark:(BOOL)isDark {
    return [self playlistPlayingRowColorForDark:isDark] ?: DefaultRowFillColor(isDark);
}

- (VibeColor *)displayPlaylistSelectedRowColorForDark:(BOOL)isDark {
    return [self playlistSelectedRowColorForDark:isDark] ?: DefaultRowFillColor(isDark);
}

- (VibeColor *)displayWaveformPlayedColorForDark:(BOOL)isDark {
    return [self waveformPlayedColorForDark:isDark] ?: DefaultWaveformPlayedColor(isDark);
}

- (VibeColor *)displayWaveformUnplayedColorForDark:(BOOL)isDark {
    return [self waveformUnplayedColorForDark:isDark] ?: DefaultWaveformUnplayedColor();
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

#pragma mark Default artwork

// custom: is a container reference whose name is the content hash — which is
// also what makes the lifetime image cache below safe: a changed image is a
// new key. bundled: names an image shipped beside the built-in theme JSONs in
// Resources/Themes/, immutable for a build, so the same cache holds it.
static BOOL VibeIsValidDefaultArtworkValue(NSString *_Nullable value) {
    if (value.length == 0) {
        return NO;
    }
    static NSRegularExpression *shape;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shape = [NSRegularExpression regularExpressionWithPattern:
                @"^(custom:[0-9a-f]{40}|bundled:[a-z0-9_]+)\\.(png|jpg)$"
                options:0 error:NULL];
    });
    return [shape numberOfMatchesInString:value options:0
                                    range:NSMakeRange(0, value.length)] == 1;
}

static NSString *VibeCustomArtworkDirectory(void) {
#if DEBUG
    // A test seam: the host-less suite is unsandboxed, so without a redirect
    // it would write into the developer's real ~/Library. make test always
    // builds Debug; Release compiles the seam out with the rest of the debug
    // surface.
    const char *override = getenv("VIBE_THEME_ART_DIR");
    if (override) {
        return [NSString stringWithUTF8String:override];
    }
#endif
    NSString *support = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [support stringByAppendingPathComponent:@"ThemeArt"];
}

// The Resources/Themes URL a bundled: value names, or nil for any other value
// and for a name THIS build ships no image for — which is what lets an
// archive's own copy stand in. Callers pass a sanitized value: the shape gate
// is what keeps a crafted name out of the bundle lookup.
// The file name after either prefix — the archive entry's base name, the
// container file, the bundled resource — or nil for "" and anything else.
static NSString *_Nullable VibeArtworkFileName(NSString *_Nullable value) {
    for (NSString *prefix in @[@"custom:", @"bundled:"]) {
        if ([value hasPrefix:prefix]) {
            return [value substringFromIndex:prefix.length];
        }
    }
    return nil;
}

// The container path a custom: value names, or nil for any other value.
static NSString *_Nullable VibeCustomArtworkPath(NSString *_Nullable value) {
    if (![value hasPrefix:@"custom:"]) {
        return nil;
    }
    return [VibeCustomArtworkDirectory() stringByAppendingPathComponent:VibeArtworkFileName(value)];
}

static NSURL *_Nullable VibeBundledArtworkURL(NSString *_Nullable value) {
    if (![value hasPrefix:@"bundled:"]) {
        return nil;
    }
    NSString *file = VibeArtworkFileName(value);
    return [[NSBundle bundleForClass:AppTheme.class]
            URLForResource:file.stringByDeletingPathExtension
             withExtension:file.pathExtension subdirectory:@"Themes"];
}

// JPEG or PNG by magic, square by pixel counts, bounded in bytes and pixels.
// Returns the extension, or nil with the failed expectation in outReason.
static const NSUInteger kArtworkByteCap = 8 * 1024 * 1024;
static const NSInteger kArtworkPixelCap = 4096;
static const NSInteger kArtworkPixelFloor = 64;

static NSString *VibeValidatedArtworkExtension(NSData *data, NSString **outReason) {
    *outReason = nil;
    if (data.length == 0 || data.length > kArtworkByteCap) {
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
    CGSize pixels = VibeEncodedImagePixelSize(data);
    NSInteger width = (NSInteger)pixels.width;
    if (width < kArtworkPixelFloor || width > kArtworkPixelCap || pixels.width != pixels.height) {
        *outReason = @"the image must be square, between 64 and 4096 pixels";
        return nil;
    }
    return ext;
}

+ (BOOL)defaultArtworkIsMissing:(NSString *)value {
    if (!VibeIsValidDefaultArtworkValue(value)) {
        return NO;
    }
    if ([value hasPrefix:@"bundled:"]) {
        return VibeBundledArtworkURL(value) == nil;
    }
    return ![NSFileManager.defaultManager fileExistsAtPath:VibeCustomArtworkPath(value)];
}

+ (NSString *)storeCustomArtworkData:(NSData *)data error:(NSError **)error {
    NSString *reason = nil;
    NSString *ext = VibeValidatedArtworkExtension(data, &reason);
    if (!ext) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:3
                    userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return nil;
    }
    NSString *hex = [data sha1Hex];
    NSString *directory = VibeCustomArtworkDirectory();
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

+ (NSSet<NSString *> *)customArtworkFilesInRecord:(NSDictionary<NSString *, id> *)record {
    NSMutableSet<NSString *> *files = [NSMutableSet set];
    for (NSString *key in @[kFieldDefaultArtworkDark, kFieldDefaultArtworkLight]) {
        NSString *value = [record[key] isKindOfClass:NSString.class] ? record[key] : nil;
        if ([value hasPrefix:@"custom:"]) {
            [files addObject:VibeArtworkFileName(value)];
        }
    }
    return files;
}

+ (void)removeCustomArtworkFilesUnreferencedByRecords:(NSArray<NSDictionary *> *)records {
    NSMutableSet<NSString *> *referenced = [NSMutableSet set];
    for (NSDictionary *record in records) {
        [referenced unionSet:[self customArtworkFilesInRecord:record]];
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = VibeCustomArtworkDirectory();
    for (NSString *file in [manager contentsOfDirectoryAtPath:directory error:NULL]) {
        if (![referenced containsObject:file]) {
            [manager removeItemAtPath:[directory stringByAppendingPathComponent:file]
                                error:NULL];
        }
    }
}

static NSMutableDictionary<NSString *, NSImage *> *ArtworkImageCache(void) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

+ (NSImage *)imageForDefaultArtwork:(NSString *)value {
    NSMutableDictionary<NSString *, NSImage *> *cache = ArtworkImageCache();
    NSString *key = VibeIsValidDefaultArtworkValue(value) ? value : @"";
    @synchronized (cache) {
        NSImage *cached = cache[key];
        if (cached) {
            return cached;
        }
    }
    // The read and the bounded decode (Common/PlatformImage.h — 10-100ms) run
    // OUTSIDE the lock, so a first decode never stalls every other consumer
    // of the cache behind it. The draw sites are the header panel and the
    // editor's previews, and a 4096px original must never be materialized
    // into a lifetime-cached full bitmap. The synchronous once-per-key cost
    // on the calling thread is deliberate: the sites need an image to draw
    // NOW, and the lifetime cache makes it a one-time price.
    NSData *data = nil;
    if ([key hasPrefix:@"bundled:"]) {
        NSURL *url = VibeBundledArtworkURL(key);
        data = url ? [NSData dataWithContentsOfURL:url] : nil;
    } else if ([key hasPrefix:@"custom:"]) {
        data = [NSData dataWithContentsOfFile:VibeCustomArtworkPath(key)];
    }
    // The mac's display-art bound (Common/PlatformImage.h): the header
    // draws at most ~525px, so the 1024px cross-platform bound would pin a
    // bitmap 2.5x larger than anything on screen for the app's lifetime.
    NSImage *image = data ? VibeDecodedImageWithData(data, kVibeArchivedDisplayArtDimension) : nil;
    // The factory record image; the blank square is for the host-less
    // test bundle, which carries no asset catalog.
    image = image ?: [NSImage imageNamed:@"record-bg"]
            ?: [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    @synchronized (cache) {
        // Double-checked: a concurrent first decode of the same key must not
        // mint a second instance — consumers compare pointer identity to skip
        // reinstalling an unchanged placeholder.
        NSImage *raced = cache[key];
        if (raced) {
            return raced;
        }
        if ([key hasPrefix:@"custom:"]) {
            // A theme's live set is at most two custom images (dark +
            // light); auditioned predecessors would otherwise stay pinned by
            // their content-hash keys. A custom-referencing composite goes
            // with the entries it wraps.
            NSUInteger customs = 0;
            for (NSString *held in cache) {
                customs += [held hasPrefix:@"custom:"] ? 1 : 0;
            }
            if (customs >= 2) {
                for (NSString *stale in [cache.allKeys copy]) {
                    if ([stale hasPrefix:@"custom:"] || ([stale hasPrefix:@"dual|"]
                            && [stale containsString:@"custom:"])) {
                        [cache removeObjectForKey:stale];
                    }
                }
            }
        }
        cache[key] = image;
        return image;
    }
}

// The two sides as ONE image — the dynamic-color pattern for pixels: the
// wrapper draws whichever side the current drawing appearance asks for, so
// every consumer stays appearance-correct with no per-site dark flag. Cached,
// because consumers compare pointer identity to skip reinstalling an
// unchanged placeholder; same-valued sides skip the wrapper entirely, which
// keeps a single-mode theme (and the factory look) a plain image.
+ (NSImage *)imageForDefaultArtworkDark:(NSString *)darkValue light:(NSString *)lightValue {
    NSImage *dark = [self imageForDefaultArtwork:darkValue];
    NSImage *light = [self imageForDefaultArtwork:lightValue];
    if (dark == light) {
        return dark;
    }
    // "dual|" cannot collide with a stored value: "|" fails the value shape.
    NSString *key = [NSString stringWithFormat:@"dual|%@|%@", darkValue ?: @"", lightValue ?: @""];
    NSMutableDictionary<NSString *, NSImage *> *cache = ArtworkImageCache();
    @synchronized (cache) {
        NSImage *cached = cache[key];
        if (cached) {
            return cached;
        }
        NSSize size = NSMakeSize(MAX(dark.size.width, light.size.width),
                                 MAX(dark.size.height, light.size.height));
        NSImage *image = [NSImage imageWithSize:size flipped:NO
                                 drawingHandler:^BOOL(NSRect rect) {
            [(NSAppearance.currentDrawingAppearance.isDark ? dark : light)
                    drawInRect:rect fromRect:NSZeroRect
                    operation:NSCompositingOperationCopy fraction:1];
            return YES;
        }];
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

// The ZIP's DOS date/time as one packed word, date in the high half: seconds/2,
// minute and hour below; day, month and year-1980 above. Zero is a legal field
// but extracts as 1979-11-29, so entries carry the export's own wall time. The
// 7-bit year cannot hold a clock outside 1980-2107, so a bogus one clamps
// rather than wrapping into a stranger date than it started with.
static uint32_t VibeDOSTimestampNow(void) {
    NSDateComponents *now = [NSCalendar.currentCalendar
            components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                       NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond
              fromDate:NSDate.date];
    NSInteger year = MIN(MAX(now.year, 1980), 2107);
    uint32_t time = (uint32_t)(now.second / 2) |
                    ((uint32_t)now.minute << 5) | ((uint32_t)now.hour << 11);
    uint32_t date = (uint32_t)now.day |
                    ((uint32_t)now.month << 5) | ((uint32_t)(year - 1980) << 9);
    return (date << 16) | time;
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
    // One stamp for every entry: the archive is written in a single pass, so a
    // per-entry read would only differ when the write straddles a second.
    uint32_t stamp = VibeDOSTimestampNow();
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
        VibeAppendLE(out, stamp, 4);           // dos time/date
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
        VibeAppendLE(central, stamp, 4);       // must match the local header's
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

// Far above any real theme, low enough that a mispicked video file fails
// before the parser sees it.
static const NSUInteger kThemeJSONByteCap = 64 * 1024;
// The whole theme archive's ceiling — one JSON plus one image, with slack.
// Both the pre-parse input gate and the unzip's running inflate budget use it.
static const NSUInteger kThemeArchiveByteCap = 2 * 8 * 1024 * 1024 + 64 * 1024;

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
    NSUInteger budget = kThemeArchiveByteCap;
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
    // Entries are named by SLOT, not by where the image came from: a built-in
    // names its image by a bundled filename and a user theme by a content
    // hash, and neither reads as anything to a person opening the ZIP. Both
    // sides ride along — the dormant light half of a single-mode theme
    // included, so a mode flip after re-import still round-trips.
    NSDictionary<NSString *, NSString *> *slotNames = @{
        kFieldDefaultArtworkDark:  @"artwork_default_front",
        kFieldDefaultArtworkLight: @"artwork_default_back",
    };
    NSMutableDictionary<NSString *, NSData *> *entries = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *nameForValue = [NSMutableDictionary dictionary];
    for (NSString *key in @[kFieldDefaultArtworkDark, kFieldDefaultArtworkLight]) {
        NSString *art = SanitizedFieldValue(key, record[key]);
        // Both sides naming ONE image share its entry rather than shipping the
        // bytes twice — the common single-mode and both-sides-alike cases.
        if (nameForValue[art]) {
            names[key] = nameForValue[art];
            continue;
        }
        // A built-in's art ships in THIS build, so the export could name it
        // and stop. It travels anyway: the archive is the portable form, and
        // the build that opens it may not be this one.
        NSURL *bundled = VibeBundledArtworkURL(art);
        NSData *image = bundled ? [NSData dataWithContentsOfURL:bundled]
                : [NSData dataWithContentsOfFile:VibeCustomArtworkPath(art)];
        if (!image) {
            continue;
        }
        NSString *entry = [slotNames[key] stringByAppendingPathExtension:
                VibeArtworkFileName(art).pathExtension];
        entries[entry] = image;
        names[key] = entry;
        nameForValue[art] = entry;
    }
    if (!entries.count) {
        return nil;
    }
    entries[@"theme.json"] = [self JSONDataForRecord:record name:name artworkNames:names];
    return VibeZipData(entries);
}

+ (NSDictionary<NSString *, id> *)recordFromJSONOrArchiveData:(NSData *)data
                                                         name:(NSString **)outName
                                                        error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    BOOL isZip = data.length > 4 && bytes[0] == 'P' && bytes[1] == 'K';
    if (!isZip) {
        NSMutableDictionary *record =
                [[self recordFromJSONData:data name:outName error:error] mutableCopy];
        // JSON alone cannot carry the images: a custom reference that names
        // nothing already stored here is dangling — drop it, keep the theme.
        for (NSString *key in @[kFieldDefaultArtworkDark, kFieldDefaultArtworkLight]) {
            NSString *art = record[key];
            if ([art hasPrefix:@"custom:"] && [self defaultArtworkIsMissing:art]) {
                [record removeObjectForKey:key];
            }
        }
        return record;
    }
    if (data.length > kThemeArchiveByteCap) {
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
    // Inside an archive an image reference is the bare name of the entry
    // beside the JSON ("" is still the factory image). A custom: or bundled:
    // prefix is tolerated — a hand-edited file — and means nothing extra
    // here, since the entry is what the reference resolves against either
    // way. Read from the RAW JSON, because the sanitizer admits only the two
    // prefixed shapes and has already dropped a bare name from the record.
    NSDictionary *rawRoot = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    for (NSString *key in @[kFieldDefaultArtworkDark, kFieldDefaultArtworkLight]) {
        NSArray<NSString *> *location = ThemeJSONFieldLocations()[key];
        id group = [rawRoot isKindOfClass:NSDictionary.class] ? rawRoot[location[0]] : nil;
        NSString *art = TrimmedCappedString(
                [group isKindOfClass:NSDictionary.class] ? group[location[1]] : nil);
        if (art.length == 0) {
            continue;
        }
        NSString *entry = VibeArtworkFileName(art) ?: art;
        // Re-validated and re-hashed from the bytes, never trusting the name:
        // the stored custom:<sha1> form is the only shape the sanitizer admits
        // for a container image, and it is where EVERY archived image lands —
        // a built-in's included, since a slot-named entry says nothing about
        // which build's Resources the bytes started in.
        NSData *image = byBaseName[entry];
        NSString *stored = image ? [self storeCustomArtworkData:image error:error] : nil;
        if (stored) {
            record[key] = stored;
        } else {
            [record removeObjectForKey:key];
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
    NSDictionary *record = [self sanitizedRecord:legacyValues];
    return record.count ? record : nil;
}

#pragma mark JSON

// The theme JSON is nested: version, then name, then one object per editor
// section — window, player, info, waveform, playlist, the editor's order —
// with the section's scope dropped from each key, so windowCornerRadius
// travels as window.cornerRadius and showPlaylistArtworkColumn as
// playlist.showArtworkColumn. The flat field keys stay the stored record's
// form; each field row names its JSON home, and both directions derive
// from that.
static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *ThemeJSONGroups(void) {
    static NSDictionary *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSMutableDictionary *> *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in FieldSpecs()) {
            NSMutableDictionary *group = map[spec[kSpecGroup]]
                    ?: (map[spec[kSpecGroup]] = [NSMutableDictionary dictionary]);
            NSCAssert(!group[spec[kSpecJSONKey]], @"%@.%@ mapped twice",
                      spec[kSpecGroup], spec[kSpecJSONKey]);
            group[spec[kSpecJSONKey]] = spec[kSpecKey];
        }
        groups = [map copy];
    });
    return groups;
}

// The editor's section order — the export's group order.
static NSArray<NSString *> *ThemeJSONGroupOrder(void) {
    return @[@"window", @"player", @"info", @"waveform", @"playlist"];
}

// field key → [group, json key], the export side.
static NSDictionary<NSString *, NSArray<NSString *> *> *ThemeJSONFieldLocations(void) {
    static NSDictionary *locations;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in FieldSpecs()) {
            map[spec[kSpecKey]] = @[spec[kSpecGroup], spec[kSpecJSONKey]];
        }
        locations = [map copy];
    });
    return locations;
}

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
    // The fields sit under their group objects. Anything else — an unknown
    // group, a stray key inside one, a flat pre-group key — drops, the same
    // tolerance as an unknown field.
    NSMutableDictionary *flat = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *groups = ThemeJSONGroups();
    for (NSString *group in groups) {
        NSDictionary *sub = parsed[group];
        if (![sub isKindOfClass:NSDictionary.class]) {
            continue;
        }
        [groups[group] enumerateKeysAndObjectsUsingBlock:
                ^(NSString *jsonKey, NSString *fieldKey, BOOL *stop) {
            id value = sub[jsonKey];
            if (value) {
                flat[fieldKey] = value;
            }
        }];
    }
    return [self sanitizedRecord:flat];
}

+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record name:(NSString *)name {
    return [self JSONDataForRecord:record name:name artworkNames:nil];
}

+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                  artworkNames:(NSDictionary<NSString *, NSString *> *)artworkNames {
    NSDictionary *fields = [self sanitizedRecord:record];
    if (artworkNames.count) {
        NSMutableDictionary *renamed = [fields mutableCopy];
        [artworkNames enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *entry, BOOL *stop) {
            renamed[key] = entry;
        }];
        fields = renamed;
    }
    NSMutableDictionary<NSString *, NSMutableDictionary *> *grouped = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSArray<NSString *> *> *locations = ThemeJSONFieldLocations();
    for (NSString *fieldKey in fields) {
        NSArray<NSString *> *location = locations[fieldKey];
        NSMutableDictionary *sub = grouped[location[0]]
                ?: (grouped[location[0]] = [NSMutableDictionary dictionary]);
        sub[location[1]] = fields[fieldKey];
    }
    // Hand-assembled because NSJSONSerialization cannot order an object's
    // keys, and the file should read version, name, then the sections in the
    // editor's order. Each group still serializes through it.
    NSMutableString *out = [NSMutableString stringWithString:@"{\n  \"version\" : 1"];
    NSData *nameData = [NSJSONSerialization dataWithJSONObject:(name ?: @"")
            options:NSJSONWritingFragmentsAllowed error:NULL];
    [out appendFormat:@",\n  \"name\" : %@",
            [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding]];
    for (NSString *group in ThemeJSONGroupOrder()) {
        if (!grouped[group].count) {
            continue;  // the empty record — vibe.json — stays version + name alone
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:grouped[group]
                options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [out appendFormat:@",\n  \"%@\" : %@", group,
                [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\n  "]];
    }
    [out appendString:@"\n}"];
    return [out dataUsingEncoding:NSUTF8StringEncoding];
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

+ (NSDictionary<NSString *, id> *)sanitizedRecord:(NSDictionary<NSString *, id> *)record {
    return [[[AppTheme alloc] initWithRecord:record] dictionaryRepresentation];
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

- (NSString *)titleFontFace { return [self stringForKey:kFieldTitleFontFace]; }
- (void)setTitleFontFace:(NSString *)v { [self storeSanitized:v forKey:kFieldTitleFontFace]; }

- (CGFloat)titleFontSize { return [self floatForKey:kFieldTitleFontSize]; }
- (void)setTitleFontSize:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldTitleFontSize]; }

- (NSString *)artistFontFace { return [self stringForKey:kFieldArtistFontFace]; }
- (void)setArtistFontFace:(NSString *)v { [self storeSanitized:v forKey:kFieldArtistFontFace]; }

- (CGFloat)artistFontSize { return [self floatForKey:kFieldArtistFontSize]; }
- (void)setArtistFontSize:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldArtistFontSize]; }

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

// Exhaustive, no default: a new slot unhandled here must fail the build, not
// silently edit the title. None never arrives from a caller that guards it
// and falls through to the title's keys otherwise.
static void FontSlotKeys(VibeFontSlot slot, NSString **faceKey, NSString **sizeKey) {
    switch (slot) {
        case VibeFontSlotArtist:
            *faceKey = kFieldArtistFontFace; *sizeKey = kFieldArtistFontSize; return;
        case VibeFontSlotInfo:
            *faceKey = kFieldInfoFontFace; *sizeKey = kFieldInfoFontSize; return;
        case VibeFontSlotPlaylist:
            *faceKey = kFieldPlaylistFontFace; *sizeKey = kFieldPlaylistFontSize; return;
        case VibeFontSlotPlaylistDuration:
            *faceKey = kFieldPlaylistDurationFontFace; *sizeKey = kFieldPlaylistDurationFontSize; return;
        case VibeFontSlotNone:
        case VibeFontSlotTitle:
            *faceKey = kFieldTitleFontFace; *sizeKey = kFieldTitleFontSize; return;
    }
}

- (NSString *)fontFaceForSlot:(VibeFontSlot)slot {
    NSString *faceKey, *sizeKey;
    FontSlotKeys(slot, &faceKey, &sizeKey);
    return [self stringForKey:faceKey];
}

- (CGFloat)fontSizeForSlot:(VibeFontSlot)slot {
    NSString *faceKey, *sizeKey;
    FontSlotKeys(slot, &faceKey, &sizeKey);
    return [self floatForKey:sizeKey];
}

- (void)setFontFace:(NSString *)face size:(CGFloat)size forSlot:(VibeFontSlot)slot {
    NSString *faceKey, *sizeKey;
    FontSlotKeys(slot, &faceKey, &sizeKey);
    [self storeSanitized:face forKey:faceKey];
    [self storeSanitized:@(size) forKey:sizeKey];
}

- (NSString *)defaultArtworkForDark:(BOOL)isDark {
    return [self stringForKey:(self.isSingleMode || isDark)
            ? kFieldDefaultArtworkDark : kFieldDefaultArtworkLight];
}

- (void)setDefaultArtwork:(NSString *)v forDark:(BOOL)isDark {
    [self storeSanitized:v forKey:(self.isSingleMode || isDark)
            ? kFieldDefaultArtworkDark : kFieldDefaultArtworkLight];
}

- (NSImage *)resolvedDefaultArtworkImage {
    return [AppTheme imageForDefaultArtworkDark:[self defaultArtworkForDark:YES]
                                           light:[self defaultArtworkForDark:NO]];
}

- (BOOL)showPlaylistArtworkColumn { return [self boolForKey:kFieldShowPlaylistArtworkColumn]; }
- (void)setShowPlaylistArtworkColumn:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowPlaylistArtworkColumn]; }

- (BOOL)showPlaylistDurationColumn { return [self boolForKey:kFieldShowPlaylistDurationColumn]; }
- (void)setShowPlaylistDurationColumn:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowPlaylistDurationColumn]; }

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
        } else if (_parsedColors.count > 64) {
            // Value-keyed, so entries never go stale — but a color-well drag
            // mints a new hex per tick, and without a bound the dead ones
            // accumulate for the theme's lifetime. A reset re-parses at most
            // the two dozen live fields.
            [_parsedColors removeAllObjects];
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
