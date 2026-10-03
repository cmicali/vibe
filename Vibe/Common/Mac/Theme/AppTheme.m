//
//  AppTheme.m
//  Vibe
//

#import "AppTheme.h"
#import <AppKit/AppKit.h>
#import "AppThemeInternal.h"
#import "PlatformImage.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "SettingsRules.h"
#import "PlatformColor.h"
#import "NSView+DarkMode.h"
#import "NSURL+Hash.h"

NSString *const kVibeThemeIdentifierVibe = @"vibe";

static const CGFloat kCornerRadiusMin = 0;

NSString *const kVibeThemeRecordNameKey = @"name";
NSString *const kVibeThemeRecordIdentifierKey = @"id";

// The record keys are the accessor names. Persisted: never renamed.
static NSString *const kFieldWaveformStyle = @"waveformStyle";
static NSString *const kFieldMode = @"mode";
static NSString *const kFieldWaveformTheme = @"waveformTheme";
static NSString *const kFieldWaveformGradient = @"waveformGradient";
static NSString *const kFieldWaveformPlayheadLine = @"waveformPlayheadLine";
static NSString *const kFieldWaveformBarDensity = @"waveformBarDensity";
static NSString *const kFieldWaveformBarWidth = @"waveformBarWidth";
static NSString *const kFieldWindowTint = @"windowTint";
static NSString *const kFieldPlaylistTint = @"playlistTint";
static NSString *const kFieldWindowBackgroundStyle = @"windowBackgroundStyle";
static NSString *const kFieldPlaylistBackgroundStyle = @"playlistBackgroundStyle";
static NSString *const kFieldWindowCornerRadius = @"windowCornerRadius";
static NSString *const kFieldShowTransportButtons = @"showTransportButtons";
static NSString *const kFieldShowStatusIcons = @"showStatusIcons";
static NSString *const kFieldShowTimeLabels = @"showTimeLabels";
static NSString *const kFieldShowFileInfo = @"showFileInfo";
static NSString *const kFieldShowRemainingTime = @"showRemainingTime";
static NSString *const kFieldShowBPM = @"showBPM";
static NSString *const kFieldShowKey = @"showKey";
static NSString *const kFieldKeyColorsEnabled = @"keyColorsEnabled";
static NSString *const kFieldKeyNotation = @"keyNotation";
static NSString *const kFieldVolumeBar = @"volumeBar";
static NSString *const kFieldVolumeKnob = @"volumeKnob";
static NSString *const kFieldShowVolumeLabels = @"showVolumeLabels";
static NSString *const kFieldVolumeLocation = @"volumeLocation";
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
static NSString *const kFieldShowPlaylistNumberColumn = @"showPlaylistNumberColumn";
static NSString *const kFieldShowPlaylistArtworkColumn = @"showPlaylistArtworkColumn";
static NSString *const kFieldShowPlaylistDurationColumn = @"showPlaylistDurationColumn";
static NSString *const kFieldCustomCornerRadius = @"customCornerRadius";
static NSString *const kFieldDockIcon = @"dockIcon";
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
NSString *const kVibeThemeColorWindowTint = @"windowTintColor";
NSString *const kVibeThemeColorPlaylistTint = @"playlistTintColor";
NSString *const kVibeThemeColorWindowBackground = @"windowBackgroundColor";
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

