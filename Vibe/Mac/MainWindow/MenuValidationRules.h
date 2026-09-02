//
//  MenuValidationRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Every menu identifier MainPlayerController validates, and the domain that
// decides it. Each identifier is spelled once, as a constant below: the builder
// mints through it, validateMenuItem: dispatches on it and
// contentWidthForSizeIdentifier: sizes the window from it, so a rename that
// misses a site is a compile error rather than a silently unvalidated item. A
// literal spelling of one anywhere else is exactly the bug this file prevents.
//
// TRAP: an identifier that reaches Unknown is DISABLED, not enabled. The
// validator's fall-through used to be YES, which let a mistyped or newly added
// controller-targeted item skip validation with nothing to see. Adding a menu
// item to this controller therefore means adding it here too.
//
// Items other objects own are deliberately absent and land on Unknown without
// ever being asked: the playlist's row menu is PlaylistController's, Output is
// OutputDevicesMenuController's, and Settings/Quit target the app delegate.
typedef NS_ENUM(NSInteger, VibeMenuValidationDomain) {
    // Not this controller's to validate.
    VibeMenuValidationDomainUnknown = 0,
    // Window and preference checkmarks. Never disabled: a preference is not an
    // action, and there is nothing for it to be unavailable for.
    VibeMenuValidationDomainViewToggle,
    // The width presets, checkmarked against the body's current width.
    VibeMenuValidationDomainWindowSize,
    VibeMenuValidationDomainAppearance,
    // Next/previous/play-selected/skip: the items that go unavailable at the
    // ends of a playlist, with nothing loaded, or with the player stopped.
    VibeMenuValidationDomainTransport,
    // Live FX mirroring. Never disabled — the effects are deck controls that
    // outlive any single track.
    VibeMenuValidationDomainFX,
    VibeMenuValidationDomainPitchRange,
    // Play/Close/Show in Finder: dynamic titles and symbols over the playlist.
    VibeMenuValidationDomainFile,
    // Undo/Redo titles from NSUndoManager, the Copy items, and Remove from
    // Playlist.
    VibeMenuValidationDomainEdit,
    // Convert to FLAC — Cancel Conversion while one runs, see the identifier —
    // and its preference. AudioFileConverter stays the authority for the idle
    // item's enablement and retitling.
    VibeMenuValidationDomainConvert,
    // menuNeedsUpdate: mints these and owns their state, title and target.
    VibeMenuValidationDomainTheme,
};

// The identifiers. The window-size family is derived from its preset and the
// theme family from the theme's own identifier, both below, so neither is
// spelled out here.
static NSString *const kVibeMenuShowPlaylist = @"menu_show_playlist";
static NSString *const kVibeMenuShowPitch = @"menu_show_pitch";
static NSString *const kVibeMenuShowFileInfo = @"menu_show_file_info";
static NSString *const kVibeMenuAlwaysOnTop = @"menu_always_on_top";

static NSString *const kVibeMenuAppearanceSystem = @"view_appearance_system_default";
static NSString *const kVibeMenuAppearanceLight = @"view_appearance_light";
static NSString *const kVibeMenuAppearanceDark = @"view_appearance_dark";

static NSString *const kVibeMenuNextTrack = @"menu_next_track";
static NSString *const kVibeMenuPreviousTrack = @"menu_previous_track";
static NSString *const kVibeMenuPlaySelected = @"menu_play_selected";
static NSString *const kVibeMenuSkipForward = @"menu_skip_forward";
static NSString *const kVibeMenuSkipForwardMore = @"menu_skip_forward_more";
static NSString *const kVibeMenuSkipForwardMost = @"menu_skip_forward_most";
static NSString *const kVibeMenuSkipBack = @"menu_skip_back";
static NSString *const kVibeMenuSkipBackMore = @"menu_skip_back_more";
static NSString *const kVibeMenuSkipBackMost = @"menu_skip_back_most";

static NSString *const kVibeMenuFXLowKill = @"menu_fx_low_kill";
static NSString *const kVibeMenuFXLowKillBoost = @"menu_fx_low_kill_boost";
static NSString *const kVibeMenuFXReverb = @"menu_fx_reverb";
static NSString *const kVibeMenuFXDelay = @"menu_fx_delay";
static NSString *const kVibeMenuFXShortDelay = @"menu_fx_short_delay";

static NSString *const kVibeMenuPitchRange8 = @"pitch_range_8";
static NSString *const kVibeMenuPitchRange16 = @"pitch_range_16";

static NSString *const kVibeMenuPlay = @"menu_play";
static NSString *const kVibeMenuClose = @"menu_close";
static NSString *const kVibeMenuShowInFinder = @"show_in_finder";

static NSString *const kVibeMenuEditUndo = @"menu_edit_undo";
static NSString *const kVibeMenuEditRedo = @"menu_edit_redo";
static NSString *const kVibeMenuEditCopyFile = @"menu_edit_copy_file";
static NSString *const kVibeMenuEditCopyName = @"menu_edit_copy_name";
static NSString *const kVibeMenuEditRemoveFromPlaylist = @"menu_edit_remove_from_playlist";

// Also Cancel Conversion: one item whose title and action the controller swaps
// in validation while a conversion runs, as menu_play swaps to Pause, so there
// is deliberately no menu_convert_cancel.
static NSString *const kVibeMenuConvertToFLAC = @"menu_convert_to_flac";
static NSString *const kVibeMenuConvertDeleteOriginal = @"menu_convert_delete_original";

