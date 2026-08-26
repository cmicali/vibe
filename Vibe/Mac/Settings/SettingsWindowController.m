//
//  SettingsWindowController.m
//  Vibe
//

#import "SettingsWindowController.h"
#import "SettingsAboutViewController.h"
#import "SettingsAdvancedViewController.h"
#import "SettingsAppearanceViewController.h"
#import "SettingsConvertViewController.h"
#import "SettingsFilesViewController.h"
#import "SettingsGeneralViewController.h"
#import "SettingsPaneViewController.h"
#import "SettingsPlaybackViewController.h"
#import "VibeStrings.h"

static const CGFloat kSettingsSidebarWidth = 200;

@interface SettingsWindowController () <NSMenuItemValidation, NSToolbarDelegate, NSWindowDelegate> {
    // The pane host; SettingsTabViewController is defined further down, and
    // everything reached through this ivar is NSTabViewController API.
    NSTabViewController *_tabs;
    // The content view's size, pinned EQUAL to the live frame: the constraint
    // engine re-sizes a contentViewController window to its content's fitting
    // size after every layout pass, so a user's drag snaps back unless the
    // fitting answer follows the drag. windowDidResize: keeps the constants
    // at whatever size the window holds, which turns the snap into a no-op —
    // the one arrangement that survives it (no constraints at all leaves the
    // fitting ambiguous and the window snaps to the sidebar's answer instead;
    // observed both ways).
    NSLayoutConstraint *_contentWidth;
    NSLayoutConstraint *_contentHeight;
    NSSegmentedControl *_navigationControl;
}
@end

// The same swallow as the tab controller's: AppKit resizes the window the
// moment its contentViewController's preferredContentSize changes, and the
// split controller adopts one from its children's fitting sizes on layout —
// which would snap the window to the raw pane height, past both the height
// floor and the animated resize.
@interface SettingsSplitViewController : NSSplitViewController
@end

@implementation SettingsSplitViewController

- (void)setPreferredContentSize:(NSSize)preferredContentSize {
}

@end

#pragma mark - Sidebar

// The pane list, drawn from the tab controller's own items so the two cannot
// drift: same order, same localized labels, same symbols.
@interface SettingsSidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>
@property (weak, nonatomic) NSTabViewController *tabs;
@property (readonly, nonatomic) NSTableView *tableView;
@end

// System Settings shows the accent-colored selection whether or not the
// sidebar has focus; a stock source list dims to gray when it does not.
@interface SettingsSidebarRowView : NSTableRowView
@end

@implementation SettingsSidebarRowView

- (BOOL)isEmphasized {
    return YES;
}

@end

// The icon flips white through backgroundStyle — the row view pushes it the
// moment its selection moves, mouse-down tracking included. Re-tinting from
// tableViewSelectionDidChange: left the pressed row mis-tinted for the whole
// press: that notification waits for mouse-up.
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
}

- (NSTableView *)tableView {
    (void)self.view;
    return _tableView;
}

- (void)loadView {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.style = NSTableViewStyleSourceList;
    table.headerView = nil;
    table.rowHeight = 28;
    table.allowsEmptySelection = NO;
    table.allowsMultipleSelection = NO;
    table.focusRingType = NSFocusRingTypeNone;
    [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"pane"]];
    table.dataSource = self;
    table.delegate = self;
    _tableView = table;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    self.view = scroll;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.tabs.tabViewItems.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
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
    NSTabViewItem *item = self.tabs.tabViewItems[(NSUInteger)row];
    cell.imageView.image = item.image;
    cell.textField.stringValue = item.label ?: @"";
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [SettingsSidebarRowView new];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = _tableView.selectedRow;
    if (row >= 0 && self.tabs.selectedTabViewItemIndex != row) {
        self.tabs.selectedTabViewItemIndex = row;
    }
}

@end

#pragma mark - Tab controller

// Owns the frame update when every pane's shared size changes. Also the sync
// point back to the sidebar, so a programmatic selection (the debug channel's
// settings_open) moves the highlighted row too.
@interface SettingsTabViewController : NSTabViewController <SettingsPaneSizeHost>
@property (weak, nonatomic) NSTableView *sidebarTable;
@end

@implementation SettingsTabViewController

