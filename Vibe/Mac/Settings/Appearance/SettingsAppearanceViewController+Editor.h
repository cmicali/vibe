//
//  SettingsAppearanceViewController+Editor.h
//  Vibe
//
//  The Themes pane's editor page. It edits whatever theme is active —
//  selection IS activation — so nothing is handed over on the page swap.
//

#import "SettingsAppearanceViewController.h"
#import "MainPlayerController+Settings.h"
#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SettingsAppearanceViewController (Editor) <NSFontChanging, NSTextFieldDelegate>

// A hidden sibling of the section stack. Runs after loadPaneWithSections:.
- (void)buildEditorPage;

- (void)refreshEditorFromSettings;

// Closes the font panel and deactivates every color well.
- (void)closeEditorPanels;

// resolveLayoutStateFromSettings is implemented here too: every conditional
// row is the editor's. It ends in applyEditorVisibility.

@end

static inline VibeSettingsLiveEffect VibeThemeImageEditEffect(NSString *key) {
    if ([key isEqualToString:kVibeThemeImageAppIcon]) {
        return VibeSettingsLiveEffectAppIcon;
    }
    if ([key isEqualToString:kVibeThemeImageDefaultArtworkDark]
            || [key isEqualToString:kVibeThemeImageDefaultArtworkLight]) {
        return VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance;
    }
    return VibeSettingsLiveEffectTransportButtons;
}

NS_ASSUME_NONNULL_END
