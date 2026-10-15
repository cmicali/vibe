//
//  AppTheme.m
//  Vibe
//

#import "AppTheme.h"
#import <AppKit/AppKit.h>
#import "AppThemeInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "SettingsRules.h"
#import "PlatformColor.h"
#import "NSView+DarkMode.h"

NSString *const kVibeThemeIdentifierVibe = @"vibe";

static const CGFloat kCornerRadiusMin = 0;

const NSInteger kVibeThemeRecordVersion = 2;
NSString *const kVibeThemeRecordNameKey = @"name";
NSString *const kVibeThemeRecordIdentifierKey = @"id";

// The record keys are the accessor names. Persisted: never renamed.
static NSString *const kFieldWaveformStyle = @"waveformStyle";
static NSString *const kFieldMode = @"mode";
static NSString *const kFieldWaveformTheme = @"waveformTheme";
static NSString *const kFieldWaveformShadeOverlaps = @"waveformShadeOverlaps";
static NSString *const kFieldWaveformSpectrumPalette = @"waveformSpectrumPalette";
static NSString *const kFieldWaveformGradient = @"waveformGradient";
static NSString *const kFieldWaveformCentered = @"waveformCentered";
static NSString *const kFieldWaveformPlayheadLine = @"waveformPlayheadLine";
static NSString *const kFieldWaveformBarDensity = @"waveformBarDensity";
static NSString *const kFieldWaveformBarWidth = @"waveformBarWidth";
static NSString *const kFieldWindowTint = @"windowTint";
static NSString *const kFieldDefaultArtwork = @"defaultArtwork";
static NSString *const kFieldPlaylistTint = @"playlistTint";
static NSString *const kFieldWindowBackgroundStyle = @"windowBackgroundStyle";
static NSString *const kFieldPlaylistBackgroundStyle = @"playlistBackgroundStyle";
static NSString *const kFieldWindowCornerRadius = @"windowCornerRadius";
static NSString *const kFieldShowTransportButtons = @"showTransportButtons";
static NSString *const kFieldVolumeBar = @"volumeBar";
static NSString *const kFieldVolumeKnob = @"volumeKnob";
static NSString *const kFieldShowVolumeLabels = @"showVolumeLabels";
static NSString *const kFieldVolumeLocation = @"volumeLocation";
static NSString *const kFieldVolumeVisibility = @"volumeVisibility";
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
static NSString *const kFieldCustomCornerRadius = @"customCornerRadius";
static NSString *const kFieldAppIconShape = @"appIconShape";
static NSString *const kFieldButtonGradient = @"buttonGradient";
static NSString *const kFieldPlaylistButtonGlyph = @"playlistButtonGlyph";
static NSString *const kFieldPlayButtonGlyph = @"playButtonGlyph";
static NSString *const kFieldPauseButtonGlyph = @"pauseButtonGlyph";
static NSString *const kFieldNextButtonGlyph = @"nextButtonGlyph";

NSString *const kVibeThemeImageDefaultArtworkDark  = @"defaultArtworkDark";
NSString *const kVibeThemeImageDefaultArtworkLight = @"defaultArtworkLight";
NSString *const kVibeThemeImageAppIcon = @"appIcon";
NSString *const kVibeThemeImagePlaylistButtonDark = @"playlistButtonImageDark";
NSString *const kVibeThemeImagePlaylistButtonLight = @"playlistButtonImageLight";
NSString *const kVibeThemeImagePlayButtonDark = @"playButtonImageDark";
NSString *const kVibeThemeImagePlayButtonLight = @"playButtonImageLight";
NSString *const kVibeThemeImagePauseButtonDark = @"pauseButtonImageDark";
NSString *const kVibeThemeImagePauseButtonLight = @"pauseButtonImageLight";
NSString *const kVibeThemeImageNextButtonDark = @"nextButtonImageDark";
NSString *const kVibeThemeImageNextButtonLight = @"nextButtonImageLight";

NSString *const kVibeThemeColorWaveformPlayed = @"waveformPlayedColor";
NSString *const kVibeThemeColorWaveformUnplayed = @"waveformUnplayedColor";
NSString *const kVibeThemeColorWaveformPlayhead = @"waveformPlayheadColor";
NSString *const kVibeThemeColorWaveformLow = @"waveformLowColor";
NSString *const kVibeThemeColorWaveformMid = @"waveformMidColor";
NSString *const kVibeThemeColorWaveformHigh = @"waveformHighColor";
NSString *const kVibeThemeColorWindowTint = @"windowTintColor";
NSString *const kVibeThemeColorPlaylistTint = @"playlistTintColor";
NSString *const kVibeThemeColorWindowBackground = @"windowBackgroundColor";
NSString *const kVibeThemeColorDefaultArtwork = @"defaultArtworkColor";
NSString *const kVibeThemeColorTitle = @"titleColor";
NSString *const kVibeThemeColorArtist = @"artistColor";
NSString *const kVibeThemeColorInfo = @"infoColor";
NSString *const kVibeThemeColorTime = @"timeColor";
NSString *const kVibeThemeColorPlaylistBackground = @"playlistBackgroundColor";
NSString *const kVibeThemeColorPlaylistPlayingRow = @"playlistPlayingRowColor";
NSString *const kVibeThemeColorPlaylistSelectedRow = @"playlistSelectedRowColor";
NSString *const kVibeThemeColorVolumeBar = @"volumeBarColor";
NSString *const kVibeThemeColorVolumeKnob = @"volumeKnobColor";
NSString *const kVibeThemeColorPlaylistButton = @"playlistButtonColor";
NSString *const kVibeThemeColorPlayButton = @"playButtonColor";
NSString *const kVibeThemeColorNextButton = @"nextButtonColor";
NSString *const kVibeThemeColorPlaylistNumber = @"playlistNumberColor";
NSString *const kVibeThemeColorPlaylistTitle = @"playlistTitleColor";
NSString *const kVibeThemeColorPlaylistArtist = @"playlistArtistColor";
NSString *const kVibeThemeColorPlaylistDuration = @"playlistDurationColor";
NSString *const kVibeThemeColorPlaylistPlayingRowTitle = @"playlistPlayingRowTitleColor";
NSString *const kVibeThemeColorPlaylistPlayingRowArtist = @"playlistPlayingRowArtistColor";
NSString *const kVibeThemeColorPlaylistSelectedRowTitle = @"playlistSelectedRowTitleColor";
NSString *const kVibeThemeColorPlaylistSelectedRowArtist = @"playlistSelectedRowArtistColor";