// Swallow the selected child's preferredContentSize instead of adopting it:
// a window whose contentViewController's preferredContentSize changes is
// resized by AppKit immediately, which is the snap that beats the animated
// resize below to the target frame and turns it into a no-op.
- (void)setPreferredContentSize:(NSSize)preferredContentSize {
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    [super tabView:tabView didSelectTabViewItem:tabViewItem];
    NSViewController *pane = tabViewItem.viewController;
    if (!pane) {
        return;
    }
    NSUInteger index = [self.tabViewItems indexOfObject:tabViewItem];
    NSTableView *sidebar = self.sidebarTable;
    if (index != NSNotFound && sidebar && sidebar.selectedRow != (NSInteger)index) {
        [sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    }
    // The window binds its title to the split controller's; the pane's title
    // reaches it through here, never set on the window directly.
    self.parentViewController.title = pane.title;
    SettingsWindowController *controller =
            (SettingsWindowController *)self.view.window.windowController;
    if ([controller isKindOfClass:SettingsWindowController.class]) {
        [controller updateThemeNavigation];
    }
}

// A pane revealed or hid a row, so every pane's shared size moved under the
// open window. SettingsPaneViewController has already opened the animation
// transaction that moves the visible layout with this frame update.
- (void)settingsPaneSizeDidChange {
    NSInteger index = self.selectedTabViewItemIndex;
    if (index < 0 || index >= (NSInteger)self.tabViewItems.count) {
        return;
    }
    [self resizeWindowToPaneSize:self.tabViewItems[(NSUInteger)index].viewController];
}

// The floor needs a laid-out window (the titlebar height comes from the
// engine), so the first chance to set it is here rather than at build.
- (void)viewDidAppear {
    [super viewDidAppear];
    [self settingsPaneSizeDidChange];
}

- (void)resizeWindowToPaneSize:(NSViewController *)pane {
    NSWindow *window = self.view.window;
    if (!pane || !window) {
        return;
    }
    // The panes' shared size is the window's FLOOR, not its size: the window
    // is user-resizable above it, so a shared-size change moves the minimum
    // and grows an undersized window, never shrinking one the user enlarged.
    // The floor is computed from the engine's own numbers: this view's
    // leading edge in the window is the sidebar plus divider, and the content
    // rect past contentLayoutRect is the titlebar overlaying the content.
    NSSize paneSize = pane.preferredContentSize;
    CGFloat leading = NSMinX([self.view convertRect:self.view.bounds toView:nil]);
    NSRect content = [window contentRectForFrameRect:window.frame];
    CGFloat titlebar = NSHeight(content) - NSHeight(window.contentLayoutRect);
    NSSize minContent = NSMakeSize(leading + paneSize.width, paneSize.height + titlebar);
    window.contentMinSize = minContent;
    NSSize target = NSMakeSize(MAX(minContent.width, content.size.width),
                               MAX(minContent.height, content.size.height));
    content.origin.y += content.size.height - target.height;
    content.size = target;
    NSRect targetFrame = [window frameRectForContentRect:content];
    if (fabs(NSMinX(window.frame) - NSMinX(targetFrame)) < 0.5
            && fabs(NSMinY(window.frame) - NSMinY(targetFrame)) < 0.5
            && fabs(NSWidth(window.frame) - NSWidth(targetFrame)) < 0.5
            && fabs(NSHeight(window.frame) - NSHeight(targetFrame)) < 0.5) {
        return;
    }
    if (!window.isVisible) {
        [window setFrame:targetFrame display:NO];
        return;
    }
    // The pane owns the explicit animation context so its arranged views and
    // this frame share one transaction. The animator, not the legacy blocking
    // setFrame:display:animate:, supplies the intermediate frames.
    [[window animator] setFrame:targetFrame display:YES];
}

@end

#pragma mark - Window controller

@implementation SettingsWindowController

// The identifier is the pane's stable name, the one the debug channel's
// settings_open selects by, so a script never depends on the running
// language the way the label would make it.
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
    // Every pane already has the same size. AppKit's default crossfade briefly
    // composites section headers from both panes and makes the swap flash.
    tabs.transitionOptions = NSViewControllerTransitionNone;
    tabs.tabView.tabViewType = NSNoTabsNoBorder;

    [tabs addTabViewItem:PaneItem([[SettingsGeneralViewController alloc] initWithPlayerController:playerController],
                                  @"general", STR_SETTINGS_GENERAL, @"gearshape")];
    // The sidebar labels reuse the Playback and Appearance menu strings: same
    // word, same translations.
    [tabs addTabViewItem:PaneItem([[SettingsPlaybackViewController alloc] initWithPlayerController:playerController],
                                  @"playback", STR_MENU_PLAYBACK, @"play.circle")];
    [tabs addTabViewItem:PaneItem([[SettingsAppearanceViewController alloc] initWithPlayerController:playerController],
                                  @"appearance", STR_MENU_VIEW_APPEARANCE, @"paintbrush")];
    [tabs addTabViewItem:PaneItem([[SettingsFilesViewController alloc] initWithPlayerController:playerController],
                                  @"files", STR_SETTINGS_FILES, @"folder")];
    // The Convert label reuses the Convert menu's string too.
    [tabs addTabViewItem:PaneItem([[SettingsConvertViewController alloc] initWithPlayerController:playerController],
                                  @"convert", STR_MENU_CONVERT, @"arrow.triangle.2.circlepath")];
    [tabs addTabViewItem:PaneItem([[SettingsAdvancedViewController alloc] initWithPlayerController:playerController],
                                  @"advanced", STR_SETTINGS_ADVANCED, @"gearshape.2")];
    [tabs addTabViewItem:PaneItem([[SettingsAboutViewController alloc] initWithPlayerController:playerController],
                                  @"about", STR_SETTINGS_ABOUT, @"info.circle")];

    // Every pane at the largest pane's size, before the window is built, so
    // the window has one size and a pane switch resizes nothing.
    [SettingsPaneViewController settleSharedSizeForPanes:tabs.childViewControllers];

    SettingsSidebarController *sidebar = [[SettingsSidebarController alloc] init];
    sidebar.tabs = tabs;
    tabs.sidebarTable = sidebar.tableView;

    NSSplitViewController *split = [[SettingsSplitViewController alloc] init];
    NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebar];
    sidebarItem.minimumThickness = kSettingsSidebarWidth;
    sidebarItem.maximumThickness = kSettingsSidebarWidth;
    sidebarItem.canCollapse = NO;
    sidebarItem.allowsFullHeightLayout = YES;
    [split addSplitViewItem:sidebarItem];
    [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:tabs]];
    // The window title comes from the pane-title chain (didSelectTabViewItem
    // above), never set directly; the initial selection ran before the split
    // controller existed, so seed it here once.
    split.title = tabs.tabViewItems.firstObject.viewController.title;

    NSWindow *window = [NSWindow windowWithContentViewController:split];
    // The panes carry no size constraints (see SettingsPaneViewController), so
    // the fitting pass cannot size the window: seed it from the settled shared
    // size explicitly. The height is short of the titlebar here; the tab
    // controller's grow-to-floor pass on first appearance corrects it, and an
    // autosaved frame overrides the whole thing anyway.
    NSSize seedSize = tabs.tabViewItems.firstObject.viewController.preferredContentSize;
    [window setContentSize:NSMakeSize(kSettingsSidebarWidth + 1 + seedSize.width,
                                      seedSize.height)];
    // Resizable above the panes' shared size, which is the FLOOR the tab
    // controller keeps in contentMinSize — a pane's own constraints are
    // minimums, so extra height is blank space below the sections and the
    // theme editor's scroll area grows. Full-size content view is what lets
    // the sidebar run the window's full height.
    window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
            | NSWindowStyleMaskFullSizeContentView;
    window.releasedWhenClosed = NO;
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        // An item-less toolbar except for the sidebar tracking separator,
        // which AppKit vends for a split-view content controller: it gives the
        // titlebar its unified height and carries the sidebar divider through
        // it, which is the whole System Settings look.
        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"SettingsToolbar"];
        toolbar.delegate = self;
        toolbar.allowsUserCustomization = NO;
        window.toolbar = toolbar;
        window.toolbarStyle = NSWindowToolbarStyleUnified;
        // The System Settings look: the page title sits beside the navigation
        // control with no hairline under the toolbar.
        window.titleVisibility = NSWindowTitleVisible;
        window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;

        // After center, so a saved position wins over the default one. The
        // SIZE the autosave restores — possibly a different pane's — needs no
        // correction here: the constraint engine re-sizes the window to the
        // selected pane's fitting size on the first layout pass.
        self.windowFrameAutosaveName = @"SettingsWindow";
        [sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        _tabs = tabs;

        window.delegate = self;
        NSView *content = split.view;
        _contentWidth = [content.widthAnchor constraintEqualToConstant:content.frame.size.width];
        _contentHeight = [content.heightAnchor constraintEqualToConstant:content.frame.size.height];
        // Just below required, so the one pass where the frame moved ahead of
        // the constants resolves by stretching instead of breaking loudly.
        _contentWidth.priority = NSLayoutPriorityRequired - 1;
        _contentHeight.priority = NSLayoutPriorityRequired - 1;
        [NSLayoutConstraint activateConstraints:@[_contentWidth, _contentHeight]];
    }
    return self;
}

