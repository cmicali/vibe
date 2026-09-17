//
//  SettingsAppearanceViewController+Editor.h
//  Vibe
//
//  The Appearance pane's editor page: the scrolled stack of themed rows that
//  swaps in over the theme list, its color wells, the image pickers
//  and the font panel. It edits whatever theme is active — the list's
//  selection IS activation — so nothing is handed over on the page swap; the
//  class file owns the list page, the swap itself and the theme file actions.
//

#import "SettingsAppearanceViewController.h"
#import "MainPlayerController+Settings.h"
#import "AppTheme.h"

NS_ASSUME_NONNULL_BEGIN

@interface SettingsAppearanceViewController (Editor) <NSFontChanging, NSTextFieldDelegate>

// Builds the editor container as a hidden sibling of the pane's section
// stack. Runs from loadView, after loadPaneWithSections: has set self.view.
- (void)buildEditorPage;

// Reloads every editor control from the working theme. The class file's
// refreshFromSettings calls it after the list half, then resolves layout.
- (void)refreshEditorFromSettings;

// Editor teardown: closes the font panel and deactivates every color well.
// Every caller is a page leave or a switch to a built-in.
- (void)closeEditorPanels;

// A detent slider with a fixed-width, right-aligned readout beside it — the
// shape the corner radius, the two waveform bar sliders and the list page's
// gain all take. The slider starts on its detent.
- (NSStackView *)detentSliderClusterWithDetent:(double)detent min:(double)min max:(double)max
                                        action:(SEL)action
                                        slider:(NSSlider *__strong _Nonnull *_Nonnull)outSlider
                                    valueLabel:(NSTextField *__strong _Nonnull *_Nonnull)outLabel;

// resolveLayoutStateFromSettings — the base class's layout-only hook — is
// implemented here as well: every conditional row the pane has is the
// editor's, and the pass ends in the class file's applyEditorVisibility.

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