// The switch's key beside a switched pair: playlistNumberColorEnabled in
// the record, numberColorEnabled in the JSON.
static NSString *const kEnabledSuffix = @"Enabled";
static NSString *PlaylistColorEnabledKey(NSString *base) {
    return [base stringByAppendingString:kEnabledSuffix];
}

// Keyed by the art under them, so single mode leaves both sides live.
static BOOL VibeIsArtKeyedColorBase(NSString *base) {
    return [base isEqualToString:kVibeThemeColorPlaylistButton]
            || [base isEqualToString:kVibeThemeColorPlayButton]
            || [base isEqualToString:kVibeThemeColorNextButton];
}

// The button image pairs by either side: the partner an unset side draws.
static NSString *_Nullable PartnerImageKey(NSString *key) {
    static NSDictionary<NSString *, NSString *> *partners;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSArray<NSString *> *pair in @[
                @[kVibeThemeImagePlaylistButtonDark, kVibeThemeImagePlaylistButtonLight],
                @[kVibeThemeImagePlayButtonDark, kVibeThemeImagePlayButtonLight],
                @[kVibeThemeImagePauseButtonDark, kVibeThemeImagePauseButtonLight],
                @[kVibeThemeImageNextButtonDark, kVibeThemeImageNextButtonLight]]) {
            map[pair[0]] = pair[1];
            map[pair[1]] = pair[0];
        }
        partners = [map copy];
    });
    return partners[key];
}

NSString *_Nullable VibeTrimmedCappedString(id _Nullable raw) {
    if (![raw isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *trimmed = [(NSString *)raw stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 64 ? [trimmed substringToIndex:64] : trimmed;
}

// One row per field: record key, JSON home (section and section-local key),
// default and sanitizer. Every other table derives from the rows, so a field
// cannot lack a JSON home or a clamp. Color pairs default by absence.
typedef id _Nullable (^FieldSanitizer)(id _Nullable raw);

// The gate's kinds: a raw value comes out normalized and typed, or nil
// (dropped, so the default takes over).
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
        double clamped = clampRange([raw doubleValue], min, max);
        return @(wholePoints ? round(clamped) : clamped);
    };
}

static FieldSanitizer TextField(void) {
    return ^id(id raw) { return VibeTrimmedCappedString(raw); };
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

static BOOL VibeMatchesShape(NSString *_Nullable value, NSRegularExpression *shape) {
    return value.length > 0 && [shape numberOfMatchesInString:value options:0
                                                         range:NSMakeRange(0, value.length)] == 1;
}

BOOL VibeIsValidImageReference(NSString *_Nullable value) {
    static NSRegularExpression *shape;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shape = [NSRegularExpression regularExpressionWithPattern:
                @"^(custom:[0-9a-f]{40}|bundled:[a-z0-9_]+)\\.(png|jpg)$"
                options:0 error:NULL];
    });
    return VibeMatchesShape(value, shape);
}

static FieldSanitizer ImageField(void) {
    return ^id(id raw) {
        NSString *value = VibeTrimmedCappedString(raw);
        return VibeIsValidImageReference(value) ? value : nil;
    };
}

// Shape only: the draw site falls back for a symbol this macOS lacks.
static FieldSanitizer SymbolNameField(void) {
    return ^id(id raw) {
        static NSRegularExpression *shape;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            shape = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9.]{1,64}$"
                                                              options:0 error:NULL];
        });
        NSString *value = VibeTrimmedCappedString(raw);
        return VibeMatchesShape(value, shape) ? value : nil;
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

