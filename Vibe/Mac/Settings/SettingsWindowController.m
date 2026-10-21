//
//  SettingsWindowController.m
//  Vibe
//

#import "SettingsWindowController.h"
#import "MenuValidationRules.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "MainMenuBuilder.h"
#import "MainPlayerController+Settings.h"
#import "SettingsAboutViewController.h"
#import "SettingsAdvancedViewController.h"
#import "SettingsAppearanceViewController.h"
#import "SettingsAudioOutputViewController.h"
#import "SettingsFilesViewController.h"
#import "SettingsGeneralViewController.h"
#import "SettingsPlaybackViewController.h"
#import "SettingsShortcutsViewController.h"
#import "SettingsThemesViewController.h"
#import "NSView+DarkMode.h"
#import "VibeStrings.h"

static NSString *const kThemesPaneIdentifier = @"themes";

// The Keyboard Shortcuts pane over the menu's commands and the player's one
// write path for shortcuts.
static SettingsShortcutsViewController *ShortcutsPane(MainPlayerController *playerController,
                                                      void (^sink)(NSUInteger)) {
    __weak MainPlayerController *weakPlayer = playerController;
    SettingsShortcutsViewController *pane = [[SettingsShortcutsViewController alloc]
            initWithEffectsSink:sink
                    commandRows:^{ return MainMenuBuilder.shortcutCommandRows; }
             shortcutForCommand:^(NSString *identifier) {
                 return [MainMenuBuilder carriedShortcutForIdentifier:identifier
                                                            overrides:AppSettings.sharedInstance.shortcutOverrides];
             }
                      overrides:^{ return AppSettings.sharedInstance.shortcutOverrides; }
                   setOverrides:^(NSDictionary<NSString *, NSNumber *> *overrides) {
                       [weakPlayer setShortcutOverrides:overrides];
                   }
                         assign:^(VibeShortcut shortcut, NSString *identifier, NSString **loser) {
                             return [weakPlayer assignShortcut:shortcut toCommand:identifier loser:loser];
                         }];
    pane.commandColumnTitle = STR_SETTINGS_SHORTCUTS_COLUMN_COMMAND;
    pane.shortcutColumnTitle = STR_SETTINGS_SHORTCUTS_COLUMN_SHORTCUT;
    pane.recordTitle = STR_SETTINGS_SHORTCUTS_RECORD;
    pane.clearTitle = STR_BUTTON_CLEAR;
    pane.resetAllTitle = STR_SETTINGS_SHORTCUTS_RESET_ALL;
    pane.explainer = STR_SETTINGS_SHORTCUTS_EXPLAIN;
    pane.layoutNote = STR_SETTINGS_SHORTCUTS_LAYOUT_NOTE;
    pane.selectTip = STR_SETTINGS_SHORTCUTS_SELECT_TIP;
    pane.noneTip = STR_SETTINGS_SHORTCUTS_NONE_TIP;
    pane.defaultsTip = STR_SETTINGS_SHORTCUTS_DEFAULTS_TIP;
    pane.undoActionName = STR_SETTINGS_SHORTCUTS_UNDO_ACTION;
    pane.recordingFormat = STR_SETTINGS_SHORTCUTS_RECORDING;
    pane.reservedFormat = STR_SETTINGS_SHORTCUTS_RESERVED;
    pane.unusableCaption = STR_SETTINGS_SHORTCUTS_UNUSABLE;
    pane.reassignedFormat = STR_SETTINGS_SHORTCUTS_REASSIGNED;
    return pane;
}

