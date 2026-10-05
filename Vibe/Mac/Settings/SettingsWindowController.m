//
//  SettingsWindowController.m
//  Vibe
//

#import "SettingsWindowController.h"
#import "MenuValidationRules.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "MainPlayerController+Settings.h"
#import "SettingsAboutViewController.h"
#import "SettingsAdvancedViewController.h"
#import "SettingsAppearanceViewController.h"
#import "SettingsFilesViewController.h"
#import "SettingsGeneralViewController.h"
#import "SettingsPaneViewController.h"
#import "SettingsPlaybackViewController.h"
#import "SettingsShortcutsViewController.h"
#import "NSView+DarkMode.h"
#import "VibeStrings.h"

static const CGFloat kSettingsSidebarWidth = 200;
// The theme editor's place in the back/forward history; every other location
// is a pane identifier.
static NSString *const kEditorLocation = @"themes/editor";

@class SettingsSidebarController;

@interface SettingsWindowController () <NSMenuItemValidation, NSToolbarDelegate> {
    NSTabViewController *_tabs;
    SettingsSidebarController *_sidebar;
    NSSegmentedControl *_navigationControl;
    // System Settings' history: a location is a pane identifier, with
    // "/editor" while the theme editor shows. Back and Forward walk it.
    NSString *_location;
    NSMutableArray<NSString *> *_backLocations, *_forwardLocations;
    // Set while a location is applied: the pane switch's own refreshes would
    // otherwise record its half-applied states (the Themes pane with the
    // previous page) and clear Forward.
    BOOL _restoringLocation;
    NSSegmentedControl *_appearanceToggle;
    NSSegmentedControl *_randomizeControl;
}
- (void)paneWillBecomeSelected:(NSTabViewItem *)item;
@end

// AppKit re-sizes a contentViewController window to its content's fitting
// size after layout passes, through setFrame:display:, and every constraint
// priority that defeats that snap also collapses the user's resize range. So
// a size change lands only from a live resize, inside resizeUnlocked:, or
// before the window is visible. Moves always pass; zoom is refused.
@interface SettingsWindow : NSWindow
- (void)resizeUnlocked:(void (^)(void))block;
@end

@implementation SettingsWindow {
    BOOL _resizeUnlocked;
}

- (IBAction)undo:(id)sender {
    if ([self.firstResponder isKindOfClass:NSTextView.class]) {
        [self.firstResponder.undoManager undo];
    } else {
        [NSApp sendAction:@selector(undo:) to:self.windowController from:sender];
    }
}

- (IBAction)redo:(id)sender {
    if ([self.firstResponder isKindOfClass:NSTextView.class]) {
        [self.firstResponder.undoManager redo];
    } else {
        [NSApp sendAction:@selector(redo:) to:self.windowController from:sender];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(undo:) || item.action == @selector(redo:)) {
        if ([self.firstResponder isKindOfClass:NSTextView.class]) {
            NSUndoManager *manager = self.firstResponder.undoManager;
            BOOL redo = item.action == @selector(redo:);
            item.title = redo ? manager.redoMenuItemTitle : manager.undoMenuItemTitle;
            return redo ? manager.canRedo : manager.canUndo;
        }
        return [(id<NSMenuItemValidation>)self.windowController validateMenuItem:item];
    }
    return [super validateMenuItem:item];
}

// Block-scoped and synchronous: the snap fires in the next layout flush, so a
// time-boxed unlock re-admits it, and an animator's later frames would arrive
// locked out.
- (void)resizeUnlocked:(void (^)(void))block {
    _resizeUnlocked = YES;
    block();
    _resizeUnlocked = NO;
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)flag {
    // isVisible is NO while miniaturized, but the snap still fires in the Dock.
    if (!NSEqualSizes(frameRect.size, self.frame.size)
            && (self.isVisible || self.isMiniaturized)
            && !self.inLiveResize && !_resizeUnlocked
            && ![self appKitIsRescuingOntoScreen:frameRect]) {
        return;
    }
    [super setFrame:frameRect display:flag];
}