// Every resize — the user's drag, the grow-to-floor pass, the autosave
// restore — lands the new size in the constants, so the engine's fitting
// answer is always the frame the window already holds.
- (void)windowDidResize:(NSNotification *)notification {
    NSSize size = ((NSView *)self.window.contentView).frame.size;
    _contentWidth.constant = size.width;
    _contentHeight.constant = size.height;
}

- (void)showThemeEditor {
    for (NSTabViewItem *item in _tabs.tabViewItems) {
        if ([item.identifier isEqualToString:@"appearance"]) {
            // The tab controller's own selection path, so the sidebar, the
            // title chain and refreshFromSettings all follow.
            _tabs.selectedTabViewItemIndex = [_tabs.tabViewItems indexOfObject:item];
            // Edit Themes… states intent to edit, and the active theme is
            // unambiguous — land on its page, with Back one click away.
            [(SettingsAppearanceViewController *)item.viewController showThemeEditorForActiveTheme];
            break;
        }
    }
}

static NSToolbarItemIdentifier const kThemeNavigationItemIdentifier = @"theme_navigation";

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kThemeNavigationItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kThemeNavigationItemIdentifier];
}

// The tracking separator is AppKit's own; there are no custom items to build.
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:kThemeNavigationItemIdentifier]) {
        // The System Settings navigation pill: back pops the theme editor to
        // the list, forward — armed by a pop — re-opens it. Disabled outside
        // the Appearance pane; updateThemeNavigation keeps it honest.
        NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"chevron.backward"
                          accessibilityDescription:STR_SETTINGS_THEME_BACK],
                [NSImage imageWithSystemSymbolName:@"chevron.forward"
                          accessibilityDescription:STR_SETTINGS_THEME_FORWARD]]
                trackingMode:NSSegmentSwitchTrackingMomentary
                      target:self action:@selector(navigateThemeEditor:)];
        [control setEnabled:NO forSegment:0];
        [control setEnabled:NO forSegment:1];
        _navigationControl = control;
        NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        item.view = control;
        // Leading, before the window title — where System Settings puts its
        // navigation pill.
        item.navigational = YES;
        return item;
    }
    return nil;
}