static NSString *_Nullable TrimmedCappedString(id _Nullable raw) {
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

static NSString *const kSpecKey = @"key";
static NSString *const kSpecGroup = @"group";
static NSString *const kSpecJSONKey = @"json";
static NSString *const kSpecDefault = @"default";
static NSString *const kSpecColorBase = @"colorBase";
static NSString *const kSpecInheritsBase = @"inheritsBase";
static NSString *const kSpecArchiveEntry = @"archiveEntry";
static NSString *const kSpecSanitize = @"sanitize";

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

static BOOL VibeMatchesShape(NSString *_Nullable value, NSRegularExpression *shape) {
    return value.length > 0 && [shape numberOfMatchesInString:value options:0
                                                         range:NSMakeRange(0, value.length)] == 1;
}

static BOOL VibeIsValidImageReference(NSString *_Nullable value) {
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
        NSString *value = TrimmedCappedString(raw);
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
        NSString *value = TrimmedCappedString(raw);
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

// A playlist column's switch, then its pair, whose rows carry the label pair
// it inherits.
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

static NSArray<NSDictionary *> *FieldSpecs(void) {
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
        [rows addObject:Field(kFieldDockIcon, window, @"dockIcon", SETTINGS_VALUE_DOCK_ICON_ALBUM_ART,
                              LadderField(VibeNormalizedDockIcon))];
        [rows addObject:Field(kFieldAppIconShape, window, @"appIconShape", @YES, BoolField())];

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

        [rows addObject:Field(kFieldShowStatusIcons, info, @"showStatusIcons", @YES, BoolField())];
        [rows addObject:Field(kFieldShowTimeLabels, info, @"showTimeLabels", @YES, BoolField())];
        [rows addObject:Field(kFieldShowFileInfo, info, @"showFileInfo", @YES, BoolField())];
        [rows addObject:Field(kFieldInfoFontFace, info, @"fontFace", @"", TextField())];
        [rows addObject:Field(kFieldInfoFontSize, info, @"fontSize",
                              @(kVibeThemeInfoFontBaseSize), NumberField(10, 15, NO))];
        AddColorPair(rows, kVibeThemeColorInfo, info, @"color");
        AddColorPair(rows, kVibeThemeColorTime, info, @"timeColor");
        [rows addObject:Field(kFieldShowRemainingTime, info, @"showRemainingTime", @NO, BoolField())];
        [rows addObject:Field(kFieldShowBPM, info, @"showBPM", @YES, BoolField())];
        [rows addObject:Field(kFieldShowKey, info, @"showKey", @YES, BoolField())];
        [rows addObject:Field(kFieldKeyNotation, info, @"keyNotation", SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
                              LadderField(VibeNormalizedKeyNotation))];
        [rows addObject:Field(kFieldKeyColorsEnabled, info, @"keyColorsEnabled", @NO, BoolField())];

        [rows addObject:Field(kFieldVolumeBar, volume, @"bar", SETTINGS_VALUE_VOLUME_WAVEFORM,
                              LadderField(VibeNormalizedVolumeBar))];
        AddColorPair(rows, kVibeThemeColorVolumeBar, volume, @"barColor");
        [rows addObject:Field(kFieldVolumeKnob, volume, @"knob", SETTINGS_VALUE_VOLUME_KNOB_BAR,
                              LadderField(VibeNormalizedVolumeKnob))];
        AddColorPair(rows, kVibeThemeColorVolumeKnob, volume, @"knobColor");
        [rows addObject:Field(kFieldShowVolumeLabels, volume, @"showLabels", @YES, BoolField())];
        [rows addObject:Field(kFieldVolumeLocation, volume, @"location", SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT,
                              LadderField(VibeNormalizedVolumeLocation))];

        [rows addObject:Field(kFieldWaveformStyle, waveform, @"style",
                              SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT, TextField())];
        [rows addObject:Field(kFieldWaveformTheme, waveform, @"theme", SETTINGS_VALUE_WAVEFORM_THEME_MONO,
                              LadderField(VibeNormalizedWaveformTheme))];
        [rows addObject:Field(kFieldWaveformGradient, waveform, @"gradient", @YES, BoolField())];
        [rows addObject:Field(kFieldWaveformBarDensity, waveform, @"barDensity",
                              @(kVibeThemeWaveformBarScaleDefault),
                              NumberField(kVibeThemeWaveformBarScaleMin, kVibeThemeWaveformBarScaleMax, NO))];
        [rows addObject:Field(kFieldWaveformBarWidth, waveform, @"barWidth",
                              @(kVibeThemeWaveformBarScaleDefault),
                              NumberField(kVibeThemeWaveformBarScaleMin, kVibeThemeWaveformBarScaleMax, NO))];
        AddColorPair(rows, kVibeThemeColorWaveformPlayed, waveform, @"playedColor");
        AddColorPair(rows, kVibeThemeColorWaveformUnplayed, waveform, @"unplayedColor");
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
        [rows addObject:Field(kFieldShowPlaylistNumberColumn, playlist, @"showNumberColumn", @YES, BoolField())];
        [rows addObject:Field(kFieldShowPlaylistArtworkColumn, playlist, @"showArtworkColumn", @YES, BoolField())];
        [rows addObject:Field(kFieldShowPlaylistDurationColumn, playlist, @"showDurationColumn", @YES, BoolField())];
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistNumber, playlist, @"numberColor", kVibeThemeColorArtist);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistTitle, playlist, @"titleColor", kVibeThemeColorTitle);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistArtist, playlist, @"artistColor", kVibeThemeColorArtist);
        AddSwitchedColorPair(rows, kVibeThemeColorPlaylistDuration, playlist, @"durationColor", kVibeThemeColorArtist);
        AddColorPair(rows, kVibeThemeColorPlaylistPlayingRow, playlist, @"playingRowColor");
        AddColorPair(rows, kVibeThemeColorPlaylistSelectedRow, playlist, @"selectedRowColor");
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