// A display disconnect or resolution drop: the window is off every screen and
// AppKit is pulling it back. The snap never moves a window off-screen, so it
// cannot pass here. An accessibility window-manager resize stays refused.
- (BOOL)appKitIsRescuingOntoScreen:(NSRect)proposed {
    BOOL currentOnScreen = NO, proposedFits = NO;
    for (NSScreen *screen in NSScreen.screens) {
        // Intersection, not containment: a window straddling two displays is
        // contained by neither.
        if (NSIntersectsRect(screen.visibleFrame, self.frame)) {
            currentOnScreen = YES;
        }
        if (NSContainsRect(screen.visibleFrame, proposed)) {
            proposedFits = YES;
        }
    }
    return !currentOnScreen && proposedFits;
}

@end

// AppKit resizes the window as soon as its contentViewController's
// preferredContentSize changes, and the split controller adopts one from its
// children's fitting sizes on layout.
@interface SettingsSplitViewController : NSSplitViewController
@end

@implementation SettingsSplitViewController

- (void)setPreferredContentSize:(NSSize)preferredContentSize {
}

// Assigning contentViewController after init does not bind the window title.
- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    self.view.window.title = title ?: @"";
}

@end

#pragma mark - Sidebar

// Rows come from the tab controller's items, so the two cannot drift. A group
// starts at each of these panes, after a spacer row.
static NSSet<NSString *> *SidebarGroupStarts(void) {
    return [NSSet setWithArray:@[@"playback", @"shortcuts", @"advanced"]];
}

static const CGFloat kSidebarSpacerHeight = 12;

@interface SettingsSidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate,
                                                         NSSearchFieldDelegate>
@property (weak, nonatomic) NSTabViewController *tabs;
@property (readonly, nonatomic) NSTableView *tableView;
@property (readonly, nonatomic) NSSearchField *searchField;
// Moves the highlighted row; a pane the search hides selects nothing.
- (void)selectRowForTabItem:(NSTabViewItem *)item;
// Rebuilds the rows from the search field: matching panes only, ungrouped.
- (void)reloadRows;
- (void)searchChanged:(nullable id)sender;
- (NSArray<NSString *> *)visiblePaneIdentifiers;
@end

// Tinted through backgroundStyle, which the row view pushes on mouse-down;
// tableViewSelectionDidChange: waits for mouse-up.
@interface SettingsSidebarCellView : NSTableCellView
@end

@implementation SettingsSidebarCellView

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    self.imageView.contentTintColor =
            backgroundStyle == NSBackgroundStyleEmphasized ? NSColor.whiteColor : nil;
}

@end

@implementation SettingsSidebarController {
    NSTableView *_tableView;
    NSSearchField *_searchField;
    NSTextField *_noResultsLabel;
    // A tab item per row, NSNull for a group's spacer.
    NSArray *_rows;
    // TRAP: the reload and reselection post selection changes; treated as the
    // user's, one would switch panes under the search being typed.
    BOOL _reloadingRows;
}

- (NSTableView *)tableView {
    (void)self.view;
    return _tableView;
}

- (NSSearchField *)searchField {
    (void)self.view;
    return _searchField;
}

