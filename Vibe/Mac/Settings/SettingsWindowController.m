//
//  SettingsWindowController.m
//  Vibe
//

#import "SettingsWindowController.h"
#import "MenuValidationRules.h"
#import "AppSettings.h"
#import "MainPlayerController+Settings.h"
#import "SettingsAboutViewController.h"
#import "SettingsAdvancedViewController.h"
#import "SettingsAppearanceViewController.h"
#import "SettingsConvertViewController.h"
#import "SettingsFilesViewController.h"
#import "SettingsGeneralViewController.h"
#import "SettingsPaneViewController.h"
#import "SettingsPlaybackViewController.h"
#import "NSView+DarkMode.h"
#import "VibeStrings.h"

static const CGFloat kSettingsSidebarWidth = 200;

@interface SettingsWindowController () <NSMenuItemValidation, NSToolbarDelegate> {
    // The pane host; SettingsTabViewController is defined further down, and
    // everything reached through this ivar is NSTabViewController API.
    NSTabViewController *_tabs;
    NSSegmentedControl *_navigationControl;
    NSSegmentedControl *_appearanceToggle;
}
@end

// The constraint engine re-sizes any window hosting an auto layout subtree
// to the content's ideal frame after layout passes
// (_changeWindowFrameFromConstraintsIfNecessary), through setFrame:display: —
// and the priority games that could defeat that snap also clamp interactive
// resizing: frame-tracking equality constants at 999 and at 509 collapsed the
// user-resize range to a point (no resize cursor at all), while 500 and no
// constraints lost the snap fight instead, all four observed. So the frame is
// guarded here, in public API alone: a size change lands only from the user's
// live resize, from a blessed path inside resizeUnlocked:, or while the
// window is not yet visible (setup, autosave restore). The snap becomes the
// no-op no constraint arrangement could make it, origin-only changes — moves
// — always pass, and zoom is the one casualty (refused; System Settings does
// not zoom either).
@interface SettingsWindow : NSWindow
- (void)resizeUnlocked:(void (^)(void))block;
@end

@implementation SettingsWindow {
    BOOL _resizeUnlocked;
}

// Strictly scoped: the engine's snap fires inside the very next layout
// flush, so a time-boxed unlock re-admits it (observed — a 0.35s tail let
// layoutIfNeeded revert a blessed resize before the caller ever saw it).
// Blessed resizes are therefore SYNCHRONOUS plain setFrame: calls; nothing
// animates the frame, so there is no in-flight animation to outlive the
// block.
- (void)resizeUnlocked:(void (^)(void))block {
    _resizeUnlocked = YES;
    block();
    _resizeUnlocked = NO;
}

- (void)setFrame:(NSRect)frameRect display:(BOOL)flag {
    // isVisible is NO while miniaturized, but that is not the pre-visible
    // setup window this admits — a layout flush can still fire the snap in
    // the Dock, deminiaturizing the user's frame at the fitting size.
    if (!NSEqualSizes(frameRect.size, self.frame.size)
            && (self.isVisible || self.isMiniaturized)
            && !self.inLiveResize && !_resizeUnlocked
            && ![self appKitIsRescuingOntoScreen:frameRect]) {
        return;
    }
    [super setFrame:frameRect display:flag];
}

