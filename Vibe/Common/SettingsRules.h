//
//  SettingsRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AppSettings.h"
#if TARGET_OS_OSX
#import "AppSettings+Mac.h"
#endif

// Nonnull by default: the normalizers accept a nullable stored value —
// stringForKey: answers nil before defaults registration or after an external
// delete — and always return an identifier.
NS_ASSUME_NONNULL_BEGIN

static inline NSInteger VibeNormalizedPitchRange(NSInteger range) {
    return range == 16 ? 16 : 8;
}

// An unknown stored waveform-theme identifier snaps to mono, like
// keyNotation's snap to Camelot.
static inline NSString *VibeNormalizedWaveformTheme(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE] ||
        [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART] ||
        [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM]) {
        return identifier;
    }
    return SETTINGS_VALUE_WAVEFORM_THEME_MONO;
}

// The folder-open order, both ways: an unknown stored identifier snaps to
// Name, the default and the order every folder open used before the setting.
// The waveform gain's ladder: an external write outside the slider's range
// clamps, NaN reads as the plain mapping, and every value lands on the
// nearest half dB — the slider's step — so the pane's knob and readout never
// show a value the store did not keep.
static inline double VibeNormalizedWaveformGainDB(double gainDB) {
    if (isnan(gainDB)) {
        return 0;
    }
    double clamped = MAX(-kVibeWaveformGainMaxDB, MIN(kVibeWaveformGainMaxDB, gainDB));
    return round(clamped * 2) / 2;
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

#if TARGET_OS_OSX
// The two tint ladders are one shape with different defaults: an unknown
// window tint snaps to artwork (the header wash follows the playing track's
// art color), an unknown playlist tint to mono (the factory playlist takes
// no wash).
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

// The theme record's other two-value ladders, each snapping to its factory
// side: dual color sets, the glass background, Camelot notation.
static inline NSString *VibeNormalizedThemeMode(NSString *_Nullable identifier) {
    return [identifier isEqualToString:SETTINGS_VALUE_THEME_MODE_SINGLE]
            ? SETTINGS_VALUE_THEME_MODE_SINGLE
            : SETTINGS_VALUE_THEME_MODE_DUAL;
}

static inline NSString *VibeNormalizedWindowBackgroundStyle(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID] ||
        [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR]) {
        return identifier;
    }
    return SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS;
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

// The transport buttons' glyph choices, as the theme editor offers them —
// SF Symbol names every macOS the app runs on carries. The theme's glyph
// fields are free text (AppTheme), so these are the editor's menu and the
// pair table below, not a ladder: a JSON may name a symbol outside them.
// The play choices are play/pause PAIRS, because one pick has to dress both
// states; the first column is what the editor lists and the play field
// stores, the second what it writes to the pause field beside it.
static NSString *const _Nonnull kVibePlaylistButtonGlyphs[] = {
    @"list.bullet", @"list.dash", @"list.triangle", @"list.number", @"music.note.list",
    @"text.justify", @"line.3.horizontal", @"square.stack", @"rectangle.stack",
    @"tablecells", @"sidebar.left", @"chevron.up.chevron.down",
};
static const size_t kVibePlaylistButtonGlyphCount =
        sizeof(kVibePlaylistButtonGlyphs) / sizeof(kVibePlaylistButtonGlyphs[0]);

static NSString *const _Nonnull kVibePlayPauseGlyphPairs[][2] = {
    {@"play.fill", @"pause.fill"},
    {@"play", @"pause"},
    {@"play.circle.fill", @"pause.circle.fill"},
    {@"play.circle", @"pause.circle"},
    {@"play.rectangle.fill", @"pause.rectangle.fill"},
    {@"play.rectangle", @"pause.rectangle"},
    {@"arrowtriangle.right.fill", @"pause.fill"},
    {@"arrowtriangle.right", @"pause"},
};
static const size_t kVibePlayPauseGlyphPairCount =
        sizeof(kVibePlayPauseGlyphPairs) / sizeof(kVibePlayPauseGlyphPairs[0]);

static NSString *const _Nonnull kVibeNextButtonGlyphs[] = {
    @"forward.end.fill", @"forward.end", @"forward.end.alt.fill", @"forward.end.alt",
    @"forward.fill", @"forward", @"forward.frame.fill", @"forward.end.circle.fill",
    @"chevron.right", @"chevron.right.2", @"arrow.right", @"arrow.right.circle.fill",
    @"arrow.right.to.line", @"arrowtriangle.right.fill", @"arrowshape.right.fill",
};
static const size_t kVibeNextButtonGlyphCount =
        sizeof(kVibeNextButtonGlyphs) / sizeof(kVibeNextButtonGlyphs[0]);

// The pause glyph a play pick dresses the playing state with: its pair-table
// partner, or the factory pause glyph for a play glyph the table does not
// know — a JSON-authored one — so the two states never draw the same glyph.
static inline NSString *VibePauseGlyphForPlayGlyph(NSString *_Nullable playGlyph) {
    for (size_t i = 0; i < kVibePlayPauseGlyphPairCount; i++) {
        if ([kVibePlayPauseGlyphPairs[i][0] isEqualToString:playGlyph]) {
            return kVibePlayPauseGlyphPairs[i][1];
        }
    }
    return kVibeThemePauseButtonGlyphDefault;
}

// An unknown stored waveform-drag identifier snaps to drag_window, the
// default: a drag moves the window and only a stationary click seeks.
static inline NSString *VibeNormalizedWaveformDragBehavior(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK]) {
        return identifier;
    }
    return SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW;
}

// An unknown stored artwork-drag identifier snaps to copy_file, the default:
// dragging the art out delivers the audio file itself.
static inline NSString *VibeNormalizedArtworkDragAction(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH] ||
        [identifier isEqualToString:SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE]) {
        return identifier;
    }
    return SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE;
}
#endif  // TARGET_OS_OSX

// The one-time theme migration: the value to write, or nil to write nothing.
// Sonic Cirrus owned the orange before the style/theme split, so a stored
// sonic_cirrus style with no theme key yet keeps its orange; any stored theme
// key means the migration already ran or the user chose.
static inline NSString *_Nullable VibeMigratedWaveformTheme(NSString *_Nullable storedTheme,
                                                            NSString *_Nullable storedStyle) {
    if (storedTheme) {
        return nil;
    }
    return [storedStyle isEqualToString:@"sonic_cirrus"] ? SETTINGS_VALUE_WAVEFORM_THEME_ORANGE : nil;
}

// Whether every stored setting still holds its default — the Reset to
// Defaults button's enabled decision. A registered key is non-default only
// when a value is stored AND differs from the registered default, so a
// migration that wrote the default back does not count; a nullable key (the
// custom colors, which register no default) is non-default whenever it is
// stored at all.
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

NS_ASSUME_NONNULL_END