- (void)loadView {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.style = NSTableViewStyleSourceList;
    table.headerView = nil;
    table.rowHeight = 28;
    table.allowsEmptySelection = YES;
    table.allowsMultipleSelection = NO;
    table.focusRingType = NSFocusRingTypeNone;
    [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"pane"]];
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.action = @selector(sidebarClicked:);
    _tableView = table;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = STR_SETTINGS_SEARCH_PLACEHOLDER;
    _searchField.delegate = self;
    _searchField.target = self;
    _searchField.action = @selector(searchChanged:);
    _searchField.sendsSearchStringImmediately = YES;

    _noResultsLabel = [NSTextField labelWithString:STR_SETTINGS_SEARCH_NO_RESULTS];
    _noResultsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _noResultsLabel.textColor = NSColor.secondaryLabelColor;
    _noResultsLabel.hidden = YES;

    NSView *view = [[NSView alloc] initWithFrame:NSZeroRect];
    [view addSubview:_searchField];
    [view addSubview:scroll];
    [view addSubview:_noResultsLabel];
    [NSLayoutConstraint activateConstraints:@[
        [_searchField.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor constant:8],
        [_searchField.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:10],
        [_searchField.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-10],
        [scroll.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        [_noResultsLabel.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:16],
        [_noResultsLabel.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
    ]];
    self.view = view;
    [self reloadRows];
}

#pragma mark Rows

- (NSString *)query {
    return [_searchField.stringValue stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (void)reloadRows {
    NSString *query = [self query];
    NSMutableArray *rows = [NSMutableArray array];
    NSSet<NSString *> *groupStarts = SidebarGroupStarts();
    for (NSTabViewItem *item in self.tabs.tabViewItems) {
        if (query.length) {
            SettingsPaneViewController *pane = (SettingsPaneViewController *)item.viewController;
            if ([pane isKindOfClass:SettingsPaneViewController.class] && [pane matchesSearch:query]) {
                [rows addObject:item];
            }
            continue;
        }
        if (rows.count && [groupStarts containsObject:item.identifier]) {
            [rows addObject:NSNull.null];
        }
        [rows addObject:item];
    }
    _rows = rows;
    _noResultsLabel.hidden = query.length == 0 || rows.count > 0;
    _reloadingRows = YES;
    [_tableView reloadData];
    [self selectRowForTabItem:self.tabs.tabView.selectedTabViewItem];
    _reloadingRows = NO;
}

- (void)selectRowForTabItem:(NSTabViewItem *)item {
    NSUInteger row = item ? [_rows indexOfObjectIdenticalTo:item] : NSNotFound;
    if (row == NSNotFound) {
        [_tableView deselectAll:nil];
    } else if (_tableView.selectedRow != (NSInteger)row) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }
}

// Typing narrows the list; the pane on screen stays unless it no longer
// matches, when the first match takes over so its rows can show the hits.
- (void)searchChanged:(id)sender {
    [self reloadRows];
    NSString *query = [self query];
    if (query.length && _tableView.selectedRow < 0 && _rows.count) {
        [self.tabs.tabView selectTabViewItem:_rows.firstObject];
    }
    for (NSTabViewItem *item in self.tabs.tabViewItems) {
        SettingsPaneViewController *pane = (SettingsPaneViewController *)item.viewController;
        if ([pane isKindOfClass:SettingsPaneViewController.class]) {
            [pane setSearchHighlight:query.length ? query : nil];
        }
    }
}

- (NSArray<NSString *> *)visiblePaneIdentifiers {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (id row in _rows) {
        if (row != NSNull.null) {
            [identifiers addObject:((NSTabViewItem *)row).identifier];
        }
    }
    return identifiers;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_rows.count;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    return _rows[(NSUInteger)row] == NSNull.null ? kSidebarSpacerHeight : tableView.rowHeight;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return _rows[(NSUInteger)row] != NSNull.null;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (_rows[(NSUInteger)row] == NSNull.null) {
        return nil;
    }
    SettingsSidebarCellView *cell = [tableView makeViewWithIdentifier:@"pane" owner:nil];
    if (!cell) {
        cell = [[SettingsSidebarCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"pane";
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [NSFont systemFontOfSize:13];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:icon];
        [cell addSubview:label];
        cell.imageView = icon;
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:20],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    NSTabViewItem *item = _rows[(NSUInteger)row];
    cell.imageView.image = item.image;
    cell.textField.stringValue = item.label ?: @"";
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [SettingsAccentRowView new];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_reloadingRows) {
        return;
    }
    NSInteger row = _tableView.selectedRow;
    if (row < 0) {
        // A click below the rows; the pane on screen keeps its row.
        [self selectRowForTabItem:self.tabs.tabView.selectedTabViewItem];
        return;
    }
    NSTabViewItem *item = _rows[(NSUInteger)row];
    if (item != self.tabs.tabView.selectedTabViewItem) {
        [self.tabs.tabView selectTabViewItem:item];
    }
}

- (void)sidebarClicked:(NSTableView *)sender {
    NSInteger row = sender.clickedRow;
    if (row < 0 || _rows[(NSUInteger)row] != self.tabs.tabView.selectedTabViewItem) {
        return;
    }
    // Clicking the selected row does not post a selection change.
    SettingsWindowController *controller =
            (SettingsWindowController *)self.view.window.windowController;
    [controller paneWillBecomeSelected:_rows[(NSUInteger)row]];
}

@end

#pragma mark - Tab controller

// Also syncs the sidebar, so a programmatic selection (settings_open) moves
// the highlighted row.
@interface SettingsTabViewController : NSTabViewController <SettingsPaneSizeHost>
@property (weak, nonatomic) SettingsSidebarController *sidebar;
@end

@implementation SettingsTabViewController

// AppKit would resize the window immediately, ahead of the animated resize.
- (void)setPreferredContentSize:(NSSize)preferredContentSize {
}

- (void)tabView:(NSTabView *)tabView willSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    SettingsWindowController *controller =
            (SettingsWindowController *)self.view.window.windowController;
    if ([controller isKindOfClass:SettingsWindowController.class]) {
        [controller paneWillBecomeSelected:tabViewItem];
    }
    [super tabView:tabView willSelectTabViewItem:tabViewItem];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    [super tabView:tabView didSelectTabViewItem:tabViewItem];
    NSViewController *pane = tabViewItem.viewController;
    if (!pane) {
        return;
    }
    [self.sidebar selectRowForTabItem:tabViewItem];
    self.parentViewController.title = pane.title;
    SettingsWindowController *controller =
            (SettingsWindowController *)self.view.window.windowController;
    if ([controller isKindOfClass:SettingsWindowController.class]) {
        [controller updateNavigation];
    }
}

// Runs inside the animation transaction paneContentDidChange opened.
- (void)settingsPaneSizeDidChange {
    NSInteger index = self.selectedTabViewItemIndex;
    if (index < 0 || index >= (NSInteger)self.tabViewItems.count) {
        return;
    }
    [self resizeWindowToPaneSize:self.tabViewItems[(NSUInteger)index].viewController];
}

// The floor needs a laid-out window for the titlebar height.
- (void)viewDidAppear {
    [super viewDidAppear];
    [self settingsPaneSizeDidChange];
}

- (void)resizeWindowToPaneSize:(NSViewController *)pane {
    NSWindow *window = self.view.window;
    if (![pane isKindOfClass:SettingsPaneViewController.class] || !window) {
        return;
    }
    // The shared size is the window's FLOOR: grow an undersized window, never
    // shrink one the user enlarged. Computed from the engine's own numbers,
    // since anything else is re-snapped by the next flush.
    NSSize paneSize = ((SettingsPaneViewController *)pane).sharedPaneSize;
    CGFloat leading = NSMinX([self.view convertRect:self.view.bounds toView:nil]);
    NSRect content = [window contentRectForFrameRect:window.frame];
    CGFloat titlebar = NSHeight(content) - NSHeight(window.contentLayoutRect);
    NSSize minContent = NSMakeSize(leading + paneSize.width, paneSize.height + titlebar);
    window.contentMinSize = minContent;
    [(SettingsWindowController *)window.windowController applyContentSize:
            NSMakeSize(MAX(minContent.width, content.size.width),
                       MAX(minContent.height, content.size.height))];
}

@end

#pragma mark - Window controller

@implementation SettingsWindowController

// identifier is stable and unlocalized; settings_open selects by it.
static NSTabViewItem *PaneItem(NSViewController *pane, NSString *identifier,
                               NSString *label, NSString *symbolName) {
    pane.title = label;
    NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:pane];
    item.identifier = identifier;
    item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:label];
    return item;
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController {
    SettingsTabViewController *tabs = [[SettingsTabViewController alloc] init];
    tabs.tabStyle = NSTabViewControllerTabStyleUnspecified;
    // The default crossfade composites two panes' section headers and flashes.
    tabs.transitionOptions = NSViewControllerTransitionNone;
    tabs.tabView.tabViewType = NSNoTabsNoBorder;

    // Grouped in the sidebar by SidebarGroupStarts.
    [tabs addTabViewItem:PaneItem([[SettingsGeneralViewController alloc] initWithPlayerController:playerController],
                                  @"general", STR_SETTINGS_GENERAL, @"gearshape")];
    [tabs addTabViewItem:PaneItem([[SettingsAppearanceViewController alloc] initWithPlayerController:playerController],
                                  @"themes", STR_SETTINGS_THEMES_SECTION, @"paintpalette")];
    [tabs addTabViewItem:PaneItem([[SettingsGeneralViewController alloc] initWithPlayerController:playerController page:SettingsGeneralPageAppearance],
                                  @"appearance", STR_MENU_VIEW_APPEARANCE, @"circle.lefthalf.filled")];
    [tabs addTabViewItem:PaneItem([[SettingsPlaybackViewController alloc] initWithPlayerController:playerController],
                                  @"playback", STR_MENU_PLAYBACK, @"play.circle")];
    [tabs addTabViewItem:PaneItem([[SettingsGeneralViewController alloc] initWithPlayerController:playerController page:SettingsGeneralPageAudio],
                                  @"audio", STR_SETTINGS_AUDIO_SECTION, @"speaker.wave.2")];
    [tabs addTabViewItem:PaneItem([[SettingsFilesViewController alloc] initWithPlayerController:playerController],
                                  @"files", STR_SETTINGS_FILES, @"folder")];
    [tabs addTabViewItem:PaneItem([[SettingsShortcutsViewController alloc] initWithPlayerController:playerController],
                                  @"shortcuts", STR_SETTINGS_SHORTCUTS, @"keyboard")];
    [tabs addTabViewItem:PaneItem([[SettingsAdvancedViewController alloc] initWithPlayerController:playerController],
                                  @"advanced", STR_SETTINGS_ADVANCED, @"gearshape.2")];
    [tabs addTabViewItem:PaneItem([[SettingsAboutViewController alloc] initWithPlayerController:playerController],
                                  @"about", STR_SETTINGS_ABOUT, @"info.circle")];

    [SettingsPaneViewController settleSharedSizeForPanes:tabs.childViewControllers];

    SettingsSidebarController *sidebar = [[SettingsSidebarController alloc] init];
    // Before the split controller loads the sidebar, whose rows read the tabs.
    sidebar.tabs = tabs;
    tabs.sidebar = sidebar;

    NSSplitViewController *split = [[SettingsSplitViewController alloc] init];
    NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebar];
    sidebarItem.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    sidebarItem.minimumThickness = kSettingsSidebarWidth;
    sidebarItem.maximumThickness = kSettingsSidebarWidth;
    sidebarItem.canCollapse = NO;
    sidebarItem.allowsFullHeightLayout = YES;
    [split addSplitViewItem:sidebarItem];
    // Per split item: the default draws a hairline under the toolbar once
    // content scrolls beneath it, and the window-level None does not reach.
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:tabs];
    contentItem.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    [split addSplitViewItem:contentItem];
    // The initial selection ran before the split controller existed.
    split.title = tabs.tabViewItems.firstObject.viewController.title;

    // Short of the titlebar; the tab controller's grow-to-floor pass on first
    // appearance corrects it.
    NSSize seedSize = ((SettingsPaneViewController *)
            tabs.tabViewItems.firstObject.viewController).sharedPaneSize;
    NSRect seedRect = NSMakeRect(0, 0, kSettingsSidebarWidth + 1 + seedSize.width,
                                 seedSize.height);
    // The split controller must stay the contentViewController: hosted bare,
    // macOS 26 draws the titlebar scroll pocket as a window-wide band with a
    // hairline over the theme editor.
    SettingsWindow *window = [[SettingsWindow alloc]
            initWithContentRect:seedRect
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                              | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                              | NSWindowStyleMaskFullSizeContentView)
                        backing:NSBackingStoreBuffered
                          defer:NO];
    window.contentViewController = split;
    // The frame guard would refuse fullscreen's grow-to-screen, stranding a
    // small window in its own space.
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenNone;
    window.title = split.title ?: @"";
    [window setContentSize:seedRect.size];
    window.releasedWhenClosed = NO;
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _tabs = tabs;
        // Under Auto, the preview toggle shows the system's side, so an OS
        // flip must re-resolve it.
        [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:NULL];
        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"SettingsToolbar"];
        toolbar.delegate = self;
        toolbar.allowsUserCustomization = NO;
        // With labels allowed, a unified toolbar reserves a label row whether
        // or not one is drawn. Labels stay set for accessibility.
        toolbar.displayMode = NSToolbarDisplayModeIconOnly;
        window.toolbar = toolbar;
        window.toolbarStyle = NSWindowToolbarStyleUnified;
        window.titleVisibility = NSWindowTitleVisible;
        window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;

        // After center, so a saved position wins.
        self.windowFrameAutosaveName = @"SettingsWindow";
        _sidebar = sidebar;
        _backLocations = [NSMutableArray array];
        _forwardLocations = [NSMutableArray array];
        [self updateNavigation];
    }
    return self;
}

