//
//  MenuValidationRules.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import "VibeStrings.h"

NS_ASSUME_NONNULL_BEGIN

// Every menu identifier MainPlayerController validates, and its domain. Each
// is spelled once, as a constant, so a rename that misses a site fails the
// build; a literal spelling anywhere else is the bug this file prevents.
//
// TRAP: an identifier that reaches Unknown is DISABLED (and asserts), so a new
// controller-targeted item must be added here or it never enables.
//
// Items other objects target are absent and never asked: the row menu, Output,
// and the app delegate's items.
typedef NS_ENUM(NSInteger, VibeMenuValidationDomain) {
    // Not this controller's to validate.
    VibeMenuValidationDomainUnknown = 0,
    // Checkmarks, never disabled except Show Pitch Control under bit-perfect
    // output, which has no varispeed.
    VibeMenuValidationDomainViewToggle,
    VibeMenuValidationDomainWindowSize,
    // Unavailable at the playlist's ends, with nothing loaded, or Stopped.
    VibeMenuValidationDomainTransport,
    // Checkmarks, disabled without an FX segment or while
    // AppSettings.audioFXAllowed is off.
    VibeMenuValidationDomainFX,
    VibeMenuValidationDomainPitchRange,
    // Shuffle's checkmark and Repeat's mode-naming title; never disabled.
    VibeMenuValidationDomainPlayOrder,
    VibeMenuValidationDomainFile,
    VibeMenuValidationDomainEdit,
    // AudioFileConverter owns the idle item's enablement and title.
    VibeMenuValidationDomainConvert,
    // menuNeedsUpdate: mints these and owns their state, title and target.
    VibeMenuValidationDomainTheme,
};

// The window-size and theme families are derived below.
static NSString *const kVibeMenuShowPlaylist = @"menu_show_playlist";
static NSString *const kVibeMenuShowPitch = @"menu_show_pitch";
static NSString *const kVibeMenuAlwaysOnTop = @"menu_always_on_top";
static NSString *const kVibeMenuLockWindowPosition = @"menu_lock_window_position";

static NSString *const kVibeMenuNextTrack = @"menu_next_track";
static NSString *const kVibeMenuPreviousTrack = @"menu_previous_track";
static NSString *const kVibeMenuPlaySelected = @"menu_play_selected";
static NSString *const kVibeMenuSkipForward = @"menu_skip_forward";
static NSString *const kVibeMenuSkipForwardMore = @"menu_skip_forward_more";
static NSString *const kVibeMenuSkipForwardMost = @"menu_skip_forward_most";
static NSString *const kVibeMenuSkipBack = @"menu_skip_back";
static NSString *const kVibeMenuSkipBackMore = @"menu_skip_back_more";
static NSString *const kVibeMenuSkipBackMost = @"menu_skip_back_most";
static NSString *const kVibeMenuShuffle = @"menu_shuffle";
static NSString *const kVibeMenuRepeat = @"menu_repeat";

static NSString *const kVibeMenuFXLowKill = @"menu_fx_low_kill";
static NSString *const kVibeMenuFXLowKillBoost = @"menu_fx_low_kill_boost";
static NSString *const kVibeMenuFXReverb = @"menu_fx_reverb";
static NSString *const kVibeMenuFXDelay = @"menu_fx_delay";
static NSString *const kVibeMenuFXShortDelay = @"menu_fx_short_delay";

// The five effects in the FX menu's order, which the key monitor indexes its
// per-effect state by.
static inline NSArray<NSString *> *VibeFXMenuIdentifiers(void) {
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        identifiers = @[kVibeMenuFXLowKill, kVibeMenuFXLowKillBoost, kVibeMenuFXReverb,
                        kVibeMenuFXDelay, kVibeMenuFXShortDelay];
    });
    return identifiers;
}

static NSString *const kVibeMenuPitchRange8 = @"pitch_range_8";
static NSString *const kVibeMenuPitchRange16 = @"pitch_range_16";

static NSString *const kVibeMenuPlay = @"menu_play";
// Absent from the domains below: File > Open targets the app delegate.
static NSString *const kVibeMenuOpen = @"menu_open";
static NSString *const kVibeMenuSavePlaylist = @"menu_save_playlist";
static NSString *const kVibeMenuClose = @"menu_close";
static NSString *const kVibeMenuShowInFinder = @"show_in_finder";

static NSString *const kVibeMenuEditUndo = @"menu_edit_undo";
static NSString *const kVibeMenuEditRedo = @"menu_edit_redo";
static NSString *const kVibeMenuEditCopyFile = @"menu_edit_copy_file";
static NSString *const kVibeMenuEditCopyName = @"menu_edit_copy_name";
static NSString *const kVibeMenuEditRemoveFromPlaylist = @"menu_edit_remove_from_playlist";

// Also Cancel Conversion, swapped in validation as menu_play swaps to Pause;
// there is deliberately no menu_convert_cancel.
static NSString *const kVibeMenuConvertToFLAC = @"menu_convert_to_flac";
static NSString *const kVibeMenuConvertDeleteOriginal = @"menu_convert_delete_original";

