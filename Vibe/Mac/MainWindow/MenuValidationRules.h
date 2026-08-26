//
//  MenuValidationRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Every menu identifier MainPlayerController validates, and the domain that
// decides it. This is the single home of those literals: the builder mints
// them, validateMenuItem: dispatches on them, and contentWidthForSizeIdentifier:
// sizes the window from them, so a rename that misses a site is a compile error
// rather than a silently unvalidated item.
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
    // Convert to FLAC and its preference. AudioFileConverter stays the
    // authority for the enablement and the retitling.
    VibeMenuValidationDomainConvert,
    // menuNeedsUpdate: mints these and owns their state, title and target.
    VibeMenuValidationDomainWaveformStyle,
};

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

// The dynamic style items carry the style's own identifier as a suffix, so the
// family is matched by prefix rather than enumerated.
static inline NSString *VibeWaveformStyleMenuIdentifier(NSString *style) {
    return [@"waveform_style_" stringByAppendingString:style];
}

static inline VibeMenuValidationDomain VibeMenuValidationDomainForIdentifier(NSString *_Nullable identifier) {
    if (identifier.length == 0) {
        return VibeMenuValidationDomainUnknown;
    }
    if ([identifier hasPrefix:@"view_size_"]) {
        return VibeMenuValidationDomainWindowSize;
    }
    if ([identifier hasPrefix:@"waveform_style_"]) {
        return VibeMenuValidationDomainWaveformStyle;
    }
    if ([identifier isEqualToString:@"menu_show_playlist"]
            || [identifier isEqualToString:@"menu_show_pitch"]
            || [identifier isEqualToString:@"menu_show_file_info"]
            || [identifier isEqualToString:@"menu_always_on_top"]) {
        return VibeMenuValidationDomainViewToggle;
    }
    if ([identifier isEqualToString:@"view_appearance_system_default"]
            || [identifier isEqualToString:@"view_appearance_light"]
            || [identifier isEqualToString:@"view_appearance_dark"]) {
        return VibeMenuValidationDomainAppearance;
    }
    if ([identifier isEqualToString:@"menu_next_track"]
            || [identifier isEqualToString:@"menu_previous_track"]
            || [identifier isEqualToString:@"menu_play_selected"]
            || [identifier isEqualToString:@"menu_skip_forward"]
            || [identifier isEqualToString:@"menu_skip_forward_more"]
            || [identifier isEqualToString:@"menu_skip_forward_most"]
            || [identifier isEqualToString:@"menu_skip_back"]
            || [identifier isEqualToString:@"menu_skip_back_more"]
            || [identifier isEqualToString:@"menu_skip_back_most"]) {
        return VibeMenuValidationDomainTransport;
    }
    if ([identifier isEqualToString:@"menu_fx_low_kill"]
            || [identifier isEqualToString:@"menu_fx_low_kill_boost"]
            || [identifier isEqualToString:@"menu_fx_reverb"]
            || [identifier isEqualToString:@"menu_fx_delay"]
            || [identifier isEqualToString:@"menu_fx_short_delay"]) {
        return VibeMenuValidationDomainFX;
    }
    if ([identifier isEqualToString:@"pitch_range_8"]
            || [identifier isEqualToString:@"pitch_range_16"]) {
        return VibeMenuValidationDomainPitchRange;
    }
    if ([identifier isEqualToString:@"menu_play"]
            || [identifier isEqualToString:@"menu_close"]
            || [identifier isEqualToString:@"show_in_finder"]) {
        return VibeMenuValidationDomainFile;
    }
    if ([identifier isEqualToString:@"menu_edit_undo"]
            || [identifier isEqualToString:@"menu_edit_redo"]
            || [identifier isEqualToString:@"menu_edit_copy_file"]
            || [identifier isEqualToString:@"menu_edit_copy_name"]
            || [identifier isEqualToString:@"menu_edit_remove_from_playlist"]) {
        return VibeMenuValidationDomainEdit;
    }
    if ([identifier isEqualToString:@"menu_convert_to_flac"]
            || [identifier isEqualToString:@"menu_convert_delete_original"]) {
        return VibeMenuValidationDomainConvert;
    }
    return VibeMenuValidationDomainUnknown;
}

NS_ASSUME_NONNULL_END