- (void)applyWindowFrame:(NSRect)frame {
    SettingsWindow *window = (SettingsWindow *)self.window;
    [window resizeUnlocked:^{
        [window setFrame:frame display:YES];
    }];
}

// Back from the editor is the theme list however it was reached: from the
// menu the list was never shown, so it is recorded on the way in.
- (void)showThemeEditor {
    if ([[self currentLocation] isEqualToString:kEditorLocation]) {
        return;
    }
    [self goToLocation:[self themesTabItem].identifier];
    [self goToLocation:kEditorLocation];
}

- (void)applyContentSize:(NSSize)size {
    NSWindow *window = self.window;
    NSRect content = [window contentRectForFrameRect:window.frame];
    content.origin.y += content.size.height - size.height;
    content.size = size;
    NSRect frame = [window frameRectForContentRect:content];
    if (fabs(NSMinX(window.frame) - NSMinX(frame)) < 0.5
            && fabs(NSMinY(window.frame) - NSMinY(frame)) < 0.5
            && fabs(NSWidth(window.frame) - NSWidth(frame)) < 0.5
            && fabs(NSHeight(window.frame) - NSHeight(frame)) < 0.5) {
        return;
    }
    if (!window.isVisible) {
        [window setFrame:frame display:NO];
        return;
    }
    // Synchronous: an animator's later frames would arrive locked out.
    [self applyWindowFrame:frame];
}