// An image field's JSON key is its record key; archiveEntry is the slot name
// its bytes travel as (AppTheme+Archive).
static NSMutableDictionary *ImageFieldSpec(NSString *key, NSString *group, NSString *archiveEntry) {
    NSMutableDictionary *spec = Field(key, group, key, @"", ImageField());
    spec[kSpecArchiveEntry] = archiveEntry;
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

// 3-Band's bands stack, so an alpha would never draw: they store opaque, and
// a well shows what draws.
static void AddOpaqueColorPair(NSMutableArray *rows, NSString *base, NSString *group, NSString *jsonBase) {
    AddColorPair(rows, base, group, jsonBase);
    FieldSanitizer color = ColorField();
    FieldSanitizer opaque = ^id(id raw) {
        return VibeHexStringFromColor([VibeColorFromHexString(color(raw)) colorWithAlphaComponent:1]);
    };
    for (NSUInteger i = rows.count - 2; i < rows.count; i++) {
        rows[i][kSpecSanitize] = [opaque copy];
        rows[i][kSpecOpaque] = @YES;
    }
}

// A playlist text color's switch, then its pair, whose rows carry the label
// pair it inherits.
static void AddSwitchedColorPair(NSMutableArray *rows, NSString *base, NSString *group,
                                 NSString *jsonBase, NSString *inheritsBase) {
    [rows addObject:Field(PlaylistColorEnabledKey(base), group,
                          [jsonBase stringByAppendingString:kEnabledSuffix], @NO, BoolField())];
    NSUInteger first = rows.count;
    AddColorPair(rows, base, group, jsonBase);
    for (NSUInteger i = first; i < rows.count; i++) {
        rows[i][kSpecInheritsBase] = inheritsBase;
    }
}

NSArray<NSDictionary *> *VibeThemeFieldSpecs(void) {
    static NSArray<NSDictionary *> *specs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *rows = [NSMutableArray array];
        NSString *window = @"window", *player = @"player", *info = @"info",
                 *volume = @"volume", *waveform = @"waveform", *playlist = @"playlist";

        [rows addObject:Field(kFieldMode, window, @"mode", SETTINGS_VALUE_THEME_MODE_DUAL,
                              LadderField(VibeNormalizedThemeMode))];
        [rows addObject:Field(kFieldWindowBackgroundStyle, window, @"backgroundStyle",
                              SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS,
                              LadderField(VibeNormalizedWindowBackgroundStyle))];
        AddColorPair(rows, kVibeThemeColorWindowBackground, window, @"backgroundColor");
        [rows addObject:Field(kFieldWindowTint, window, @"tint", SETTINGS_VALUE_WINDOW_TINT_ARTWORK,
                              LadderField(VibeNormalizedWindowTint))];
        AddColorPair(rows, kVibeThemeColorWindowTint, window, @"tintColor");
        // Whole points, matching the editor's integral readout. The switch's
        // row must follow: its off is kept only beside a stored radius
        // (storeSanitized:).
        [rows addObject:Field(kFieldWindowCornerRadius, window, @"cornerRadius",
                              @(kVibeThemeCornerRadiusDefault),
                              NumberField(kCornerRadiusMin, kVibeThemeCornerRadiusMax, YES))];
        [rows addObject:Field(kFieldCustomCornerRadius, window, @"customCornerRadius", @NO, BoolField())];
        [rows addObject:ImageFieldSpec(kVibeThemeImageAppIcon, window, @"app_icon")];
        [rows addObject:Field(kFieldAppIconShape, window, @"appIconShape", @YES, BoolField())];

        [rows addObject:Field(kFieldDefaultArtwork, player, @"defaultArtwork",
                              SETTINGS_VALUE_DEFAULT_ARTWORK_ARTWORK,
                              LadderField(VibeNormalizedDefaultArtwork))];
        AddColorPair(rows, kVibeThemeColorDefaultArtwork, player, @"defaultArtworkColor");
        // front/back rather than dark/light: exported archives carry these.
        [rows addObject:ImageFieldSpec(kVibeThemeImageDefaultArtworkDark, player, @"artwork_default_front")];
        [rows addObject:ImageFieldSpec(kVibeThemeImageDefaultArtworkLight, player, @"artwork_default_back")];
        [rows addObject:Field(kFieldPlaylistButtonGlyph, player, @"playlistButtonGlyph",
                              kVibeThemePlaylistButtonGlyphDefault, SymbolNameField())];
        AddColorPair(rows, kVibeThemeColorPlaylistButton, player, @"playlistButtonColor");
        [rows addObject:ImageFieldSpec(kVibeThemeImagePlaylistButtonDark, player, @"button_playlist_dark")];
        [rows addObject:ImageFieldSpec(kVibeThemeImagePlaylistButtonLight, player, @"button_playlist_light")];
        [rows addObject:Field(kFieldPlayButtonGlyph, player, @"playButtonGlyph",
                              kVibeThemePlayButtonGlyphDefault, SymbolNameField())];
        [rows addObject:Field(kFieldPauseButtonGlyph, player, @"pauseButtonGlyph",
                              kVibeThemePauseButtonGlyphDefault, SymbolNameField())];
        AddColorPair(rows, kVibeThemeColorPlayButton, player, @"playButtonColor");
        [rows addObject:ImageFieldSpec(kVibeThemeImagePlayButtonDark, player, @"button_play_dark")];
        [rows addObject:ImageFieldSpec(kVibeThemeImagePlayButtonLight, player, @"button_play_light")];
        [rows addObject:ImageFieldSpec(kVibeThemeImagePauseButtonDark, player, @"button_pause_dark")];
        [rows addObject:ImageFieldSpec(kVibeThemeImagePauseButtonLight, player, @"button_pause_light")];
        [rows addObject:Field(kFieldNextButtonGlyph, player, @"nextButtonGlyph",
                              kVibeThemeNextButtonGlyphDefault, SymbolNameField())];
        AddColorPair(rows, kVibeThemeColorNextButton, player, @"nextButtonColor");
        [rows addObject:ImageFieldSpec(kVibeThemeImageNextButtonDark, player, @"button_next_dark")];
        [rows addObject:ImageFieldSpec(kVibeThemeImageNextButtonLight, player, @"button_next_light")];
        [rows addObject:Field(kFieldShowTransportButtons, player, @"showTransportButtons", @YES, BoolField())];
        [rows addObject:Field(kFieldButtonGradient, player, @"buttonGradient",
                SETTINGS_VALUE_BUTTON_GRADIENT_ALWAYS, ^id(id raw) {
            // A legacy BOOL from when the field was a switch.
            if ([raw isKindOfClass:NSNumber.class]) {
                return [raw boolValue] ? SETTINGS_VALUE_BUTTON_GRADIENT_ALWAYS : SETTINGS_VALUE_BUTTON_GRADIENT_NONE;
            }
            return LadderField(VibeNormalizedButtonGradient)(raw);
        })];
        // Narrow font clamps: the labels sit in fixed frames.
        [rows addObject:Field(kFieldTitleFontFace, player, @"titleFontFace", @"", TextField())];
        [rows addObject:Field(kFieldTitleFontSize, player, @"titleFontSize",
                              @(kVibeThemeTitleFontBaseSize), NumberField(20, 26, NO))];
        AddColorPair(rows, kVibeThemeColorTitle, player, @"titleColor");
        [rows addObject:Field(kFieldArtistFontFace, player, @"artistFontFace", @"", TextField())];
        [rows addObject:Field(kFieldArtistFontSize, player, @"artistFontSize",
                              @(kVibeThemeArtistFontBaseSize), NumberField(12, 20, NO))];
        AddColorPair(rows, kVibeThemeColorArtist, player, @"artistColor");

        [rows addObject:Field(kFieldInfoFontFace, info, @"fontFace", @"", TextField())];
        [rows addObject:Field(kFieldInfoFontSize, info, @"fontSize",
                              @(kVibeThemeInfoFontBaseSize), NumberField(10, 15, NO))];
        AddColorPair(rows, kVibeThemeColorInfo, info, @"color");
        AddColorPair(rows, kVibeThemeColorTime, info, @"timeColor");

        [rows addObject:Field(kFieldVolumeBar, volume, @"bar", SETTINGS_VALUE_VOLUME_WAVEFORM,
                              LadderField(VibeNormalizedVolumeBar))];
        AddColorPair(rows, kVibeThemeColorVolumeBar, volume, @"barColor");
        [rows addObject:Field(kFieldVolumeKnob, volume, @"knob", SETTINGS_VALUE_VOLUME_KNOB_BAR,
                              LadderField(VibeNormalizedVolumeKnob))];
        AddColorPair(rows, kVibeThemeColorVolumeKnob, volume, @"knobColor");
        [rows addObject:Field(kFieldShowVolumeLabels, volume, @"showLabels", @YES, BoolField())];
        [rows addObject:Field(kFieldVolumeLocation, volume, @"location", SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT,
                              LadderField(VibeNormalizedVolumeLocation))];
        [rows addObject:Field(kFieldVolumeVisibility, volume, @"visibility",
                              SETTINGS_VALUE_VOLUME_VISIBILITY_HOVER_CLOSE,
                              LadderField(VibeNormalizedVolumeVisibility))];

        [rows addObject:Field(kFieldWaveformStyle, waveform, @"style",
                              SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT, TextField())];
        [rows addObject:Field(kFieldWaveformTheme, waveform, @"theme", SETTINGS_VALUE_WAVEFORM_THEME_MONO,
                              LadderField(VibeNormalizedWaveformTheme))];
        [rows addObject:Field(kFieldWaveformGradient, waveform, @"gradient", @YES, BoolField())];
        [rows addObject:Field(kFieldWaveformCentered, waveform, @"centered", @YES, BoolField())];
        [rows addObject:Field(kFieldWaveformBarDensity, waveform, @"barDensity",
                              @(kVibeThemeWaveformBarScaleDefault),
                              NumberField(kVibeThemeWaveformBarScaleMin, kVibeThemeWaveformBarScaleMax, NO))];
        [rows addObject:Field(kFieldWaveformBarWidth, waveform, @"barWidth",
                              @(kVibeThemeWaveformBarScaleDefault),
                              NumberField(kVibeThemeWaveformBarScaleMin, kVibeThemeWaveformBarScaleMax, NO))];
        AddColorPair(rows, kVibeThemeColorWaveformPlayed, waveform, @"playedColor");
        AddColorPair(rows, kVibeThemeColorWaveformUnplayed, waveform, @"unplayedColor");
        [rows addObject:Field(kFieldWaveformShadeOverlaps, waveform, @"shadeOverlaps", @YES, BoolField())];
        [rows addObject:Field(kFieldWaveformSpectrumPalette, waveform, @"spectrumPalette",
                              SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB,
                              LadderField(VibeNormalizedWaveformSpectrumPalette))];
        AddOpaqueColorPair(rows, kVibeThemeColorWaveformLow, waveform, @"lowColor");
        AddOpaqueColorPair(rows, kVibeThemeColorWaveformMid, waveform, @"midColor");
        AddOpaqueColorPair(rows, kVibeThemeColorWaveformHigh, waveform, @"highColor");
        [rows addObject:Field(kFieldWaveformPlayheadLine, waveform, @"playheadLine", @NO, BoolField())];
        AddColorPair(rows, kVibeThemeColorWaveformPlayhead, waveform, @"playheadColor");

        [rows addObject:Field(kFieldPlaylistBackgroundStyle, playlist, @"backgroundStyle",
                              SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS,
                              LadderField(VibeNormalizedPlaylistBackgroundStyle))];
        AddColorPair(rows, kVibeThemeColorPlaylistBackground, playlist, @"backgroundColor");
        [rows addObject:Field(kFieldPlaylistTint, playlist, @"tint", SETTINGS_VALUE_WINDOW_TINT_MONO,
                              LadderField(VibeNormalizedPlaylistTint))];
        AddColorPair(rows, kVibeThemeColorPlaylistTint, playlist, @"tintColor");
        [rows addObject:Field(kFieldPlaylistFontFace, playlist, @"fontFace", @"", TextField())];
        [rows addObject:Field(kFieldPlaylistFontSize, playlist, @"fontSize",
                              @(kVibeThemePlaylistFontBaseSize), NumberField(11, 16, NO))];
        [rows addObject:Field(kFieldPlaylistDurationFontFace, playlist, @"durationFontFace", @"", TextField())];
        [rows addObject:Field(kFieldPlaylistDurationFontSize, playlist, @"durationFontSize",
                              @(kVibeThemePlaylistDurationFontBaseSize), NumberField(10, 14, NO))];
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistNumber, playlist, @"numberColor", kVibeThemeColorArtist);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistTitle, playlist, @"titleColor", kVibeThemeColorTitle);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistArtist, playlist, @"artistColor", kVibeThemeColorArtist);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistDuration, playlist, @"durationColor", kVibeThemeColorArtist);
        AddColorPair(rows, kVibeThemeColorPlaylistPlayingRow, playlist, @"playingRowColor");
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistPlayingRowTitle, playlist, @"playingRowTitleColor",
                             kVibeThemeColorTitle);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistPlayingRowArtist, playlist, @"playingRowArtistColor",
                             kVibeThemeColorArtist);
        AddColorPair(rows, kVibeThemeColorPlaylistSelectedRow, playlist, @"selectedRowColor");
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistSelectedRowTitle, playlist, @"selectedRowTitleColor",
                             kVibeThemeColorTitle);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistSelectedRowArtist, playlist, @"selectedRowArtistColor",
                             kVibeThemeColorArtist);
        specs = [rows copy];
    });
    return specs;
}