@implementation SettingsWindowController {
    NSSegmentedControl *_appearanceToggle;
    NSSegmentedControl *_randomizeControl;
    // Undo and redo, apart from the dice: a missed undo must not reroll the theme.
    NSSegmentedControl *_historyControl;
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController {
    // Every pane's effects sink: the player applies the stored state the bits
    // name (MainPlayerController+Settings).
    __weak MainPlayerController *weakPlayer = playerController;
    void (^sink)(NSUInteger) = ^(NSUInteger effects) {
        [weakPlayer applySettingsLiveEffects:(VibeSettingsLiveEffect)effects];
    };
    Class window = SettingsPanesWindowController.class;
    NSArray<NSArray<NSTabViewItem *> *> *groups = @[
        @[
            [window paneItemWithViewController:[[SettingsGeneralViewController alloc] initWithEffectsSink:sink]
                                    identifier:@"general" label:STR_SETTINGS_GENERAL symbolName:@"gearshape"],
            [window paneItemWithViewController:[[SettingsThemesViewController alloc] initWithEffectsSink:sink]
                                    identifier:kThemesPaneIdentifier label:STR_SETTINGS_THEMES_SECTION
                                    symbolName:@"paintpalette"],
            [window paneItemWithViewController:[[SettingsAppearanceViewController alloc] initWithEffectsSink:sink]
                                    identifier:@"appearance" label:STR_MENU_VIEW_APPEARANCE
                                    symbolName:@"circle.lefthalf.filled"],
        ],
        @[
            [window paneItemWithViewController:[[SettingsPlaybackViewController alloc] initWithEffectsSink:sink]
                                    identifier:@"playback" label:STR_MENU_PLAYBACK symbolName:@"play.circle"],
            [window paneItemWithViewController:[[SettingsAudioOutputViewController alloc]
                                                       initWithPlayerController:playerController effectsSink:sink]
                                    identifier:@"audio" label:STR_SETTINGS_AUDIO_SECTION symbolName:@"speaker.wave.2"],
            [window paneItemWithViewController:[[SettingsFilesViewController alloc] initWithEffectsSink:sink]
                                    identifier:@"files" label:STR_SETTINGS_FILES symbolName:@"folder"],
        ],
        @[
            [window paneItemWithViewController:ShortcutsPane(playerController, sink)
                                    identifier:@"shortcuts" label:STR_SETTINGS_SHORTCUTS symbolName:@"keyboard"],
        ],
        @[
            [window paneItemWithViewController:[[SettingsAdvancedViewController alloc]
                                                       initWithPlayerController:playerController effectsSink:sink]
                                    identifier:@"advanced" label:STR_SETTINGS_ADVANCED symbolName:@"gearshape.2"],
            [window paneItemWithViewController:[[SettingsAboutViewController alloc] initWithEffectsSink:sink]
                                    identifier:@"about" label:STR_SETTINGS_ABOUT symbolName:@"info.circle"],
        ],
    ];
    self = [super initWithPaneGroups:groups
                           backTitle:STR_SETTINGS_NAV_BACK forwardTitle:STR_SETTINGS_NAV_FORWARD
                           undoTitle:STR_MENU_EDIT_UNDO redoTitle:STR_MENU_EDIT_REDO
                   searchPlaceholder:STR_SETTINGS_SEARCH_PLACEHOLDER noResultsText:STR_SETTINGS_SEARCH_NO_RESULTS];
    if (self) {
        // Before the window first shows, so the frame Vibe saved restores.
        self.windowFrameAutosaveName = @"SettingsWindow";
        // Under Auto, the preview toggle shows the system's side, so an OS
        // flip must re-resolve it.
        [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:NULL];
        [self updateNavigation];
    }
    return self;
}

- (void)dealloc {
    [NSApp removeObserver:self forKeyPath:@"effectiveAppearance"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    // Selecting the pane or opening the window re-reads it on the way in.
    if (!self.window.isVisible || ![self themesPaneIsSelected]) {
        return;
    }
    [self updateNavigation];
}

#pragma mark - The panes

- (NSTabViewItem *)themesTabItem {
    return [self tabItemWithIdentifier:kThemesPaneIdentifier];
}

- (SettingsThemesViewController *)themesPane {
    return (SettingsThemesViewController *)[self themesTabItem].viewController;
}

- (SettingsAudioOutputViewController *)audioPane {
    SettingsAudioOutputViewController *pane =
            (SettingsAudioOutputViewController *)[self tabItemWithIdentifier:@"audio"].viewController;
    return pane.isViewLoaded && pane.view.window.isVisible ? pane : nil;
}

- (BOOL)themesPaneIsSelected {
    NSTabViewItem *item = [self themesTabItem];
    return item != nil && self.selectedTabItem == item;
}

// Back from the editor is the theme list however it was reached: from the
// menu the list was never shown, so it is recorded on the way in.
- (void)showThemeEditor {
    NSString *editor = [NSString stringWithFormat:@"%@/%@", kThemesPaneIdentifier, kVibeThemeEditorPage];
    if ([self.currentLocation isEqualToString:editor]) {
        return;
    }
    [self goToLocation:kThemesPaneIdentifier];
    [self goToLocation:editor];
}

#pragma mark - The Themes pane's toolbar items

static NSToolbarItemIdentifier const kAppearanceToggleItemIdentifier = @"appearance_toggle";
static NSToolbarItemIdentifier const kRandomizeItemIdentifier = @"theme_randomize";
static NSToolbarItemIdentifier const kHistoryItemIdentifier = @"theme_history";

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [[super toolbarAllowedItemIdentifiers:toolbar] arrayByAddingObjectsFromArray:
            @[kRandomizeItemIdentifier, kHistoryItemIdentifier, kAppearanceToggleItemIdentifier]];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:kRandomizeItemIdentifier]) {
        NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"dice"
                          accessibilityDescription:STR_SETTINGS_THEME_RANDOMIZE_SETTINGS],
                [NSImage imageWithSystemSymbolName:@"paintpalette"
                          accessibilityDescription:STR_SETTINGS_THEME_RANDOMIZE_COLORS]]
                trackingMode:NSSegmentSwitchTrackingMomentary
                      target:self action:@selector(randomizeTheme:)];
        [control setToolTip:STR_SETTINGS_THEME_RANDOMIZE_SETTINGS forSegment:0];
        [control setToolTip:STR_SETTINGS_THEME_RANDOMIZE_COLORS forSegment:1];
        _randomizeControl = control;
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.view = control;
        item.label = STR_SETTINGS_THEME_RANDOMIZE;
        return item;
    }
    if ([itemIdentifier isEqualToString:kHistoryItemIdentifier]) {
        NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"arrow.uturn.backward"
                          accessibilityDescription:STR_MENU_EDIT_UNDO],
                [NSImage imageWithSystemSymbolName:@"arrow.uturn.forward"
                          accessibilityDescription:STR_MENU_EDIT_REDO]]
                trackingMode:NSSegmentSwitchTrackingMomentary
                      target:self action:@selector(restoreThemeHistory:)];
        [control setToolTip:STR_MENU_EDIT_UNDO forSegment:0];
        [control setToolTip:STR_MENU_EDIT_REDO forSegment:1];
        _historyControl = control;
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.view = control;
        item.label = STR_MENU_EDIT_UNDO;
        return item;
    }
    if ([itemIdentifier isEqualToString:kAppearanceToggleItemIdentifier]) {
        NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"sun.max"
                          accessibilityDescription:STR_MENU_APPEARANCE_LIGHT],
                [NSImage imageWithSystemSymbolName:@"moon"
                          accessibilityDescription:STR_MENU_APPEARANCE_DARK]]
                trackingMode:NSSegmentSwitchTrackingSelectOne
                      target:self action:@selector(toggleAppearancePreview:)];
        _appearanceToggle = control;
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.view = control;
        item.label = STR_SETTINGS_THEME_PREVIEW;
        control.accessibilityLabel = STR_SETTINGS_THEME_PREVIEW;
        [control setToolTip:STR_SETTINGS_THEME_PREVIEW forSegment:0];
        [control setToolTip:STR_SETTINGS_THEME_PREVIEW forSegment:1];
        return item;
    }
    return [super toolbar:toolbar itemForItemIdentifier:itemIdentifier willBeInsertedIntoToolbar:flag];
}

