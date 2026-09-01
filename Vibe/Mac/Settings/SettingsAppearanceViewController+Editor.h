//
//  SettingsAppearanceViewController+Editor.h
//  Vibe
//
//  The Appearance pane's editor page: the scrolled stack of themed rows that
//  swaps in over the theme list, its color wells, the default-artwork pickers
//  and the font panel. It edits whatever theme is active — the list's
//  selection IS activation — so nothing is handed over on the page swap; the
//  class file owns the list page, the swap itself and the theme file actions.
//

#import "SettingsAppearanceViewController.h"

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

// resolveLayoutStateFromSettings — the base class's layout-only hook — is
// implemented here as well: every conditional row the pane has is the
// editor's, and the pass ends in the class file's applyEditorVisibility.

@end

NS_ASSUME_NONNULL_END