NSDictionary<NSString *, NSDictionary *> *VibeThemeFieldSpecsByKey(void) {
    static NSDictionary<NSString *, NSDictionary *> *byKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in VibeThemeFieldSpecs()) {
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
        for (NSDictionary *spec in VibeThemeFieldSpecs()) {
            map[spec[kSpecKey]] = spec[kSpecDefault];
        }
        defaults = [map copy];
    });
    return defaults;
}

static NSArray<NSString *> *KnownFieldKeys(void) {
    return [VibeThemeFieldSpecs() valueForKey:kSpecKey];
}

NSArray<NSString *> *VibeThemeImageFieldKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *found = [NSMutableArray array];
        for (NSDictionary *spec in VibeThemeFieldSpecs()) {
            if (spec[kSpecArchiveEntry]) {
                [found addObject:spec[kSpecKey]];
            }
        }
        keys = [found copy];
    });
    return keys;
}

static id _Nullable SanitizedFieldValue(NSString *key, id _Nullable raw) {
    FieldSanitizer sanitize = VibeThemeFieldSpecsByKey()[key][kSpecSanitize];
    return sanitize ? sanitize(raw) : nil;
}

// base → [darkKey, lightKey], built once so a per-draw color read allocates
// no key.
static NSDictionary<NSString *, NSArray<NSString *> *> *ColorFieldKeysByBase(void) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<NSString *, NSMutableArray *> *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in VibeThemeFieldSpecs()) {
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

// Switched playlist pair → the label pair it inherits; nil for every other base.
NSDictionary<NSString *, NSString *> *VibeThemePlaylistColorFallbackBases(void) {
    static NSDictionary<NSString *, NSString *> *bases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in VibeThemeFieldSpecs()) {
            if (spec[kSpecInheritsBase]) {
                map[spec[kSpecColorBase]] = spec[kSpecInheritsBase];
            }
        }
        bases = [map copy];
    });
    return bases;
}