static NSString *ThemeHistoryTitle(BOOL forward) {
    AppSettings *settings = AppSettings.sharedInstance;
    if (forward) {
        return settings.themeRedoRemovesTheme ? STR_SETTINGS_THEME_REDO_REMOVE : STR_SETTINGS_THEME_REDO_EDIT;
    }
    return settings.themeUndoRemovesTheme ? STR_SETTINGS_THEME_UNDO_REMOVE : STR_SETTINGS_THEME_UNDO_EDIT;
}

- (void)updateNavigation {
    [super updateNavigation];
    SettingsThemesViewController *pane = [self themesPane];
    BOOL selected = [self themesPaneIsSelected];
    // Inserted and removed, never hidden: NSToolbarItem.hidden needs macOS 15,
    // and the delegate vends non-inserted copies during enumeration, so a
    // stored item is not reliably the one on screen.
    NSToolbar *toolbar = self.window.toolbar;
    for (NSToolbarItemIdentifier identifier in @[kRandomizeItemIdentifier, kHistoryItemIdentifier,
                                                 kAppearanceToggleItemIdentifier]) {
        NSUInteger index = [toolbar.items indexOfObjectPassingTest:
                ^BOOL(NSToolbarItem *item, NSUInteger i, BOOL *stop) {
            return [item.itemIdentifier isEqualToString:identifier];
        }];
        if (selected && index == NSNotFound) {
            [toolbar insertItemWithItemIdentifier:identifier atIndex:(NSInteger)toolbar.items.count];
        } else if (!selected && index != NSNotFound) {
            [toolbar removeItemAtIndex:(NSInteger)index];
        }
    }
    BOOL canRandomize = selected && pane.editorShown;
    [_randomizeControl setEnabled:canRandomize forSegment:0];
    [_randomizeControl setEnabled:canRandomize forSegment:1];
    [_historyControl setEnabled:(selected && [pane canRestoreThemeHistoryForward:NO]) forSegment:0];
    [_historyControl setEnabled:(selected && [pane canRestoreThemeHistoryForward:YES]) forSegment:1];
    [_historyControl setToolTip:ThemeHistoryTitle(NO) forSegment:0];
    [_historyControl setToolTip:ThemeHistoryTitle(YES) forSegment:1];
    // windowAppearance folds in the preview and a single-mode pin; nil is Auto.
    NSAppearance *appearance =
            AppSettings.sharedInstance.windowAppearance ?: NSApp.effectiveAppearance;
    _appearanceToggle.selectedSegment = appearance.isDark ? 1 : 0;
    BOOL canPreview = AppSettings.sharedInstance.currentTheme.requiredWindowAppearance == nil;
    [_appearanceToggle setEnabled:canPreview forSegment:0];
    [_appearanceToggle setEnabled:canPreview forSegment:1];
}