static NSArray<NSString *> *ImageFieldKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *found = [NSMutableArray array];
        for (NSDictionary *spec in FieldSpecs()) {
            if (spec[kSpecArchiveEntry]) {
                [found addObject:spec[kSpecKey]];
            }
        }
        keys = [found copy];
    });
    return keys;
}

static id _Nullable SanitizedFieldValue(NSString *key, id _Nullable raw) {
    FieldSanitizer sanitize = FieldSpecsByKey()[key][kSpecSanitize];
    return sanitize ? sanitize(raw) : nil;
}

// base → [darkKey, lightKey], built once so a per-draw color read allocates
// no key.
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

// Column pair → the label pair it inherits; nil for every other base.
static NSDictionary<NSString *, NSString *> *PlaylistColorFallbackBases(void) {
    static NSDictionary<NSString *, NSString *> *bases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *spec in FieldSpecs()) {
            if (spec[kSpecInheritsBase]) {
                map[spec[kSpecColorBase]] = spec[kSpecInheritsBase];
            }
        }
        bases = [map copy];
    });
    return bases;
}

@implementation AppTheme {
    NSMutableDictionary<NSString *, id> *_fields;
    // Keyed by hex VALUE, so it never goes stale. Rows read fills per draw.
    NSMutableDictionary<NSString *, VibeColor *> *_parsedColors;
}

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
    // A column's unset side shows the label pair it inherits.
    NSString *inherited = PlaylistColorFallbackBases()[base];
    return inherited ? [self displayColorForBase:inherited dark:isDark]
                     : DefaultColorForBase(base, isDark);
}

- (BOOL)playlistColorEnabledForBase:(NSString *)base {
    return [self boolForKey:PlaylistColorEnabledKey(base)];
}

- (void)setPlaylistColorEnabled:(BOOL)enabled forBase:(NSString *)base {
    [self storeSanitized:@(enabled) forKey:PlaylistColorEnabledKey(base)];
}

- (VibeColor *)resolvedPlaylistColorForBase:(NSString *)base {
    NSString *inherited = PlaylistColorFallbackBases()[base];
    NSCAssert(inherited, @"not a playlist column pair: %@", base);
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

#pragma mark Images

+ (NSArray<NSString *> *)imageFieldKeys {
    return ImageFieldKeys();
}

+ (NSString *)archiveEntryStemForImageKey:(NSString *)key {
    return FieldSpecsByKey()[key][kSpecArchiveEntry];
}

// Never renamed: every install's images are already there.
static NSString *VibeCustomImageDirectory(void) {
#if DEBUG
    // Test seam: the unsandboxed host-less suite would otherwise write into
    // the real ~/Library.
    const char *override = getenv("VIBE_THEME_ART_DIR");
    if (override) {
        return [NSString stringWithUTF8String:override];
    }
#endif
    NSString *support = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:
            NSBundle.mainBundle.bundleIdentifier ?: @"Vibe"]
            stringByAppendingPathComponent:@"ThemeArt"];
}

// The file name after either prefix, or nil.
static NSString *_Nullable VibeImageFileName(NSString *_Nullable reference) {
    for (NSString *prefix in @[@"custom:", @"bundled:"]) {
        if ([reference hasPrefix:prefix]) {
            return [reference substringFromIndex:prefix.length];
        }
    }
    return nil;
}