// The Theme submenu; its items carry the prefix, and its Edit tail is the app
// delegate's.
static NSString *const kVibeMenuThemeSubmenu = @"view_theme";
static NSString *const kVibeMenuThemePrefix = @"view_theme_";
static NSString *const kVibeMenuEditThemes = @"menu_edit_themes";

// Identifiers derive from the preset, so the builder, the checkmark and the
// width lookup cannot disagree about a spelling.
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

// An identifier naming no preset answers Default.
static inline VibeWindowSizePreset VibeWindowSizePresetForMenuIdentifier(NSString *_Nullable identifier) {
    if ([identifier isEqualToString:VibeWindowSizeMenuIdentifier(VibeWindowSizePresetSmall)]) {
        return VibeWindowSizePresetSmall;
    }
    if ([identifier isEqualToString:VibeWindowSizeMenuIdentifier(VibeWindowSizePresetLarge)]) {
        return VibeWindowSizePresetLarge;
    }
    return VibeWindowSizePresetDefault;
}

// Matched by prefix. menu_edit_themes is absent: it targets the app delegate.
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
            || [identifier isEqualToString:kVibeMenuAlwaysOnTop]
            || [identifier isEqualToString:kVibeMenuLockWindowPosition]) {
        return VibeMenuValidationDomainViewToggle;
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
    if ([VibeFXMenuIdentifiers() containsObject:identifier]) {
        return VibeMenuValidationDomainFX;
    }
    if ([identifier isEqualToString:kVibeMenuPitchRange8]
            || [identifier isEqualToString:kVibeMenuPitchRange16]) {
        return VibeMenuValidationDomainPitchRange;
    }
    if ([identifier isEqualToString:kVibeMenuShuffle]
            || [identifier isEqualToString:kVibeMenuRepeat]) {
        return VibeMenuValidationDomainPlayOrder;
    }
    if ([identifier isEqualToString:kVibeMenuPlay]
            || [identifier isEqualToString:kVibeMenuSavePlaylist]
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

// Validation reads snapshots only; it never probes files or opens a window.
static inline BOOL VibeMenuHasVisibleSelection(BOOL keyWindow, BOOL playlistShown, NSInteger selectedRow) {
    return keyWindow && playlistShown && selectedRow >= 0;
}

static inline BOOL VibeTransportMenuEnabled(NSString *identifier, BOOL hasNext, BOOL hasPrevious,
        BOOL visibleSelection, BOOL hasTrack, BOOL stopped) {
    if ([identifier isEqualToString:kVibeMenuNextTrack]) return hasNext;
    if ([identifier isEqualToString:kVibeMenuPreviousTrack]) return hasPrevious;
    if ([identifier isEqualToString:kVibeMenuPlaySelected]) return visibleSelection;
    return VibeMenuValidationDomainForIdentifier(identifier) == VibeMenuValidationDomainTransport
            && hasTrack && !stopped;
}

static inline BOOL VibeFileMenuEnabled(NSString *identifier, NSUInteger count, BOOL keyWindow, BOOL hasURL) {
    if ([identifier isEqualToString:kVibeMenuSavePlaylist]) return keyWindow && count > 0;
    if ([identifier isEqualToString:kVibeMenuPlay] || [identifier isEqualToString:kVibeMenuClose]) return count > 0;
    return [identifier isEqualToString:kVibeMenuShowInFinder] && hasURL;
}

static inline BOOL VibeEditMenuEnabled(NSString *identifier, BOOL undoRedoInFlight,
        BOOL canUndo, BOOL canRedo, BOOL visibleSelection, BOOL hasTrack, BOOL hasURL) {
    if ([identifier isEqualToString:kVibeMenuEditUndo]) return !undoRedoInFlight && canUndo;
    if ([identifier isEqualToString:kVibeMenuEditRedo]) return !undoRedoInFlight && canRedo;
    if ([identifier isEqualToString:kVibeMenuEditRemoveFromPlaylist]) return visibleSelection;
    if ([identifier isEqualToString:kVibeMenuEditCopyFile]) return hasURL;
    return [identifier isEqualToString:kVibeMenuEditCopyName] && hasTrack;
}

static inline NSString *_Nullable VibeFileMenuTitle(NSString *identifier, NSUInteger count, BOOL playing) {
    if ([identifier isEqualToString:kVibeMenuPlay]) return playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
    if ([identifier isEqualToString:kVibeMenuClose]) return count > 1 ? STR_MENU_FILE_CLOSE_ALL : STR_MENU_FILE_CLOSE;
    return nil;
}

static inline NSString *VibeConvertMenuTitle(BOOL converting) {
    return converting ? STR_MENU_CONVERT_CANCEL : STR_MENU_CONVERT_TO_FLAC;
}

static inline SEL VibeConvertMenuAction(BOOL converting) {
    return NSSelectorFromString(converting ? @"cancelConversion:" : @"convertCurrentTrackToFLAC:");
}

NS_ASSUME_NONNULL_END