- (void)toggleAppearancePreview:(id)sender {
    [[self themesPane] previewAppearanceDark:(_appearanceToggle.selectedSegment == 1)];
}

- (void)randomizeTheme:(NSSegmentedControl *)sender {
    SettingsThemesViewController *pane = [self themesPane];
    if (sender.selectedSegment == 0) [pane randomizeThemeSettings];
    else [pane randomizeThemeColors];
}

- (void)restoreThemeHistory:(NSSegmentedControl *)sender {
    [[self themesPane] restoreThemeHistoryForward:sender.selectedSegment == 1];
}

#pragma mark - Menu

// Catches the nil-targeted ⌘W ahead of the player's, which clears the playlist.
- (IBAction)closeFile:(nullable id)sender {
    [self.window performClose:sender];
}

// Edit > Undo is the theme history while Themes is selected, on either page.
- (IBAction)undo:(id)sender {
    if ([self themesPaneIsSelected]) [self.themesPane restoreThemeHistoryForward:NO];
    else [super undo:sender];
}

- (IBAction)redo:(id)sender {
    if ([self themesPaneIsSelected]) [self.themesPane restoreThemeHistoryForward:YES];
    else [super redo:sender];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ((menuItem.action == @selector(undo:) || menuItem.action == @selector(redo:))
            && [self themesPaneIsSelected]) {
        BOOL forward = menuItem.action == @selector(redo:);
        menuItem.title = ThemeHistoryTitle(forward);
        return [self.themesPane canRestoreThemeHistoryForward:forward];
    }
    // The one Close item may have been retitled by the player's validation.
    if ([menuItem.identifier isEqualToString:kVibeMenuClose]) {
        menuItem.title = STR_MENU_FILE_CLOSE;
    }
    return [super validateMenuItem:menuItem];
}

@end