static NSString *_Nullable VibeCustomImagePath(NSString *_Nullable reference) {
    if (![reference hasPrefix:@"custom:"]) {
        return nil;
    }
    return [VibeCustomImageDirectory() stringByAppendingPathComponent:VibeImageFileName(reference)];
}

// nil also for a name THIS build does not ship, which lets an archive's copy
// stand in. Callers pass a sanitized value: the shape gate keeps a crafted
// name out of the bundle lookup.
static NSURL *_Nullable VibeBundledImageURL(NSString *_Nullable reference) {
    if (![reference hasPrefix:@"bundled:"]) {
        return nil;
    }
    NSString *file = VibeImageFileName(reference);
    return [[NSBundle bundleForClass:AppTheme.class]
            URLForResource:file.stringByDeletingPathExtension
             withExtension:file.pathExtension subdirectory:@"Themes"];
}

// Returns the extension, or nil with the reason.
static const NSInteger kImagePixelCap = 4096;
static const NSInteger kImagePixelFloor = 64;

static NSString *VibeValidatedImageExtension(NSData *data, NSString **outReason) {
    *outReason = nil;
    if (data.length == 0 || data.length > kVibeThemeImageByteCap) {
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
    if (width < kImagePixelFloor || width > kImagePixelCap || pixels.width != pixels.height) {
        *outReason = @"the image must be square, between 64 and 4096 pixels";
        return nil;
    }
    return ext;
}

+ (BOOL)referenceIsMissing:(NSString *)reference {
    if (!VibeIsValidImageReference(reference)) {
        return NO;
    }
    if ([reference hasPrefix:@"bundled:"]) {
        return VibeBundledImageURL(reference) == nil;
    }
    return ![NSFileManager.defaultManager fileExistsAtPath:VibeCustomImagePath(reference)];
}

+ (NSString *)storeCustomImageData:(NSData *)data error:(NSError **)error {
    NSString *reason = nil;
    NSString *ext = VibeValidatedImageExtension(data, &reason);
    if (!ext) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppTheme" code:3
                    userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return nil;
    }
    NSString *hex = [data sha1Hex];
    NSString *directory = VibeCustomImageDirectory();
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

+ (NSSet<NSString *> *)customImageFilesInRecord:(NSDictionary<NSString *, id> *)record {
    NSMutableSet<NSString *> *files = [NSMutableSet set];
    for (NSString *key in ImageFieldKeys()) {
        NSString *value = [record[key] isKindOfClass:NSString.class] ? record[key] : nil;
        if ([value hasPrefix:@"custom:"]) {
            [files addObject:VibeImageFileName(value)];
        }
    }
    return files;
}

+ (void)removeCustomImageFilesUnreferencedByRecords:(NSArray<NSDictionary *> *)records {
    NSMutableSet<NSString *> *referenced = [NSMutableSet set];
    for (NSDictionary *record in records) {
        [referenced unionSet:[self customImageFilesInRecord:record]];
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *directory = VibeCustomImageDirectory();
    for (NSString *file in [manager contentsOfDirectoryAtPath:directory error:NULL]) {
        if (![referenced containsObject:file]) {
            [manager removeItemAtPath:[directory stringByAppendingPathComponent:file]
                                error:NULL];
        }
    }
}

// The one read behind the image cache and the archive; nil when nothing
// holds the name.
+ (NSData *)dataForReference:(NSString *)reference {
    NSURL *bundled = VibeBundledImageURL(reference);
    if (bundled) {
        return [NSData dataWithContentsOfURL:bundled];
    }
    NSString *path = VibeCustomImagePath(reference);
    return path ? [NSData dataWithContentsOfFile:path] : nil;
}

static NSMutableDictionary<NSString *, NSImage *> *ImageCache(void) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

+ (NSImage *)imageForReference:(NSString *)reference {
    NSMutableDictionary<NSString *, NSImage *> *cache = ImageCache();
    NSString *key = VibeIsValidImageReference(reference) ? reference : @"";
    @synchronized (cache) {
        NSImage *cached = cache[key];
        if (cached) {
            return cached;
        }
    }
    // Read and decode outside the lock, so a first decode stalls no other
    // consumer. Synchronous on purpose: the caller needs an image now, once
    // per key. Bounded to the mac's display-art size, so a 4096px original is
    // never pinned full-size for the app's lifetime.
    NSData *data = [self dataForReference:key];
    NSImage *image = data ? VibeDecodedImageWithData(data, kVibeArchivedDisplayArtDimension) : nil;
    if (!image && key.length) {
        // TRAP: never cache the fallback under the missing image's key. Names
        // are content hashes, so re-storing that image reuses the key and the
        // theme would draw the factory record until relaunch.
        return [self imageForReference:@""];
    }
    // The blank square is for the host-less tests, which have no asset
    // catalog.
    image = image ?: [NSImage imageNamed:@"record-bg"]
            ?: [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    @synchronized (cache) {
        // Double-checked: consumers compare pointer identity to skip
        // reinstalling an unchanged placeholder.
        NSImage *raced = cache[key];
        if (raced) {
            return raced;
        }
        if ([key hasPrefix:@"custom:"]) {
            // A live theme needs at most one custom image per field; past
            // that, drop them (and composites wrapping them) so auditioned
            // images are not pinned forever.
            NSUInteger customs = 0;
            for (NSString *held in cache) {
                customs += [held hasPrefix:@"custom:"] ? 1 : 0;
            }
            if (customs >= ImageFieldKeys().count) {
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

// Cached, because consumers compare pointer identity; identical sides skip
// the wrapper, keeping single mode and the factory look a plain image.
+ (NSImage *)imageForDefaultArtworkDark:(NSString *)darkValue light:(NSString *)lightValue {
    NSImage *dark = [self imageForReference:darkValue];
    NSImage *light = [self imageForReference:lightValue];
    if (dark == light) {
        return dark;
    }
    // "dual|" cannot collide with a stored value: "|" fails the value shape.
    NSString *key = [NSString stringWithFormat:@"dual|%@|%@", darkValue ?: @"", lightValue ?: @""];
    NSMutableDictionary<NSString *, NSImage *> *cache = ImageCache();
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

// group → {json key → field key}, the import side.
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

// The editor's section order, as the rows first name the groups.
static NSArray<NSString *> *ThemeJSONGroupOrder(void) {
    return [NSOrderedSet orderedSetWithArray:[FieldSpecs() valueForKey:kSpecGroup]].array;
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

// Far above any real theme; a mispicked video fails before the parser.
static const NSUInteger kThemeJSONByteCap = 64 * 1024;

// Trimmed, not sanitized, so a bare archive entry name survives where the
// gate drops it.
+ (NSDictionary<NSString *, NSString *> *)rawImageReferencesInJSONData:(NSData *)json {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    NSMutableDictionary<NSString *, NSString *> *references = [NSMutableDictionary dictionary];
    for (NSString *key in ImageFieldKeys()) {
        NSArray<NSString *> *location = ThemeJSONFieldLocations()[key];
        id group = [root isKindOfClass:NSDictionary.class] ? root[location[0]] : nil;
        NSString *art = TrimmedCappedString(
                [group isKindOfClass:NSDictionary.class] ? group[location[1]] : nil);
        if (art.length) {
            references[key] = art;
        }
    }
    return references;
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
    // Anything outside a known group key drops, like an unknown field.
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
    return [self JSONDataForRecord:record name:name entryNames:nil];
}

+ (NSData *)JSONDataForRecord:(NSDictionary<NSString *, id> *)record
                          name:(NSString *)name
                    entryNames:(NSDictionary<NSString *, NSString *> *)entryNames {
    NSDictionary *fields = [self sanitizedRecord:record];
    if (entryNames.count) {
        NSMutableDictionary *renamed = [fields mutableCopy];
        [entryNames enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *entry, BOOL *stop) {
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
    // Hand-assembled: NSJSONSerialization cannot order top-level keys.
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
    // The switch postdates the radius: a record naming a radius but not the
    // switch chose that shape, so it reads as custom.
    if (_fields[kFieldWindowCornerRadius]
            && !SanitizedFieldValue(kFieldCustomCornerRadius, record[kFieldCustomCornerRadius])) {
        _fields[kFieldCustomCornerRadius] = @YES;
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

- (BOOL)waveformPlayheadLine { return [self boolForKey:kFieldWaveformPlayheadLine]; }
- (void)setWaveformPlayheadLine:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldWaveformPlayheadLine]; }

- (double)waveformBarDensity { return [self floatForKey:kFieldWaveformBarDensity]; }
- (void)setWaveformBarDensity:(double)v { [self storeSanitized:@(v) forKey:kFieldWaveformBarDensity]; }
- (double)waveformBarWidth { return [self floatForKey:kFieldWaveformBarWidth]; }
- (void)setWaveformBarWidth:(double)v { [self storeSanitized:@(v) forKey:kFieldWaveformBarWidth]; }

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

- (BOOL)customCornerRadius { return [self boolForKey:kFieldCustomCornerRadius]; }
- (void)setCustomCornerRadius:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldCustomCornerRadius]; }

- (CGFloat)resolvedWindowCornerRadius {
    return self.customCornerRadius ? self.windowCornerRadius : kVibeThemeCornerRadiusDefault;
}

- (NSString *)dockIcon { return [self stringForKey:kFieldDockIcon]; }
- (void)setDockIcon:(NSString *)v { [self storeSanitized:v forKey:kFieldDockIcon]; }

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

- (BOOL)showStatusIcons { return [self boolForKey:kFieldShowStatusIcons]; }
- (void)setShowStatusIcons:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowStatusIcons]; }

- (BOOL)showTimeLabels { return [self boolForKey:kFieldShowTimeLabels]; }
- (void)setShowTimeLabels:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowTimeLabels]; }

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

- (NSString *)volumeBar { return [self stringForKey:kFieldVolumeBar]; }
- (void)setVolumeBar:(NSString *)v { [self storeSanitized:v forKey:kFieldVolumeBar]; }

- (NSString *)volumeKnob { return [self stringForKey:kFieldVolumeKnob]; }
- (void)setVolumeKnob:(NSString *)v { [self storeSanitized:v forKey:kFieldVolumeKnob]; }

- (BOOL)showVolumeLabels { return [self boolForKey:kFieldShowVolumeLabels]; }
- (void)setShowVolumeLabels:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowVolumeLabels]; }

- (NSString *)volumeLocation { return [self stringForKey:kFieldVolumeLocation]; }
- (void)setVolumeLocation:(NSString *)v { [self storeSanitized:v forKey:kFieldVolumeLocation]; }

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
    NSAssert([ImageFieldKeys() containsObject:key], @"no image field %@", key);
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
    return [AppTheme imageForDefaultArtworkDark:[self imageReferenceForKey:kVibeThemeImageDefaultArtworkDark]
                                           light:[self imageReferenceForKey:kVibeThemeImageDefaultArtworkLight]];
}

- (NSImage *)defaultArtworkImageForAppearance:(NSAppearance *)appearance {
    return [AppTheme imageForReference:[self imageReferenceForKey:appearance.isDark ? kVibeThemeImageDefaultArtworkDark
                                                                                     : kVibeThemeImageDefaultArtworkLight]];
}

- (BOOL)showPlaylistNumberColumn { return [self boolForKey:kFieldShowPlaylistNumberColumn]; }
- (void)setShowPlaylistNumberColumn:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowPlaylistNumberColumn]; }