// The Theme submenu itself, which menuNeedsUpdate: recognizes; its items carry
// the prefix, and its Edit tail is the app delegate's, not this controller's.
static NSString *const kVibeMenuThemeSubmenu = @"view_theme";
static NSString *const kVibeMenuThemePrefix = @"view_theme_";
static NSString *const kVibeMenuEditThemes = @"menu_edit_themes";

// The three width presets. The identifier is derived from the preset rather
// than written out, so the builder, the checkmark and the width lookup cannot
// disagree about a spelling.
typedef NS_ENUM(NSInteger, VibeWindowSizePreset) {
    VibeWindowSizePresetSmall,
    VibeWindowSizePresetDefault,
    VibeWindowSizePresetLarge,
};

static inline NSString *VibeWindowSizeMenuIdentifier(VibeWindowSizePreset preset) {
    switch (preset) {
        case VibeWindowSizePresetSmall:   return @"view_size_small";
        case VibeWindowSizePresetLarge:   return @"view_size_large";
        case VibeWindowSizePresetDefault: break;
    }
    return @"view_size_default";
}

// An identifier in the family but naming no preset answers Default, which is
// what the width lookup has always done with one.
static inline VibeWindowSizePreset VibeWindowSizePresetForMenuIdentifier(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:VibeWindowSizeMenuIdentifier(VibeWindowSizePresetSmall)]) {
        return VibeWindowSizePresetSmall;
    }
    if ([identifier isEqualToString:VibeWindowSizeMenuIdentifier(VibeWindowSizePresetLarge)]) {
        return VibeWindowSizePresetLarge;
    }
    return VibeWindowSizePresetDefault;
}

// The dynamic theme items carry the theme's own identifier as a suffix, so
// the family is matched by prefix rather than enumerated. The tail's
// menu_edit_themes is deliberately absent: it targets the app delegate, like
// Settings and Quit.
static inline NSString *VibeThemeMenuIdentifier(NSString *themeIdentifier) {
    return [kVibeMenuThemePrefix stringByAppendingString:themeIdentifier];
}

static inline VibeMenuValidationDomain VibeMenuValidationDomainForIdentifier(NSString *_Nullable identifier) {
    if (identifier.length == 0) {
        return VibeMenuValidationDomainUnknown;
    }
    if ([identifier hasPrefix:@"view_size_"]) {
        return VibeMenuValidationDomainWindowSize;
    }
    if ([identifier hasPrefix:kVibeMenuThemePrefix]) {
        return VibeMenuValidationDomainTheme;
    }
    if ([identifier isEqualToString:kVibeMenuShowPlaylist]
            || [identifier isEqualToString:kVibeMenuShowPitch]
            || [identifier isEqualToString:kVibeMenuShowFileInfo]
            || [identifier isEqualToString:kVibeMenuAlwaysOnTop]) {
        return VibeMenuValidationDomainViewToggle;
    }
    if ([identifier isEqualToString:kVibeMenuAppearanceSystem]
            || [identifier isEqualToString:kVibeMenuAppearanceLight]
            || [identifier isEqualToString:kVibeMenuAppearanceDark]) {
        return VibeMenuValidationDomainAppearance;
    }
    if ([identifier isEqualToString:kVibeMenuNextTrack]
            || [identifier isEqualToString:kVibeMenuPreviousTrack]
            || [identifier isEqualToString:kVibeMenuPlaySelected]
            || [identifier isEqualToString:kVibeMenuSkipForward]
            || [identifier isEqualToString:kVibeMenuSkipForwardMore]
            || [identifier isEqualToString:kVibeMenuSkipForwardMost]
            || [identifier isEqualToString:kVibeMenuSkipBack]
            || [identifier isEqualToString:kVibeMenuSkipBackMore]
            || [identifier isEqualToString:kVibeMenuSkipBackMost]) {
        return VibeMenuValidationDomainTransport;
    }
    if ([identifier isEqualToString:kVibeMenuFXLowKill]
            || [identifier isEqualToString:kVibeMenuFXLowKillBoost]
            || [identifier isEqualToString:kVibeMenuFXReverb]
            || [identifier isEqualToString:kVibeMenuFXDelay]
            || [identifier isEqualToString:kVibeMenuFXShortDelay]) {
        return VibeMenuValidationDomainFX;
    }
    if ([identifier isEqualToString:kVibeMenuPitchRange8]
            || [identifier isEqualToString:kVibeMenuPitchRange16]) {
        return VibeMenuValidationDomainPitchRange;
    }
    if ([identifier isEqualToString:kVibeMenuPlay]
            || [identifier isEqualToString:kVibeMenuClose]
            || [identifier isEqualToString:kVibeMenuShowInFinder]) {
        return VibeMenuValidationDomainFile;
    }
    if ([identifier isEqualToString:kVibeMenuEditUndo]
            || [identifier isEqualToString:kVibeMenuEditRedo]
            || [identifier isEqualToString:kVibeMenuEditCopyFile]
            || [identifier isEqualToString:kVibeMenuEditCopyName]
            || [identifier isEqualToString:kVibeMenuEditRemoveFromPlaylist]) {
        return VibeMenuValidationDomainEdit;
    }
    if ([identifier isEqualToString:kVibeMenuConvertToFLAC]
            || [identifier isEqualToString:kVibeMenuConvertDeleteOriginal]) {
        return VibeMenuValidationDomainConvert;
    }
    return VibeMenuValidationDomainUnknown;
}

NS_ASSUME_NONNULL_END
