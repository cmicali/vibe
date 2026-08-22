//
//  SettingsRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AppSettings.h"

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
// An unknown stored window-tint identifier snaps to artwork, the default:
// the header wash follows the playing track's art color.
static inline NSString *VibeNormalizedWindowTint(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_MONO] ||
        [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        return identifier;
    }
    return SETTINGS_VALUE_WINDOW_TINT_ARTWORK;
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