- (BOOL)showPlaylistArtworkColumn { return [self boolForKey:kFieldShowPlaylistArtworkColumn]; }
- (void)setShowPlaylistArtworkColumn:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowPlaylistArtworkColumn]; }

- (BOOL)showPlaylistDurationColumn { return [self boolForKey:kFieldShowPlaylistDurationColumn]; }
- (void)setShowPlaylistDurationColumn:(BOOL)v { [self storeSanitized:@(v) forKey:kFieldShowPlaylistDurationColumn]; }

#pragma mark Dice

static NSString *const kRandomMonoFontFace = @"Menlo-Regular";

static NSUInteger RandomIndex(NSUInteger count) {
    return arc4random_uniform((uint32_t)count);
}

static BOOL RandomChance(uint32_t percent) {
    return arc4random_uniform(100) < percent;
}

static id RandomPick(NSArray *choices) {
    return choices[RandomIndex(choices.count)];
}

+ (NSArray<NSString *> *)randomizableFontFaces {
    return @[@"Georgia", @"Baskerville", @"Palatino-Roman",
             @"HelveticaNeue-Medium", @"AvenirNext-Medium", @"Futura-Medium",
             kRandomMonoFontFace];
}

- (void)randomizeSettingsWithWaveformStyles:(NSArray<NSString *> *)styles {
    NSArray *backgrounds = @[SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS, SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID,
                             SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR];
    NSArray *tints = @[SETTINGS_VALUE_WINDOW_TINT_MONO, SETTINGS_VALUE_WINDOW_TINT_ARTWORK];
    self.windowBackgroundStyle = RandomPick([backgrounds arrayByAddingObject:SETTINGS_VALUE_WINDOW_BACKGROUND_FROSTED]);
    self.windowTint = RandomPick(tints);
    // Radius first: the switch's off is kept only beside a stored radius.
    self.windowCornerRadius = [RandomPick(@[@0, @8, @12, @16, @20, @28, @36]) doubleValue];
    self.customCornerRadius = RandomChance(50);
    if (styles.count) {
        self.waveformStyle = RandomPick(styles);
    }
    self.waveformTheme = RandomPick(@[SETTINGS_VALUE_WAVEFORM_THEME_MONO, SETTINGS_VALUE_WAVEFORM_THEME_ORANGE,
                                      SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART]);
    self.waveformGradient = RandomChance(50);
    self.buttonGradient = RandomPick(VibeButtonGradientModes());
    self.playlistButtonGlyph = RandomPick(VibePlaylistButtonGlyphs());
    NSArray<NSString *> *pair = RandomPick(VibePlayPauseGlyphPairs());
    self.playButtonGlyph = pair[0];
    self.pauseButtonGlyph = pair[1];
    self.nextButtonGlyph = RandomPick(VibeNextButtonGlyphs());
    self.playlistBackgroundStyle = RandomPick(backgrounds);
    self.playlistTint = RandomPick(tints);
    self.volumeBar = RandomPick([tints arrayByAddingObject:SETTINGS_VALUE_VOLUME_WAVEFORM]);
    self.volumeKnob = RandomPick([tints arrayByAddingObjectsFromArray:
            @[SETTINGS_VALUE_VOLUME_WAVEFORM, SETTINGS_VALUE_VOLUME_KNOB_BAR]]);
    self.showPlaylistNumberColumn = RandomChance(75);
    self.showPlaylistArtworkColumn = RandomChance(75);
    self.showPlaylistDurationColumn = RandomChance(75);
    NSString *face = RandomPick(AppTheme.randomizableFontFaces);
    NSString *numbers = RandomChance(50) ? kRandomMonoFontFace : face;
    [self setFontFace:face size:kVibeThemeTitleFontBaseSize forSlot:VibeFontSlotTitle];
    [self setFontFace:face size:kVibeThemeArtistFontBaseSize forSlot:VibeFontSlotArtist];
    [self setFontFace:face size:kVibeThemePlaylistFontBaseSize forSlot:VibeFontSlotPlaylist];
    [self setFontFace:numbers size:kVibeThemeInfoFontBaseSize forSlot:VibeFontSlotInfo];
    [self setFontFace:numbers size:kVibeThemePlaylistDurationFontBaseSize forSlot:VibeFontSlotPlaylistDuration];
}

