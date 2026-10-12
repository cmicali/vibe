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
