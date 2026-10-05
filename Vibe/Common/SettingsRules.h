//
//  SettingsRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AppSettings.h"
#import "VibeStrings.h"
#if TARGET_OS_OSX
#import "AppSettings+Mac.h"
#endif

// The normalizers accept a nil stored value and always return an identifier.
NS_ASSUME_NONNULL_BEGIN

static inline NSInteger VibeNormalizedPitchRange(NSInteger range) {
    return range == 16 ? 16 : 8;
}

// An out-of-list stored value reads as the nearest preset, so display and
// behavior cannot disagree. Ties break downward.
static inline NSInteger VibeNearestPreset(NSInteger value, const NSInteger *presets, size_t count) {
    // Clamp before subtracting: external defaults can contain integer extremes.
    if (value <= presets[0]) return presets[0];
    if (value >= presets[count - 1]) return presets[count - 1];
    NSInteger best = presets[0];
    for (size_t i = 1; i < count; i++) {
        if (llabs((long long)(value - presets[i])) < llabs((long long)(value - best))) {
            best = presets[i];
        }
    }
    return best;
}

// The nearest slider step, ties downward; anything below the first step is
// off.
static inline NSInteger VibeNormalizedCrossfadeMilliseconds(NSInteger milliseconds) {
    // Clamp before rounding: external defaults can contain integer extremes.
    NSInteger clamped = MAX(0, MIN(kVibeCrossfadeMaxMilliseconds, milliseconds));
    NSInteger half = kVibeCrossfadeStepMilliseconds / 2;
    NSInteger stepped = (clamped + half - 1) / kVibeCrossfadeStepMilliseconds * kVibeCrossfadeStepMilliseconds;
    return stepped > 0 ? stepped : kVibeCrossfadeOffMilliseconds;
}

static inline NSString *VibeNormalizedWaveformTheme(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE] ||
        [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART] ||
        [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM]) {
        return identifier;
    }
    return SETTINGS_VALUE_WAVEFORM_THEME_MONO;
}

static inline VibeFolderOpenSort VibeNormalizedFolderOpenSort(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_FOLDER_OPEN_SORT_NEWEST_FIRST]) {
        return VibeFolderOpenSortNewestFirst;
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_FOLDER_OPEN_SORT_AS_RECEIVED]) {
        return VibeFolderOpenSortAsReceived;
    }
    return VibeFolderOpenSortName;
}

static inline NSString *VibeFolderOpenSortIdentifier(VibeFolderOpenSort sort) {
    switch (sort) {
        case VibeFolderOpenSortNewestFirst: return SETTINGS_VALUE_FOLDER_OPEN_SORT_NEWEST_FIRST;
        case VibeFolderOpenSortAsReceived:  return SETTINGS_VALUE_FOLDER_OPEN_SORT_AS_RECEIVED;
        case VibeFolderOpenSortName:        break;
    }
    return SETTINGS_VALUE_FOLDER_OPEN_SORT_NAME;
}

// The label every chooser of the folder-open order shows for each choice.
static inline NSString *VibeFolderOpenSortDisplayName(VibeFolderOpenSort sort) {
    switch (sort) {
        case VibeFolderOpenSortNewestFirst: return STR_SETTINGS_FOLDER_SORT_NEWEST_FIRST;
        case VibeFolderOpenSortAsReceived:  return STR_SETTINGS_FOLDER_SORT_AS_RECEIVED;
        case VibeFolderOpenSortName:        break;
    }
    return STR_SETTINGS_FOLDER_SORT_NAME;
}

static inline VibeRepeatMode VibeNormalizedRepeatMode(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_REPEAT_MODE_ALL]) {
        return VibeRepeatModeAll;
    }
    if ([identifier isEqualToString:SETTINGS_VALUE_REPEAT_MODE_ONE]) {
        return VibeRepeatModeOne;
    }
    return VibeRepeatModeOff;
}

static inline NSString *VibeRepeatModeIdentifier(VibeRepeatMode mode) {
    switch (mode) {
        case VibeRepeatModeAll: return SETTINGS_VALUE_REPEAT_MODE_ALL;
        case VibeRepeatModeOne: return SETTINGS_VALUE_REPEAT_MODE_ONE;
        case VibeRepeatModeOff: break;
    }
    return SETTINGS_VALUE_REPEAT_MODE_OFF;
}

// The repeat control names the mode it is in — the mac's menu title, the iOS
// button's accessibility label — and choosing it moves to the next.
static inline NSString *VibeRepeatModeTitle(VibeRepeatMode mode) {
    switch (mode) {
        case VibeRepeatModeAll: return STR_TRANSPORT_REPEAT_ALL;
        case VibeRepeatModeOne: return STR_TRANSPORT_REPEAT_ONE;
        case VibeRepeatModeOff: break;
    }
    return STR_TRANSPORT_REPEAT_OFF;
}