static NSToolbarItemIdentifier const kNavigationItemIdentifier = @"navigation";
static NSToolbarItemIdentifier const kAppearanceToggleItemIdentifier = @"appearance_toggle";
static NSToolbarItemIdentifier const kRandomizeItemIdentifier = @"theme_randomize";

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kNavigationItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier, kRandomizeItemIdentifier,
             kAppearanceToggleItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    // The dice and the appearance toggle are inserted by updateNavigation.
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kNavigationItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:kRandomizeItemIdentifier]) {
        NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"dice"
                          accessibilityDescription:STR_SETTINGS_THEME_RANDOMIZE_SETTINGS],
                [NSImage imageWithSystemSymbolName:@"paintpalette"
                          accessibilityDescription:STR_SETTINGS_THEME_RANDOMIZE_COLORS],
                [NSImage imageWithSystemSymbolName:@"arrow.uturn.backward"
                          accessibilityDescription:STR_MENU_EDIT_UNDO],
                [NSImage imageWithSystemSymbolName:@"arrow.uturn.forward"
                          accessibilityDescription:STR_MENU_EDIT_REDO]]
                trackingMode:NSSegmentSwitchTrackingMomentary
                      target:self action:@selector(randomizeTheme:)];
        [control setToolTip:STR_SETTINGS_THEME_RANDOMIZE_SETTINGS forSegment:0];
        [control setToolTip:STR_SETTINGS_THEME_RANDOMIZE_COLORS forSegment:1];
        [control setToolTip:STR_MENU_EDIT_UNDO forSegment:2];
        [control setToolTip:STR_MENU_EDIT_REDO forSegment:3];
        _randomizeControl = control;
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.view = control;
        item.label = STR_SETTINGS_THEME_RANDOMIZE;
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
    if ([itemIdentifier isEqualToString:kNavigationItemIdentifier]) {
        NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"chevron.backward"
                          accessibilityDescription:STR_SETTINGS_NAV_BACK],
                [NSImage imageWithSystemSymbolName:@"chevron.forward"
                          accessibilityDescription:STR_SETTINGS_NAV_FORWARD]]
                trackingMode:NSSegmentSwitchTrackingMomentary
                      target:self action:@selector(navigate:)];
        [control setToolTip:STR_SETTINGS_NAV_BACK forSegment:0];
        [control setToolTip:STR_SETTINGS_NAV_FORWARD forSegment:1];
        [control setEnabled:NO forSegment:0];
        [control setEnabled:NO forSegment:1];
        _navigationControl = control;
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.view = control;
        item.navigational = YES;
        return item;
    }
    return nil;
}

