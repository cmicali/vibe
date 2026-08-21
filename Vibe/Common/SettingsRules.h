//
//  SettingsRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "AppSettings.h"

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