static inline NSString *VibeRepeatModeSymbolName(VibeRepeatMode mode) {
    return mode == VibeRepeatModeOne ? @"repeat.1" : @"repeat";
}

// What a tap on iOS's button or the mac's ⌘R moves to: Off, All, One, Off.
static inline VibeRepeatMode VibeRepeatModeAfter(VibeRepeatMode mode) {
    switch (mode) {
        case VibeRepeatModeOff: return VibeRepeatModeAll;
        case VibeRepeatModeAll: return VibeRepeatModeOne;
        case VibeRepeatModeOne: break;
    }
    return VibeRepeatModeOff;
}

#if TARGET_OS_OSX
// One ladder, two factory defaults: artwork for the window, mono for the
// playlist.
static inline NSString *VibeNormalizedTint(NSString *_Nullable identifier, NSString *fallback) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_MONO] ||
        [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_ARTWORK] ||
        [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        return identifier;
    }
    return fallback;
}

static inline NSString *VibeNormalizedWindowTint(NSString *_Nullable identifier) {
    return VibeNormalizedTint(identifier, SETTINGS_VALUE_WINDOW_TINT_ARTWORK);
}

static inline NSString *VibeNormalizedPlaylistTint(NSString *_Nullable identifier) {
    return VibeNormalizedTint(identifier, SETTINGS_VALUE_WINDOW_TINT_MONO);
}

// The tint ladder plus the waveform's played color, its default.
static inline NSString *VibeNormalizedVolumeBar(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_VOLUME_WAVEFORM]
            ? identifier : VibeNormalizedTint(identifier, SETTINGS_VALUE_VOLUME_WAVEFORM);
}

// The bar's ladder plus the bar's own color, its default.
static inline NSString *VibeNormalizedVolumeKnob(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_VOLUME_WAVEFORM]
            ? identifier : VibeNormalizedTint(identifier, SETTINGS_VALUE_VOLUME_KNOB_BAR);
}

static inline NSString *VibeNormalizedVolumeLocation(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_VOLUME_LOCATION_BOTTOM]
            ? SETTINGS_VALUE_VOLUME_LOCATION_BOTTOM
            : SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT;
}

static inline NSString *VibeNormalizedWaveformBandTheme(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE] ||
        [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM]) {
        return identifier;
    }
    return SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN;
}

// Each snaps an unknown value to its factory choice.
static inline NSString *VibeNormalizedThemeMode(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_THEME_MODE_SINGLE]
            ? SETTINGS_VALUE_THEME_MODE_SINGLE
            : SETTINGS_VALUE_THEME_MODE_DUAL;
}

static inline NSString *VibeNormalizedPlaylistBackgroundStyle(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID] ||
        [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR]) {
        return identifier;
    }
    return SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS;
}

// The playlist's choices plus frosted, which only the window has: the
// window's color under its glass panes.
static inline NSString *VibeNormalizedWindowBackgroundStyle(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_FROSTED]
            ? identifier : VibeNormalizedPlaylistBackgroundStyle(identifier);
}

// Frosted and solid both lay the theme's color over the backdrop; solid also
// drops the glass panes over it.
static inline BOOL VibeWindowBackgroundTakesColor(NSString *_Nullable style) {
    return [style isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_FROSTED] ||
           [style isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
}

static inline NSString *VibeNormalizedKeyNotation(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]
            ? SETTINGS_VALUE_KEY_NOTATION_MUSICAL
            : SETTINGS_VALUE_KEY_NOTATION_CAMELOT;
}

static inline NSString *VibeNormalizedDockIcon(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_DOCK_ICON_APP_ICON]
            ? SETTINGS_VALUE_DOCK_ICON_APP_ICON
            : SETTINGS_VALUE_DOCK_ICON_ALBUM_ART;
}

// In the editor's menu order.
static inline NSArray<NSString *> *VibeButtonGradientModes(void) {
    return @[SETTINGS_VALUE_BUTTON_GRADIENT_NONE, SETTINGS_VALUE_BUTTON_GRADIENT_HOVER,
             SETTINGS_VALUE_BUTTON_GRADIENT_ARTWORK, SETTINGS_VALUE_BUTTON_GRADIENT_ALWAYS];
}

static inline NSString *VibeNormalizedButtonGradient(NSString *_Nullable identifier) {
    return identifier && [VibeButtonGradientModes() containsObject:identifier]
            ? identifier : SETTINGS_VALUE_BUTTON_GRADIENT_ALWAYS;
}

// The editor's glyph menus: SF Symbols every supported macOS carries. Not a
// ladder — the theme's glyph fields are free text.
static inline NSArray<NSString *> *VibePlaylistButtonGlyphs(void) {
    return @[@"list.bullet", @"list.dash", @"list.triangle", @"list.number", @"music.note.list",
             @"text.justify", @"line.3.horizontal", @"square.stack", @"rectangle.stack",
             @"tablecells", @"sidebar.left", @"chevron.up.chevron.down"];
}