- (NSTabViewItem *)tabItemWithIdentifier:(NSString *)identifier {
    for (NSTabViewItem *item in _tabs.tabViewItems) {
        if ([item.identifier isEqualToString:identifier]) {
            return item;
        }
    }
    return nil;
}

- (NSTabViewItem *)themesTabItem {
    return [self tabItemWithIdentifier:@"themes"];
}

- (SettingsAppearanceViewController *)themesPane {
    return (SettingsAppearanceViewController *)[self themesTabItem].viewController;
}

- (SettingsGeneralViewController *)audioPane {
    SettingsGeneralViewController *pane =
            (SettingsGeneralViewController *)[self tabItemWithIdentifier:@"audio"].viewController;
    return pane.isViewLoaded && pane.view.window.isVisible ? pane : nil;
}

// Panes measure nothing while hidden, so settle them all on the way in.
- (void)showWindow:(id)sender {
    BOOL wasVisible = self.window.isVisible;
    [super showWindow:sender];
    if (!wasVisible) {
        [SettingsPaneViewController settleSharedSizeForPanes:_tabs.childViewControllers];
    }
}

- (void)refreshSelectedPane {
    if (!self.window.isVisible) return;
    NSInteger index = _tabs.selectedTabViewItemIndex;
    if (index < 0 || index >= (NSInteger)_tabs.tabViewItems.count) return;
    NSViewController *pane = _tabs.tabViewItems[(NSUInteger)index].viewController;
    if ([pane isKindOfClass:SettingsPaneViewController.class]) {
        [(SettingsPaneViewController *)pane refreshSettingsAndPaneSize];
    }
}