- (SettingsAppearanceViewController *)appearancePane {
    for (NSTabViewItem *item in _tabs.tabViewItems) {
        if ([item.identifier isEqualToString:@"appearance"]) {
            return (SettingsAppearanceViewController *)item.viewController;
        }
    }
    return nil;
}

- (BOOL)appearancePaneIsSelected {
    NSInteger index = _tabs.selectedTabViewItemIndex;
    return index >= 0 && index < (NSInteger)_tabs.tabViewItems.count
            && [_tabs.tabViewItems[(NSUInteger)index].identifier isEqualToString:@"appearance"];
}

- (void)updateThemeNavigation {
    SettingsAppearanceViewController *pane = [self appearancePane];
    BOOL selected = [self appearancePaneIsSelected];
    [_navigationControl setEnabled:(selected && pane.canGoBack) forSegment:0];
    [_navigationControl setEnabled:(selected && pane.canGoForward) forSegment:1];
}

- (void)navigateThemeEditor:(NSSegmentedControl *)sender {
    SettingsAppearanceViewController *pane = [self appearancePane];
    if (![self appearancePaneIsSelected] || !pane) {
        return;
    }
    if (sender.selectedSegment == 0) {
        [pane navigateBack];
    } else {
        [pane navigateForward];
    }
}

// File > Close (⌘W) is nil-targeted closeFile:; catching it while this window
// is key closes it, instead of falling through to the player's version, which
// clears the playlist.
- (IBAction)closeFile:(nullable id)sender {
    [self.window performClose:sender];
}

// The File menu owns one nil-targeted Close item. Its previous validation may
// have run through the player and named it "Close All Files", so every other
// closeFile: target restores the title that describes its own action.
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:@"menu_close"]) {
        menuItem.title = STR_MENU_FILE_CLOSE;
    }
    return YES;
}

@end