@implementation AppTheme

static VibeColor *DynamicColor(VibeColor *dark, VibeColor *light, VibeColor *fallback) {
    if (!dark && !light) {
        return fallback;
    }
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return (appearance.isDark ? dark : light) ?: fallback;
    }];
}

// A dynamic color resolves under the current appearance, which for an editor
// well is the pane's, not the side's.
static VibeColor *ResolvedForDark(VibeColor *color, BOOL isDark) {
    __block NSColor *resolved = color;
    NSAppearance *appearance = [NSAppearance appearanceNamed:
            isDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    [appearance performAsCurrentDrawingAppearance:^{
        resolved = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    return resolved ?: color;
}

// nil for a pair that is not a label pair.
static NSColor *_Nullable SemanticFallbackForBase(NSString *base) {
    if ([base isEqualToString:kVibeThemeColorTitle]) {
        return NSColor.labelColor;
    }
    if ([base isEqualToString:kVibeThemeColorArtist] || [base isEqualToString:kVibeThemeColorTime]) {
        return NSColor.secondaryLabelColor;
    }
    if ([base isEqualToString:kVibeThemeColorInfo]) {
        return NSColor.tertiaryLabelColor;
    }
    return nil;
}

// What an unset slot draws as — the one home, so a surface, its editor well
// and a popup's seed cannot disagree.
static VibeColor *DefaultColorForBase(NSString *base, BOOL isDark) {
    NSColor *semantic = SemanticFallbackForBase(base);
    if (semantic) {
        return ResolvedForDark(semantic, isDark);
    }
    if ([base isEqualToString:kVibeThemeColorWindowBackground]
            || [base isEqualToString:kVibeThemeColorPlaylistBackground]) {
        return isDark ? [NSColor colorWithWhite:0.11 alpha:0.95]
                      : [NSColor colorWithWhite:0.93 alpha:0.95];
    }
    if ([base isEqualToString:kVibeThemeColorWindowTint]
            || [base isEqualToString:kVibeThemeColorPlaylistTint]) {
        return isDark ? [NSColor colorWithWhite:0.14 alpha:0.40]
                      : [NSColor colorWithWhite:0.88 alpha:0.55];
    }
    if ([base isEqualToString:kVibeThemeColorDefaultArtwork]) {
        return isDark ? [NSColor colorWithWhite:0.14 alpha:1] : [NSColor colorWithWhite:0.88 alpha:1];
    }
    if ([base isEqualToString:kVibeThemeColorPlaylistPlayingRow]
            || [base isEqualToString:kVibeThemeColorPlaylistSelectedRow]) {
        return [(isDark ? NSColor.whiteColor : NSColor.blackColor) colorWithAlphaComponent:0.09];
    }
    // 0.55 is SymbolButton's resting strength.
    if (VibeIsArtKeyedColorBase(base)) {
        return [NSColor colorWithWhite:isDark ? 1 : 0 alpha:0.55];
    }
    if ([base isEqualToString:kVibeThemeColorVolumeBar]) {
        return ResolvedForDark(NSColor.controlAccentColor, isDark);
    }
    if ([base isEqualToString:kVibeThemeColorVolumeKnob]) {
        return NSColor.whiteColor;
    }
    if ([base isEqualToString:kVibeThemeColorWaveformPlayed]) {
        return isDark ? [NSColor colorWithRed:1 green:1 blue:1 alpha:0.75]
                      : [NSColor colorWithRed:0 green:0 blue:0 alpha:0.75];
    }
    if ([base isEqualToString:kVibeThemeColorWaveformPlayhead]) {
        return isDark ? [NSColor colorWithRed:1 green:1 blue:1 alpha:1]
                      : [NSColor colorWithRed:0 green:0 blue:0 alpha:1];
    }
    // Rekord Bin's bands (WaveformTheme).
    if ([base isEqualToString:kVibeThemeColorWaveformLow]) {
        return VibeColorFromHexString(@"#0055E1");
    }
    if ([base isEqualToString:kVibeThemeColorWaveformMid]) {
        return VibeColorFromHexString(isDark ? @"#FFA600" : @"#D97706");
    }
    if ([base isEqualToString:kVibeThemeColorWaveformHigh]) {
        return VibeColorFromHexString(isDark ? @"#FFFFFF" : @"#262626");
    }
    NSCAssert([base isEqualToString:kVibeThemeColorWaveformUnplayed], @"no color pair %@", base);
    return [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.75];
}

+ (NSArray<NSString *> *)imageKeysForButton:(NSString *)key {
    if ([key isEqualToString:kVibeThemeImagePlayButtonDark]) {
        return @[kVibeThemeImagePlayButtonDark, kVibeThemeImagePlayButtonLight,
                 kVibeThemeImagePauseButtonDark, kVibeThemeImagePauseButtonLight];
    }
    if ([key isEqualToString:kVibeThemeImageNextButtonDark]) {
        return @[kVibeThemeImageNextButtonDark, kVibeThemeImageNextButtonLight];
    }
    return @[kVibeThemeImagePlaylistButtonDark, kVibeThemeImagePlaylistButtonLight];
}

- (void)setGlyph:(NSString *)glyph forButtonImageKey:(NSString *)key {
    if ([key isEqualToString:kVibeThemeImagePlayButtonDark]) {
        self.playButtonGlyph = glyph;
        self.pauseButtonGlyph = VibePauseGlyphForPlayGlyph(glyph);
    } else if ([key isEqualToString:kVibeThemeImageNextButtonDark]) {
        self.nextButtonGlyph = glyph;
    } else {
        self.playlistButtonGlyph = glyph;
    }
    for (NSString *imageKey in [AppTheme imageKeysForButton:key]) {
        [self setImageReference:@"" forKey:imageKey];
    }
}

- (VibeColor *)resolvedColorForBase:(NSString *)base {
    return DynamicColor([self colorForBase:base dark:YES], [self colorForBase:base dark:NO],
                        SemanticFallbackForBase(base));
}

- (VibeColor *)resolvedTitleColor { return [self resolvedColorForBase:kVibeThemeColorTitle]; }
- (VibeColor *)resolvedArtistColor { return [self resolvedColorForBase:kVibeThemeColorArtist]; }
- (VibeColor *)resolvedInfoColor { return [self resolvedColorForBase:kVibeThemeColorInfo]; }
- (VibeColor *)resolvedTimeColor { return [self resolvedColorForBase:kVibeThemeColorTime]; }

- (VibeColor *)displayColorForBase:(NSString *)base dark:(BOOL)isDark {
    VibeColor *color = [self colorForBase:base dark:isDark];
    if (color) {
        return color;
    }
    // A switched playlist pair's unset side shows the label pair it inherits.
    NSString *inherited = VibeThemePlaylistColorFallbackBases()[base];
    return inherited ? [self displayColorForBase:inherited dark:isDark]
                     : DefaultColorForBase(base, isDark);
}

+ (BOOL)storesOpaqueColorBase:(NSString *)base {
    return [VibeThemeFieldSpecsByKey()[[base stringByAppendingString:@"Dark"]][kSpecOpaque] boolValue];
}

- (BOOL)playlistColorEnabledForBase:(NSString *)base {
    return [self boolForKey:PlaylistColorEnabledKey(base)];
}

- (void)setPlaylistColorEnabled:(BOOL)enabled forBase:(NSString *)base {
    [self storeSanitized:@(enabled) forKey:PlaylistColorEnabledKey(base)];
}

- (VibeColor *)resolvedPlaylistColorForBase:(NSString *)base {
    NSString *inherited = VibeThemePlaylistColorFallbackBases()[base];
    NSCAssert(inherited, @"not a switched playlist pair: %@", base);
    VibeColor *fallback = [self resolvedColorForBase:inherited];
    if (![self playlistColorEnabledForBase:base]) {
        return fallback;
    }
    return DynamicColor([self colorForBase:base dark:YES], [self colorForBase:base dark:NO], fallback);
}

#pragma mark Built-ins

// Resources/Themes/<identifier>.json through the import gate; vibe first,
// the rest alphabetical.
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
        // vibe is the store's snap-back anchor and must exist whatever the
        // bundle holds.
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

#pragma mark Names and migration

+ (NSString *)dedupedThemeName:(NSString *)candidate
                      fallback:(NSString *)fallback
                 existingNames:(NSArray<NSString *> *)existingNames {
    NSString *base = VibeTrimmedCappedString(candidate);
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

+ (NSDictionary<NSString *, id> *)recordUpgradedFromVersion1:(NSDictionary<NSString *, id> *)record {
    if (![record[kFieldWindowBackgroundStyle] isEqual:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID]) {
        return record;
    }
    NSMutableDictionary *upgraded = [record mutableCopy];
    upgraded[kFieldWindowBackgroundStyle] = SETTINGS_VALUE_WINDOW_BACKGROUND_FROSTED;
    return upgraded;
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
    // The switch postdates the radius: a record naming a radius but not the
    // switch chose that shape, so it reads as custom.
    if (_fields[kFieldWindowCornerRadius]
            && !SanitizedFieldValue(kFieldCustomCornerRadius, record[kFieldCustomCornerRadius])) {
        _fields[kFieldCustomCornerRadius] = @YES;
    }
    // Wiggle MC is Wiggle grounded, whatever version a record claims: a 1.15
    // beta stored and exported it at version 2.
    if ([record[kFieldWaveformStyle] isEqual:SETTINGS_VALUE_WAVEFORM_STYLE_LEGACY_WIGGLE_MC]) {
        _fields[kFieldWaveformStyle] = SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE;
        _fields[kFieldWaveformCentered] = @NO;
    }
}

+ (NSDictionary<NSString *, id> *)sanitizedRecord:(NSDictionary<NSString *, id> *)record {
    return [[[AppTheme alloc] initWithRecord:record] dictionaryRepresentation];
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    return [_fields copy];
}

// Keeps only a value differing from the default — except the custom-radius
// switch's off beside a stored radius, which dropped would read back as
// custom (replaceWithRecord:).
- (void)storeSanitized:(id)raw forKey:(NSString *)key {
    id value = SanitizedFieldValue(key, raw);
    BOOL keep = [key isEqualToString:kFieldCustomCornerRadius]
            && _fields[kFieldWindowCornerRadius] != nil;
    if (!value || (!keep && [value isEqual:FieldDefaults()[key]])) {
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

- (BOOL)waveformCentered { return [self boolForKey:kFieldWaveformCentered]; }
- (void)setWaveformCentered:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldWaveformCentered]; }

- (BOOL)waveformShadeOverlaps { return [self boolForKey:kFieldWaveformShadeOverlaps]; }
- (void)setWaveformShadeOverlaps:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldWaveformShadeOverlaps]; }

- (NSString *)waveformSpectrumPalette { return [self stringForKey:kFieldWaveformSpectrumPalette]; }
- (void)setWaveformSpectrumPalette:(NSString *)v { [self storeSanitized:v forKey:kFieldWaveformSpectrumPalette]; }

- (BOOL)waveformPlayheadLine { return [self boolForKey:kFieldWaveformPlayheadLine]; }
- (void)setWaveformPlayheadLine:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldWaveformPlayheadLine]; }