// The fitting snap keeps the window on its current screen, so it never
// escapes here. A display disconnect or resolution drop is the case this
// admits: the window is currently off every screen and AppKit is pulling it
// back onto one. (An AX window-manager resize is indistinguishable from the
// snap at this funnel and stays refused — the documented limitation.)
- (BOOL)appKitIsRescuingOntoScreen:(NSRect)proposed {
    BOOL currentOnScreen = NO, proposedFits = NO;
    for (NSScreen *screen in NSScreen.screens) {
        // Intersection, not containment: a window straddling two displays is
        // contained by neither visibleFrame, but it is exactly where the user
        // put it — only a window with no visible part left needs the rescue.
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

// Assigning contentViewController after init does not establish the title
// binding windowWithContentViewController: would have, so the pane-title
// chain's last hop — split to window — is explicit.
- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    self.view.window.title = title ?: @"";
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
    if (![pane isKindOfClass:SettingsPaneViewController.class] || !window) {
        return;
    }
    // The panes' shared size is the window's FLOOR, not its size: the window
    // is user-resizable above it, so a shared-size change moves the minimum
    // and grows an undersized window, never shrinking one the user enlarged.
    // The floor is computed from the engine's own numbers: this view's
    // leading edge in the window is the sidebar plus divider, and the content
    // rect past contentLayoutRect is the titlebar overlaying the content.
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
    sidebarItem.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    sidebarItem.minimumThickness = kSettingsSidebarWidth;
    sidebarItem.maximumThickness = kSettingsSidebarWidth;
    sidebarItem.canCollapse = NO;
    sidebarItem.allowsFullHeightLayout = YES;
    [split addSplitViewItem:sidebarItem];
    // Each split item carries its OWN titlebar separator style, defaulting to
    // automatic — which draws a hairline under the toolbar the moment the
    // pane's content can scroll beneath it, exactly what the theme editor's
    // scroll view does. The window-level None does not reach through.
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:tabs];
    contentItem.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    [split addSplitViewItem:contentItem];
    // The window title comes from the pane-title chain (didSelectTabViewItem
    // above), never set directly; the initial selection ran before the split
    // controller existed, so seed it here once.
    split.title = tabs.tabViewItems.firstObject.viewController.title;

    // The seed is the settled shared size; the height is short of the
    // titlebar here — the tab controller's grow-to-floor pass on first
    // appearance corrects it, and an autosaved frame overrides it anyway.
    NSSize seedSize = ((SettingsPaneViewController *)
            tabs.tabViewItems.firstObject.viewController).sharedPaneSize;
    NSRect seedRect = NSMakeRect(0, 0, kSettingsSidebarWidth + 1 + seedSize.width,
                                 seedSize.height);
    // The guarded subclass is what makes contentViewController livable: the
    // engine re-sizes such a window to its content's fitting answer after
    // layout passes, and every constraint arrangement that could defeat that
    // snap also collapsed the user-resize range to a point (no resize cursor;
    // 999 and 509 equalities, 500, and none — all observed). The guard
    // refuses the snap at the setFrame:display: funnel instead, so the
    // content can stay constraint-free and the resize range open. The split
    // controller must remain the contentViewController — hosting its view
    // bare re-created the titlebar scroll pocket as an unmanaged window-wide
    // band whose hard edge drew a stray hairline over the theme editor
    // (macOS 26); through the controller, the split items' separator style
    // governs it. Full-size content view lets the sidebar run the window's
    // full height; extra height past the floor is blank space below the
    // sections, and the theme editor's scroll area grows.
    SettingsWindow *window = [[SettingsWindow alloc]
            initWithContentRect:seedRect
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                              | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                              | NSWindowStyleMaskFullSizeContentView)
                        backing:NSBackingStoreBuffered
                          defer:NO];
    window.contentViewController = split;
    // No green-button fullscreen: a resizable non-panel window offers it
    // implicitly, and the frame guard would refuse AppKit's grow-to-screen —
    // stranding a mini-window in a dedicated space. System Settings is the
    // same. Zoom is likewise a no-op through the guard, by design.
    window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenNone;
    window.title = split.title ?: @"";
    [window setContentSize:seedRect.size];
    window.releasedWhenClosed = NO;
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _tabs = tabs;
        // Under Auto, the preview toggle shows the side the system is on; an
        // OS flip while the editor is idle must re-resolve it.
        // viewDidChangeEffectiveAppearance is an NSView hook, not available on
        // this controller, so the app-level appearance is observed by KVO.
        [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:NULL];
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
        // SIZE the autosave restores needs no correction here: the tab
        // controller's grow-to-floor pass raises an undersized restore to the
        // panes' floor on first appearance and never shrinks an enlarged one.
        self.windowFrameAutosaveName = @"SettingsWindow";
        [sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    return self;
}

- (void)applyWindowFrame:(NSRect)frame {
    // Plain and synchronous — nothing animates this window's frame anymore,
    // so there is no in-flight animation to retarget.
    SettingsWindow *window = (SettingsWindow *)self.window;
    [window resizeUnlocked:^{
        [window setFrame:frame display:YES];
    }];
}

- (void)showThemeEditor {
    NSTabViewItem *item = [self appearanceTabItem];
    if (!item) {
        return;
    }
    // The tab controller's own selection path, so the sidebar, the title
    // chain and refreshFromSettings all follow; then land on the active
    // theme's page — Edit Themes… states intent to edit, and the active
    // theme is unambiguous — with Back one click away.
    _tabs.selectedTabViewItemIndex = (NSInteger)[_tabs.tabViewItems indexOfObject:item];
    [(SettingsAppearanceViewController *)item.viewController showThemeEditorForActiveTheme];
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
    // Synchronous, not animated — the guard's unlock is scoped to the call,
    // and an animator's later frames would arrive locked out. The pane's
    // arranged views still animate inside their own transaction; the window
    // edge lands at once.
    [self applyWindowFrame:frame];
}