- (BOOL)themesPaneIsSelected {
    NSTabViewItem *item = [self themesTabItem];
    return item != nil && _tabs.tabView.selectedTabViewItem == item;
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

static NSString *ThemeHistoryTitle(BOOL forward) {
    AppSettings *settings = AppSettings.sharedInstance;
    if (forward) {
        return settings.themeRedoRemovesTheme ? STR_SETTINGS_THEME_REDO_REMOVE : STR_SETTINGS_THEME_REDO_EDIT;
    }
    return settings.themeUndoRemovesTheme ? STR_SETTINGS_THEME_UNDO_REMOVE : STR_SETTINGS_THEME_UNDO_EDIT;
}

#pragma mark - Navigation history

static const NSUInteger kNavigationHistoryLimit = 50;

- (NSString *)currentLocation {
    NSString *identifier = _tabs.tabView.selectedTabViewItem.identifier;
    return [self themesPaneIsSelected] && self.themesPane.editorShown ? kEditorLocation : identifier;
}

// Every pane switch and page swap lands here; a user's move pushes the place
// it left, as System Settings' history does, and clears what Forward held.
- (void)noteLocation {
    if (_restoringLocation) {
        return;
    }
    NSString *location = [self currentLocation];
    if (!location || [location isEqualToString:_location]) {
        return;
    }
    if (_location) {
        [_backLocations addObject:_location];
        if (_backLocations.count > kNavigationHistoryLimit) {
            [_backLocations removeObjectAtIndex:0];
        }
        [_forwardLocations removeAllObjects];
    }
    _location = location;
}

// The page first, so the pane appears on it.
- (void)goToLocation:(NSString *)location {
    BOOL editor = [location isEqualToString:kEditorLocation];
    NSTabViewItem *item = editor ? [self themesTabItem] : [self tabItemWithIdentifier:location];
    if (!item) {
        return;
    }
    _restoringLocation = YES;
    if (item == [self themesTabItem]) {
        [self.themesPane setEditorShown:editor];
    }
    [_tabs.tabView selectTabViewItem:item];
    _restoringLocation = NO;
    [self updateNavigation];
}

// A pane picked in the sidebar opens at its top, as System Settings' panes
// do; only Back and Forward reopen the theme editor where it was left.
- (void)paneWillBecomeSelected:(NSTabViewItem *)item {
    if (!_restoringLocation && item == [self themesTabItem]) {
        [self.themesPane setEditorShown:NO];
    }
}

- (BOOL)canNavigateForward:(BOOL)forward {
    return (forward ? _forwardLocations : _backLocations).count > 0;
}

- (void)navigateForward:(BOOL)forward {
    NSMutableArray<NSString *> *from = forward ? _forwardLocations : _backLocations;
    NSMutableArray<NSString *> *to = forward ? _backLocations : _forwardLocations;
    NSString *target = from.lastObject;
    if (!target) {
        return;
    }
    [from removeLastObject];
    if (_location) {
        [to addObject:_location];
    }
    // Already the location, so arriving there records nothing.
    _location = target;
    [self goToLocation:target];
}

- (void)navigate:(NSSegmentedControl *)sender {
    [self navigateForward:sender.selectedSegment == 1];
}

- (void)updateNavigation {
    [self noteLocation];
    SettingsAppearanceViewController *pane = [self themesPane];
    BOOL selected = [self themesPaneIsSelected];
    // The editor's page swap retitles the pane mid-view.
    NSInteger selectedIndex = _tabs.selectedTabViewItemIndex;
    if (selectedIndex >= 0) {
        _tabs.parentViewController.title =
                _tabs.tabViewItems[(NSUInteger)selectedIndex].viewController.title;
    }
    [_navigationControl setEnabled:[self canNavigateForward:NO] forSegment:0];
    [_navigationControl setEnabled:[self canNavigateForward:YES] forSegment:1];
    // Inserted and removed, never hidden: NSToolbarItem.hidden needs macOS 15,
    // and the delegate vends non-inserted copies during enumeration, so a
    // stored item is not reliably the one on screen.
    NSToolbar *toolbar = self.window.toolbar;
    for (NSToolbarItemIdentifier identifier in @[kRandomizeItemIdentifier, kAppearanceToggleItemIdentifier]) {
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
    [_randomizeControl setEnabled:(selected && [pane canRestoreThemeHistoryForward:NO]) forSegment:2];
    [_randomizeControl setEnabled:(selected && [pane canRestoreThemeHistoryForward:YES]) forSegment:3];
    [_randomizeControl setToolTip:ThemeHistoryTitle(NO) forSegment:2];
    [_randomizeControl setToolTip:ThemeHistoryTitle(YES) forSegment:3];
    // windowAppearance folds in the preview and a single-mode pin; nil is Auto.
    NSAppearance *appearance =
            AppSettings.sharedInstance.windowAppearance ?: NSApp.effectiveAppearance;
    _appearanceToggle.selectedSegment = appearance.isDark ? 1 : 0;
    BOOL canPreview = AppSettings.sharedInstance.currentTheme.requiredWindowAppearance == nil;
    [_appearanceToggle setEnabled:canPreview forSegment:0];
    [_appearanceToggle setEnabled:canPreview forSegment:1];
}

- (NSArray<NSString *> *)searchSettingsFor:(NSString *)query {
    _sidebar.searchField.stringValue = query;
    [_sidebar searchChanged:nil];
    return [_sidebar visiblePaneIdentifiers];
}

- (void)toggleAppearancePreview:(id)sender {
    [[self themesPane] previewAppearanceDark:(_appearanceToggle.selectedSegment == 1)];
}

- (void)randomizeTheme:(NSSegmentedControl *)sender {
    SettingsAppearanceViewController *pane = [self themesPane];
    switch (sender.selectedSegment) {
        case 0: [pane randomizeThemeSettings]; break;
        case 1: [pane randomizeThemeColors]; break;
        case 2: [pane restoreThemeHistoryForward:NO]; break;
        case 3: [pane restoreThemeHistoryForward:YES]; break;
    }
}

// Catches the nil-targeted ⌘W ahead of the player's, which clears the playlist.
- (IBAction)closeFile:(nullable id)sender {
    [self.window performClose:sender];
}

// The selected pane's own undo stack, for a pane that keeps one.
- (NSUndoManager *)selectedPaneUndoManager {
    SettingsPaneViewController *pane =
            (SettingsPaneViewController *)_tabs.tabView.selectedTabViewItem.viewController;
    return [pane isKindOfClass:SettingsPaneViewController.class] ? pane.paneUndoManager : nil;
}

- (IBAction)undo:(id)sender {
    if ([self themesPaneIsSelected]) [self.themesPane restoreThemeHistoryForward:NO];
    else [self.selectedPaneUndoManager undo];
}

- (IBAction)redo:(id)sender {
    if ([self themesPaneIsSelected]) [self.themesPane restoreThemeHistoryForward:YES];
    else [self.selectedPaneUndoManager redo];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(undo:) || menuItem.action == @selector(redo:)) {
        BOOL forward = menuItem.action == @selector(redo:);
        if ([self themesPaneIsSelected]) {
            menuItem.title = ThemeHistoryTitle(forward);
            return [self.themesPane canRestoreThemeHistoryForward:forward];
        }
        NSUndoManager *manager = self.selectedPaneUndoManager;
        menuItem.title = forward ? (manager.redoMenuItemTitle ?: STR_MENU_EDIT_REDO)
                                 : (manager.undoMenuItemTitle ?: STR_MENU_EDIT_UNDO);
        return forward ? manager.canRedo : manager.canUndo;
    }
    // The one Close item may have been retitled by the player's validation.
    if ([menuItem.identifier isEqualToString:kVibeMenuClose]) {
        menuItem.title = STR_MENU_FILE_CLOSE;
    }
    return YES;
}

@end