- (double)waveformBarDensity { return [self floatForKey:kFieldWaveformBarDensity]; }
- (void)setWaveformBarDensity:(double)v { [self storeSanitized:@(v) forKey:kFieldWaveformBarDensity]; }
- (double)waveformBarWidth { return [self floatForKey:kFieldWaveformBarWidth]; }
- (void)setWaveformBarWidth:(double)v { [self storeSanitized:@(v) forKey:kFieldWaveformBarWidth]; }

- (NSString *)windowTint { return [self stringForKey:kFieldWindowTint]; }
- (void)setWindowTint:(NSString *)v { [self storeSanitized:v forKey:kFieldWindowTint]; }

- (NSString *)defaultArtwork { return [self stringForKey:kFieldDefaultArtwork]; }
- (void)setDefaultArtwork:(NSString *)v { [self storeSanitized:v forKey:kFieldDefaultArtwork]; }

- (NSString *)playlistTint { return [self stringForKey:kFieldPlaylistTint]; }
- (void)setPlaylistTint:(NSString *)v { [self storeSanitized:v forKey:kFieldPlaylistTint]; }

- (NSString *)windowBackgroundStyle { return [self stringForKey:kFieldWindowBackgroundStyle]; }
- (void)setWindowBackgroundStyle:(NSString *)v { [self storeSanitized:v forKey:kFieldWindowBackgroundStyle]; }

