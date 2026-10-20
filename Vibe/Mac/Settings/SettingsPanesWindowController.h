//
//  SettingsPanesWindowController.h
//  Vibe
//
//  A window of settings panes in the System Settings shape: a source-list
//  sidebar with search drives a tab-less tab controller of panes. It keeps
//  the back/forward history, the one resize funnel, the pane-title chain and
//  undo routing to the selected pane. It names nothing of the app's: a
//  subclass supplies the panes, pushes the strings in, and adds any toolbar
//  items of its own.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsPanesWindowController : NSWindowController <NSMenuItemValidation, NSToolbarDelegate>

// identifier is stable and unlocalized; a pane is selected by it. label
// names the sidebar row and the window, and symbolName draws the row's icon.
+ (NSTabViewItem *)paneItemWithViewController:(NSViewController *)pane identifier:(NSString *)identifier
                                        label:(NSString *)label symbolName:(NSString *)symbolName;

// The panes in sidebar order, grouped: the sidebar puts a spacer between
// groups. Back and Forward name the navigation pill's segments, Undo and
// Redo are the Edit menu's titles while the selected pane has nothing to
// undo, and the last two are the sidebar's search field and its empty state.
- (instancetype)initWithPaneGroups:(NSArray<NSArray<NSTabViewItem *> *> *)paneGroups
                         backTitle:(NSString *)backTitle forwardTitle:(NSString *)forwardTitle
                         undoTitle:(NSString *)undoTitle redoTitle:(NSString *)redoTitle
                 searchPlaceholder:(NSString *)searchPlaceholder noResultsText:(NSString *)noResultsText;

- (nullable NSTabViewItem *)tabItemWithIdentifier:(NSString *)identifier;
@property (readonly, nonatomic, nullable) NSTabViewItem *selectedTabItem;

- (void)refreshSelectedPane;

// Called by the sidebar and the tab controller before a pane is selected.
- (void)paneWillBecomeSelected:(NSTabViewItem *)item;

// The window refuses engine-driven size changes (SettingsWindow), so every
// programmatic resize must come through here.
- (void)applyWindowFrame:(NSRect)frame;

// The same funnel in content points, top-anchored.
- (void)applyContentSize:(NSSize)size;

// Records the location in the back/forward history and re-reads the
// selected pane's title. Called on every page swap and pane switch. A
// subclass with toolbar items of its own refreshes them here, after super.
- (void)updateNavigation;

// A location is a pane identifier, or "<identifier>/<page>" for a pane
// showing one of its pages (SettingsPaneViewController.currentPage). The
// page is set before the pane is selected, so the pane appears on it.
- (void)goToLocation:(NSString *)location;
@property (readonly, nonatomic, nullable) NSString *currentLocation;

// The toolbar's back/forward pill, across panes and their pages.
- (BOOL)canNavigateForward:(BOOL)forward;
- (void)navigateForward:(BOOL)forward;

// Edit > Undo's target while the window is key: the selected pane's own
// undo stack.
- (IBAction)undo:(nullable id)sender;
- (IBAction)redo:(nullable id)sender;

// Types query into the sidebar's search field, as a user would; answers the
// identifiers of the panes left in the sidebar.
- (NSArray<NSString *> *)searchSettingsFor:(NSString *)query;

@end

NS_ASSUME_NONNULL_END
