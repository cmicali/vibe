//
//  SettingsThemesViewController+Editor.h
//  Vibe
//
//  The Themes pane's editor page. It edits whatever theme is active —
//  selection IS activation — so nothing is handed over on the page swap.
//  The Editor category builds the page. EditorActions holds its state and
//  actions, declared in SettingsThemesViewControllerInternal.h.
//

#import "SettingsThemesViewController.h"
#import "MainPlayerController+Settings.h"
#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SettingsThemesViewController (Editor)

// A hidden sibling of the section stack. Runs after loadPaneWithSections:.
- (void)buildEditorPage;

// Selects the jump bar's segment for the card at the top of the page.
- (void)syncEditorJumpSelection;

@end

// The placeholder changed, whichever field: the header and the rows redraw
// it.
static const VibeSettingsLiveEffect kVibeThemeDefaultArtworkEffect =
        VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance;

static inline VibeSettingsLiveEffect VibeThemeImageEditEffect(NSString *key) {
    if ([key isEqualToString:kVibeThemeImageAppIcon]) {
        return VibeSettingsLiveEffectAppIcon;
    }
    if ([key isEqualToString:kVibeThemeImageDefaultArtworkDark]
            || [key isEqualToString:kVibeThemeImageDefaultArtworkLight]) {
        return kVibeThemeDefaultArtworkEffect;
    }
    return VibeSettingsLiveEffectTransportButtons;
}

// A row's text is pushed by its row view, as its fill is drawn. A column's
// color is in the cell strings, which rebuild.
static inline VibeSettingsLiveEffect VibeThemePlaylistColorEditEffect(NSString *base) {
    if ([base isEqualToString:kVibeThemeColorPlaylistNumber]
            || [base isEqualToString:kVibeThemeColorPlaylistTitle]
            || [base isEqualToString:kVibeThemeColorPlaylistArtist]
            || [base isEqualToString:kVibeThemeColorPlaylistDuration]) {
        return VibeSettingsLiveEffectPlaylistAppearance;
    }
    return VibeSettingsLiveEffectPlaylistRowColors;
}

NS_ASSUME_NONNULL_END