- (NSString *)playlistBackgroundStyle { return [self stringForKey:kFieldPlaylistBackgroundStyle]; }
- (void)setPlaylistBackgroundStyle:(NSString *)v { [self storeSanitized:v forKey:kFieldPlaylistBackgroundStyle]; }

- (CGFloat)windowCornerRadius { return [self floatForKey:kFieldWindowCornerRadius]; }
- (void)setWindowCornerRadius:(CGFloat)v { [self storeSanitized:@(v) forKey:kFieldWindowCornerRadius]; }

- (BOOL)customCornerRadius { return [self boolForKey:kFieldCustomCornerRadius]; }
- (void)setCustomCornerRadius:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldCustomCornerRadius]; }

- (CGFloat)resolvedWindowCornerRadius {
    return self.customCornerRadius ? self.windowCornerRadius : kVibeThemeCornerRadiusDefault;
}

- (BOOL)appIconShape { return [self boolForKey:kFieldAppIconShape]; }
- (void)setAppIconShape:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldAppIconShape]; }

- (NSString *)buttonGradient { return [self stringForKey:kFieldButtonGradient]; }
- (void)setButtonGradient:(NSString *)v { [self storeSanitized:v forKey:kFieldButtonGradient]; }

- (NSString *)playlistButtonGlyph { return [self stringForKey:kFieldPlaylistButtonGlyph]; }
- (void)setPlaylistButtonGlyph:(NSString *)v { [self storeSanitized:v forKey:kFieldPlaylistButtonGlyph]; }

- (NSString *)playButtonGlyph { return [self stringForKey:kFieldPlayButtonGlyph]; }
- (void)setPlayButtonGlyph:(NSString *)v { [self storeSanitized:v forKey:kFieldPlayButtonGlyph]; }

- (NSString *)pauseButtonGlyph { return [self stringForKey:kFieldPauseButtonGlyph]; }
- (void)setPauseButtonGlyph:(NSString *)v { [self storeSanitized:v forKey:kFieldPauseButtonGlyph]; }

- (NSString *)nextButtonGlyph { return [self stringForKey:kFieldNextButtonGlyph]; }
- (void)setNextButtonGlyph:(NSString *)v { [self storeSanitized:v forKey:kFieldNextButtonGlyph]; }

- (BOOL)showTransportButtons { return [self boolForKey:kFieldShowTransportButtons]; }
- (void)setShowTransportButtons:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowTransportButtons]; }

- (NSString *)volumeBar { return [self stringForKey:kFieldVolumeBar]; }
- (void)setVolumeBar:(NSString *)v { [self storeSanitized:v forKey:kFieldVolumeBar]; }

- (NSString *)volumeKnob { return [self stringForKey:kFieldVolumeKnob]; }
- (void)setVolumeKnob:(NSString *)v { [self storeSanitized:v forKey:kFieldVolumeKnob]; }

- (BOOL)showVolumeLabels { return [self boolForKey:kFieldShowVolumeLabels]; }
- (void)setShowVolumeLabels:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowVolumeLabels]; }

- (NSString *)volumeLocation { return [self stringForKey:kFieldVolumeLocation]; }
- (void)setVolumeLocation:(NSString *)v { [self storeSanitized:v forKey:kFieldVolumeLocation]; }