static NSToolbarItemIdentifier const kThemeNavigationItemIdentifier = @"theme_navigation";
static NSToolbarItemIdentifier const kAppearanceToggleItemIdentifier = @"appearance_toggle";

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kThemeNavigationItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier, kAppearanceToggleItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    // The appearance toggle is deliberately absent: it exists only while the
    // Appearance pane is selected, inserted and removed by
    // updateThemeNavigation.
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kThemeNavigationItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:kAppearanceToggleItemIdentifier]) {
        // The Appearance pane's fast light/dark preview, trailing in the
        // titlebar: a dual-mode theme keeps a palette per appearance, and
        // flipping the main window's is how you see the other one — on the
        // theme list, where it previews the theme being picked, as much as
        // inside the editor. Never disabled: under a single-mode theme the
        // preview still lands, it is only outranked by the pinned dark
        // appearance until the mode flips back.
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
        item.label = STR_MENU_VIEW_APPEARANCE;
        return item;
    }
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

- (NSTabViewItem *)appearanceTabItem {
    for (NSTabViewItem *item in _tabs.tabViewItems) {
        if ([item.identifier isEqualToString:@"appearance"]) {
            return item;
        }
    }
    return nil;
}

- (SettingsAppearanceViewController *)appearancePane {
    return (SettingsAppearanceViewController *)[self appearanceTabItem].viewController;
}

- (BOOL)appearancePaneIsSelected {
    NSTabViewItem *item = [self appearanceTabItem];
    return item != nil
            && _tabs.selectedTabViewItemIndex == (NSInteger)[_tabs.tabViewItems indexOfObject:item];
}

- (void)dealloc {
    [NSApp removeObserver:self forKeyPath:@"effectiveAppearance"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    [self updateThemeNavigation];
}

- (void)updateThemeNavigation {
    SettingsAppearanceViewController *pane = [self appearancePane];
    BOOL selected = [self appearancePaneIsSelected];
    // A pane can retitle itself mid-view (the editor's page swap); re-push
    // the pane-title chain the tab controller drives on selection, so no
    // pane has to know how deep the container nesting is.
    NSInteger selectedIndex = _tabs.selectedTabViewItemIndex;
    if (selectedIndex >= 0) {
        _tabs.parentViewController.title =
                _tabs.tabViewItems[(NSUInteger)selectedIndex].viewController.title;
    }
    [_navigationControl setEnabled:(selected && pane.canGoBack) forSegment:0];
    [_navigationControl setEnabled:(selected && pane.canGoForward) forSegment:1];
    // The toggle exists only on this pane — both its pages — and is inserted
    // and removed rather than hidden, which reaches every macOS the app runs
    // on; NSToolbarItem.hidden needs macOS 15. The delegate also vends
    // non-inserted copies during allowed-item enumeration, so a stored item
    // reference is not reliably the one on screen.
    NSToolbar *toolbar = self.window.toolbar;
    NSUInteger index = [toolbar.items indexOfObjectPassingTest:
            ^BOOL(NSToolbarItem *item, NSUInteger i, BOOL *stop) {
        return [item.itemIdentifier isEqualToString:kAppearanceToggleItemIdentifier];
    }];
    if (selected && index == NSNotFound) {
        [toolbar insertItemWithItemIdentifier:kAppearanceToggleItemIdentifier
                                      atIndex:(NSInteger)toolbar.items.count];
    } else if (!selected && index != NSNotFound) {
        [toolbar removeItemAtIndex:(NSInteger)index];
    }
    // windowAppearance owns the style-to-appearance ladder, preview and a
    // single-mode theme's pin folded in; its nil (Auto) shows the side the
    // system is on right now.
    NSAppearance *appearance =
            AppSettings.sharedInstance.windowAppearance ?: NSApp.effectiveAppearance;
    _appearanceToggle.selectedSegment = appearance.isDark ? 1 : 0;
}

// A PREVIEW, not a choice — the pane owns it, as it owns the pages the
// navigation pill drives, so the debug channel reaches it by the same route
// the toolbar does.
- (void)toggleAppearancePreview:(id)sender {
    [[self appearancePane] previewAppearanceDark:(_appearanceToggle.selectedSegment == 1)];
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
    if ([menuItem.identifier isEqualToString:kVibeMenuClose]) {
        menuItem.title = STR_MENU_FILE_CLOSE;
    }
    return YES;
}

@end
