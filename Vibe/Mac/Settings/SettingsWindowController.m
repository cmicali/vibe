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

@interface SettingsWindowController () <NSMenuItemValidation, NSToolbarDelegate> {
    // The pane host; SettingsTabViewController is defined further down, and
    // everything reached through this ivar is NSTabViewController API.
    NSTabViewController *_tabs;
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
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"pane" owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
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

- (void)resizeWindowToPaneSize:(NSViewController *)pane {
    NSWindow *window = self.view.window;
    if (!pane || !window) {
        return;
    }
    // The target is the frame the constraint engine will settle the window at
    // anyway (the pane's fitting size is the window's size — see
    // SettingsPaneViewController), computed from the engine's own numbers:
    // this view's leading edge in the window is the sidebar plus divider, and
    // the content rect past contentLayoutRect is the titlebar overlaying the
    // content. Animating to the same answer keeps the post-animation snap a
    // no-op.
    NSSize paneSize = pane.preferredContentSize;
    CGFloat leading = NSMinX([self.view convertRect:self.view.bounds toView:nil]);
    NSRect content = [window contentRectForFrameRect:window.frame];
    CGFloat titlebar = NSHeight(content) - NSHeight(window.contentLayoutRect);
    NSSize target = NSMakeSize(leading + paneSize.width, paneSize.height + titlebar);
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
    // Not resizable: each pane owns its size. Full-size content view is what
    // lets the sidebar run the window's full height.
    window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView;
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

        // After center, so a saved position wins over the default one. The
        // SIZE the autosave restores — possibly a different pane's — needs no
        // correction here: the constraint engine re-sizes the window to the
        // selected pane's fitting size on the first layout pass.
        self.windowFrameAutosaveName = @"SettingsWindow";
        [sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        _tabs = tabs;
    }
    return self;
}

- (void)showThemeEditor {
    for (NSTabViewItem *item in _tabs.tabViewItems) {
        if ([item.identifier isEqualToString:@"appearance"]) {
            // The tab controller's own selection path, so the sidebar, the
            // title chain and refreshFromSettings all follow.
            _tabs.selectedTabViewItemIndex = [_tabs.tabViewItems indexOfObject:item];
            break;
        }
    }
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier];
}

// The tracking separator is AppKit's own; there are no custom items to build.
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    return nil;
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