- (NSString *)volumeVisibility { return [self stringForKey:kFieldVolumeVisibility]; }
- (void)setVolumeVisibility:(NSString *)v { [self storeSanitized:v forKey:kFieldVolumeVisibility]; }

// Exhaustive, no default: an unhandled new slot must fail the build.
static void FontSlotKeys(VibeFontSlot slot, NSString **faceKey, NSString **sizeKey) {
    switch (slot) {
        case VibeFontSlotTitle:
            *faceKey = kFieldTitleFontFace; *sizeKey = kFieldTitleFontSize; return;
        case VibeFontSlotArtist:
            *faceKey = kFieldArtistFontFace; *sizeKey = kFieldArtistFontSize; return;
        case VibeFontSlotInfo:
            *faceKey = kFieldInfoFontFace; *sizeKey = kFieldInfoFontSize; return;
        case VibeFontSlotPlaylist:
            *faceKey = kFieldPlaylistFontFace; *sizeKey = kFieldPlaylistFontSize; return;
        case VibeFontSlotPlaylistDuration:
            *faceKey = kFieldPlaylistDurationFontFace; *sizeKey = kFieldPlaylistDurationFontSize; return;
        case VibeFontSlotNone:
            *faceKey = nil; *sizeKey = nil; return;
    }
}

- (NSString *)fontFaceForSlot:(VibeFontSlot)slot {
    NSString *faceKey = nil, *sizeKey = nil;
    FontSlotKeys(slot, &faceKey, &sizeKey);
    return faceKey ? [self stringForKey:faceKey] : @"";
}

- (CGFloat)fontSizeForSlot:(VibeFontSlot)slot {
    NSString *faceKey = nil, *sizeKey = nil;
    FontSlotKeys(slot, &faceKey, &sizeKey);
    return sizeKey ? [self floatForKey:sizeKey] : 0;
}

- (void)setFontFace:(NSString *)face size:(CGFloat)size forSlot:(VibeFontSlot)slot {
    NSString *faceKey = nil, *sizeKey = nil;
    FontSlotKeys(slot, &faceKey, &sizeKey);
    if (!faceKey) {
        return;
    }
    [self storeSanitized:face forKey:faceKey];
    [self storeSanitized:@(size) forKey:sizeKey];
}

- (NSString *)imageKeyForKey:(NSString *)key {
    if (self.isSingleMode && [key isEqualToString:kVibeThemeImageDefaultArtworkLight]) {
        return kVibeThemeImageDefaultArtworkDark;
    }
    NSAssert([VibeThemeImageFieldKeys() containsObject:key], @"no image field %@", key);
    return key;
}

- (NSString *)imageReferenceForKey:(NSString *)key {
    return [self stringForKey:[self imageKeyForKey:key]];
}

- (void)setImageReference:(NSString *)reference forKey:(NSString *)key {
    [self storeSanitized:reference forKey:[self imageKeyForKey:key]];
}

- (NSImage *)customImageForKey:(NSString *)key {
    NSString *reference = [self imageReferenceForKey:key];
    if (reference.length == 0 || [AppTheme referenceIsMissing:reference]) {
        return nil;
    }
    return [AppTheme imageForReference:reference];
}

- (NSImage *)buttonImageForKey:(NSString *)key {
    return [self customImageForKey:key] ?: [self customImageForKey:PartnerImageKey(key)];
}

- (NSImage *)resolvedDefaultArtworkImage {
    NSString *mode = self.defaultArtwork;
    if ([mode isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_CUSTOM]) {
        return [AppTheme imageForDefaultArtworkColorDark:[self displayColorForBase:kVibeThemeColorDefaultArtwork dark:YES]
                                                   light:[self displayColorForBase:kVibeThemeColorDefaultArtwork dark:NO]];
    }
    if (![mode isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_ARTWORK]) {
        return [AppTheme clearDefaultArtworkImage];
    }
    return [AppTheme imageForDefaultArtworkDark:[self imageReferenceForKey:kVibeThemeImageDefaultArtworkDark]
                                           light:[self imageReferenceForKey:kVibeThemeImageDefaultArtworkLight]];
}

- (NSImage *)defaultArtworkImageForAppearance:(NSAppearance *)appearance {
    if (![self.defaultArtwork isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_ARTWORK]) {
        return nil;
    }
    return [AppTheme imageForReference:[self imageReferenceForKey:appearance.isDark ? kVibeThemeImageDefaultArtworkDark
                                                                                     : kVibeThemeImageDefaultArtworkLight]];
}

#pragma mark Color pairs

// Single mode reads and writes the dark slot from either side; the light
// halves stay dormant, so flipping back to dual restores them.
- (NSString *)colorKeyForBase:(NSString *)base dark:(BOOL)isDark {
    return ColorFieldKey(base, (self.isSingleMode && !VibeIsArtKeyedColorBase(base)) ? YES : isDark);
}

- (VibeColor *)colorForBase:(NSString *)base dark:(BOOL)isDark {
    NSString *hex = _fields[[self colorKeyForBase:base dark:isDark]];
    if (!hex) {
        return nil;
    }
    VibeColor *color = _parsedColors[hex];
    if (!color) {
        color = VibeColorFromHexString(hex);
        if (!_parsedColors) {
            _parsedColors = [NSMutableDictionary dictionary];
        } else if (_parsedColors.count > 64) {
            // A color-well drag mints a new hex per tick.
            [_parsedColors removeAllObjects];
        }
        _parsedColors[hex] = color;
    }
    return color;
}

- (BOOL)isSingleMode {
    return [self.mode isEqualToString:SETTINGS_VALUE_THEME_MODE_SINGLE];
}

- (void)setColor:(VibeColor *)color forBase:(NSString *)base dark:(BOOL)isDark {
    [self storeSanitized:VibeHexStringFromColor(color) forKey:[self colorKeyForBase:base dark:isDark]];
}

- (NSAppearance *)requiredWindowAppearance {
    return self.isSingleMode
            ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
}

@end