// Pairs, because one pick dresses both states: the play field stores the
// first, the pause field the second.
static inline NSArray<NSArray<NSString *> *> *VibePlayPauseGlyphPairs(void) {
    return @[@[@"play.fill", @"pause.fill"],
             @[@"play", @"pause"],
             @[@"play.circle.fill", @"pause.circle.fill"],
             @[@"play.circle", @"pause.circle"],
             @[@"play.rectangle.fill", @"pause.rectangle.fill"],
             @[@"play.rectangle", @"pause.rectangle"],
             @[@"arrowtriangle.right.fill", @"pause.fill"],
             @[@"arrowtriangle.right", @"pause"]];
}

static inline NSArray<NSString *> *VibePlayButtonGlyphs(void) {
    NSMutableArray<NSString *> *glyphs = [NSMutableArray array];
    for (NSArray<NSString *> *pair in VibePlayPauseGlyphPairs()) {
        [glyphs addObject:pair[0]];
    }
    return glyphs;
}

static inline NSArray<NSString *> *VibeNextButtonGlyphs(void) {
    return @[@"forward.end.fill", @"forward.end", @"forward.end.alt.fill", @"forward.end.alt",
             @"forward.fill", @"forward", @"forward.frame.fill", @"forward.end.circle.fill",
             @"chevron.right", @"chevron.right.2", @"arrow.right", @"arrow.right.circle.fill",
             @"arrow.right.to.line", @"arrowtriangle.right.fill", @"arrowshape.right.fill"];
}

// The factory pause glyph for a play glyph outside the table, so the two
// states never draw the same glyph.
static inline NSString *VibePauseGlyphForPlayGlyph(NSString *_Nullable playGlyph) {
    for (NSArray<NSString *> *pair in VibePlayPauseGlyphPairs()) {
        if ([pair[0] isEqualToString:playGlyph]) {
            return pair[1];
        }
    }
    return kVibeThemePauseButtonGlyphDefault;
}

static inline NSString *VibeNormalizedWaveformDragBehavior(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK]) {
        return identifier;
    }
    return SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW;
}

static inline NSString *VibeNormalizedArtworkDragAction(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH] ||
        [identifier isEqualToString:SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE]) {
        return identifier;
    }
    return SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE;
}

// Lands on the slider's half-dB step, so the knob and readout never show a
// value the store did not keep.
static inline double VibeNormalizedWaveformGainDB(double gainDB) {
    if (isnan(gainDB)) {
        return 0;
    }
    double clamped = MAX(-kVibeWaveformGainMaxDB, MIN(kVibeWaveformGainMaxDB, gainDB));
    return round(clamped * 2) / 2;
}

// The pre-theme mac store's waveform theme, or nil. A sonic_cirrus style with
// no theme key keeps the orange that style used to draw; a stored theme key
// was the user's choice. Pre-theme stores exist only on the mac: an iOS store
// with no theme key is a user who never picked one.
static inline NSString *_Nullable VibeMigratedWaveformTheme(NSString *_Nullable storedTheme,
                                                            NSString *_Nullable storedStyle) {
    if (storedTheme) {
        return nil;
    }
    return [storedStyle isEqualToString:@"sonic_cirrus"] ? SETTINGS_VALUE_WAVEFORM_THEME_ORANGE : nil;
}
#endif  // TARGET_OS_OSX

// Reset to Defaults' enabled decision. A registered key counts only when its
// stored value differs from the default, so a migration writing the default
// back does not; a nullable key counts whenever stored.
static inline BOOL VibeSettingsAreAtDefaults(NSDictionary<NSString *, id> *_Nullable stored,
                                             NSDictionary<NSString *, id> *registeredDefaults,
                                             NSArray<NSString *> *nullableKeys) {
    for (NSString *key in registeredDefaults) {
        id value = stored[key];
        if (value && ![value isEqual:registeredDefaults[key]]) {
            return NO;
        }
    }
    for (NSString *key in nullableKeys) {
        if (stored[key]) {
            return NO;
        }
    }
    return YES;
}

#if TARGET_OS_OSX
// Release builds reveal the Advanced pane's Audio readout after
// kVibeAudioPathRevealClicks clicks on the Version row, each within
// kVibeAudioPathRevealGapSeconds of the last; a slower click starts over.
static const NSUInteger kVibeAudioPathRevealClicks = 7;
static const NSTimeInterval kVibeAudioPathRevealGapSeconds = 1.5;

static inline NSUInteger VibeAudioPathRevealClickCount(NSUInteger count, NSTimeInterval sinceLast) {
    return sinceLast <= kVibeAudioPathRevealGapSeconds ? count + 1 : 1;
}
#endif

NS_ASSUME_NONNULL_END