// A pastel for dark, a deeper shade for light. The hue wraps, so a
// complement is plain addition.
static NSColor *HueColor(CGFloat hue, BOOL dark, CGFloat alpha) {
    hue = fmod(hue + 1, 1);
    return dark ? [NSColor colorWithHue:hue saturation:0.55 brightness:0.95 alpha:alpha]
                : [NSColor colorWithHue:hue saturation:0.75 brightness:0.55 alpha:alpha];
}

- (void)setHue:(CGFloat)hue alpha:(CGFloat)alpha forBase:(NSString *)base {
    [self setHue:hue darkAlpha:alpha lightAlpha:alpha forBase:base];
}

// Under single mode both sides share the dark slot, and the light write would
// overwrite the pastel the pinned-dark window draws.
- (void)setHue:(CGFloat)hue darkAlpha:(CGFloat)darkAlpha lightAlpha:(CGFloat)lightAlpha
       forBase:(NSString *)base {
    [self setColor:HueColor(hue, YES, darkAlpha) forBase:base dark:YES];
    if (![[self colorKeyForBase:base dark:NO] isEqualToString:[self colorKeyForBase:base dark:YES]]) {
        [self setColor:HueColor(hue, NO, lightAlpha) forBase:base dark:NO];
    }
}

- (void)randomizeColors {
    for (NSDictionary *spec in FieldSpecs()) {
        if (spec[kSpecColorBase]) {
            [_fields removeObjectForKey:spec[kSpecKey]];
        }
    }
    for (NSString *base in PlaylistColorFallbackBases()) {
        [self setPlaylistColorEnabled:NO forBase:base];
    }
    if ([self.waveformTheme isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM]) {
        self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    }
    if ([self.windowTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.windowTint = SETTINGS_VALUE_WINDOW_TINT_ARTWORK;
    }
    if ([self.playlistTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.playlistTint = SETTINGS_VALUE_WINDOW_TINT_MONO;
    }
    if ([self.volumeBar isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.volumeBar = SETTINGS_VALUE_VOLUME_WAVEFORM;
    }
    if ([self.volumeKnob isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.volumeKnob = SETTINGS_VALUE_VOLUME_KNOB_BAR;
    }

    CGFloat hue = RandomIndex(360) / 360.0;
    switch (RandomIndex(5)) {
        case 0: // The header labels in the hue, the artist line lighter.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorArtist];
            break;
        case 1: // The same, carried into the playlist's rows and fills.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorArtist];
            [self setHue:hue alpha:0.95 forBase:kVibeThemeColorPlaylistTitle];
            [self setHue:hue alpha:0.6 forBase:kVibeThemeColorPlaylistArtist];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistTitle];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistArtist];
            [self setHue:hue alpha:0.18 forBase:kVibeThemeColorPlaylistPlayingRow];
            [self setHue:hue alpha:0.12 forBase:kVibeThemeColorPlaylistSelectedRow];
            break;
        case 2: // A complementary pair: titles in the hue, artists opposite it.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue + 0.5 alpha:0.75 forBase:kVibeThemeColorArtist];
            [self setHue:hue alpha:0.95 forBase:kVibeThemeColorPlaylistTitle];
            [self setHue:hue + 0.5 alpha:0.65 forBase:kVibeThemeColorPlaylistArtist];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistTitle];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistArtist];
            self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
            [self setHue:hue alpha:0.85 forBase:kVibeThemeColorWaveformPlayed];
            [self setHue:hue + 0.5 alpha:0.35 forBase:kVibeThemeColorWaveformUnplayed];
            break;
        case 3: // An analogous pair, reaching the info card and the buttons.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue + 0.08 alpha:0.7 forBase:kVibeThemeColorArtist];
            [self setHue:hue + 0.08 alpha:0.55 forBase:kVibeThemeColorInfo];
            [self setHue:hue alpha:0.65 forBase:kVibeThemeColorTime];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorPlaylistButton];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorPlayButton];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorNextButton];
            self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
            [self setHue:hue alpha:0.8 forBase:kVibeThemeColorWaveformPlayed];
            [self setHue:hue + 0.08 alpha:0.3 forBase:kVibeThemeColorWaveformUnplayed];
            break;
        default: // A wash of the hue over the window and the playlist, labels left plain.
            self.windowTint = SETTINGS_VALUE_WINDOW_TINT_CUSTOM;
            [self setHue:hue darkAlpha:0.35 lightAlpha:0.45 forBase:kVibeThemeColorWindowTint];
            self.playlistTint = SETTINGS_VALUE_WINDOW_TINT_CUSTOM;
            [self setHue:hue darkAlpha:0.25 lightAlpha:0.35 forBase:kVibeThemeColorPlaylistTint];
            [self setHue:hue alpha:0.2 forBase:kVibeThemeColorPlaylistPlayingRow];
            self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
            [self setHue:hue alpha:0.8 forBase:kVibeThemeColorWaveformPlayed];
            [self setHue:hue alpha:0.3 forBase:kVibeThemeColorWaveformUnplayed];
            break;
    }
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
