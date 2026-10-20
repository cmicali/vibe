//
//  SettingsPanesWindowController.m
//  Vibe
//

#import "SettingsPanesWindowController.h"
#import "SettingsPaneViewController.h"
#import "SettingsSidebarController.h"

static const CGFloat kSettingsSidebarWidth = 200;

@interface SettingsPanesWindowController () {
    NSTabViewController *_tabs;
    SettingsSidebarController *_sidebar;
    NSSegmentedControl *_navigationControl;
    NSString *_backTitle, *_forwardTitle, *_undoTitle, *_redoTitle;
    // System Settings' history: a location is a pane identifier, with
    // "/<page>" while the pane shows a page. Back and Forward walk it.
    NSString *_location;
    NSMutableArray<NSString *> *_backLocations, *_forwardLocations;
    // Set while a location is applied: the pane switch's own refreshes would
    // otherwise record its half-applied states (a pane with the previous
    // page) and clear Forward.
    BOOL _restoringLocation;
}
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
    SettingsPanesWindowController *controller =
            (SettingsPanesWindowController *)self.view.window.windowController;
    if ([controller isKindOfClass:SettingsPanesWindowController.class]) {
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
    SettingsPanesWindowController *controller =
            (SettingsPanesWindowController *)self.view.window.windowController;
    if ([controller isKindOfClass:SettingsPanesWindowController.class]) {
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
    [(SettingsPanesWindowController *)window.windowController applyContentSize:
            NSMakeSize(MAX(minContent.width, content.size.width),
                       MAX(minContent.height, content.size.height))];
}

@end

#pragma mark - Window controller

@implementation SettingsPanesWindowController

+ (NSTabViewItem *)paneItemWithViewController:(NSViewController *)pane identifier:(NSString *)identifier
                                        label:(NSString *)label symbolName:(NSString *)symbolName {
    pane.title = label;
    NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:pane];
    item.identifier = identifier;
    item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:label];
    return item;
}

- (instancetype)initWithPaneGroups:(NSArray<NSArray<NSTabViewItem *> *> *)paneGroups
                         backTitle:(NSString *)backTitle forwardTitle:(NSString *)forwardTitle
                         undoTitle:(NSString *)undoTitle redoTitle:(NSString *)redoTitle
                 searchPlaceholder:(NSString *)searchPlaceholder noResultsText:(NSString *)noResultsText {
    SettingsTabViewController *tabs = [[SettingsTabViewController alloc] init];
    tabs.tabStyle = NSTabViewControllerTabStyleUnspecified;
    // The default crossfade composites two panes' section headers and flashes.
    tabs.transitionOptions = NSViewControllerTransitionNone;
    tabs.tabView.tabViewType = NSNoTabsNoBorder;

    NSMutableSet<NSString *> *groupStarts = [NSMutableSet set];
    for (NSArray<NSTabViewItem *> *group in paneGroups) {
        if (tabs.tabViewItems.count) {
            [groupStarts addObject:group.firstObject.identifier];
        }
        for (NSTabViewItem *item in group) {
            [tabs addTabViewItem:item];
        }
    }

    [SettingsPaneViewController settleSharedSizeForPanes:tabs.childViewControllers];

    SettingsSidebarController *sidebar = [[SettingsSidebarController alloc]
            initWithSearchPlaceholder:searchPlaceholder noResultsText:noResultsText];
    // Before the split controller loads the sidebar, whose rows read the tabs.
    sidebar.tabs = tabs;
    sidebar.groupStartIdentifiers = groupStarts;
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
    // hairline over a pane's swapped-in page.
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
        _backTitle = [backTitle copy];
        _forwardTitle = [forwardTitle copy];
        _undoTitle = [undoTitle copy];
        _redoTitle = [redoTitle copy];
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

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kNavigationItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, kNavigationItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    if ([itemIdentifier isEqualToString:kNavigationItemIdentifier]) {
        NSSegmentedControl *control = [NSSegmentedControl segmentedControlWithImages:@[
                [NSImage imageWithSystemSymbolName:@"chevron.backward"
                          accessibilityDescription:_backTitle],
                [NSImage imageWithSystemSymbolName:@"chevron.forward"
                          accessibilityDescription:_forwardTitle]]
                trackingMode:NSSegmentSwitchTrackingMomentary
                      target:self action:@selector(navigate:)];
        [control setToolTip:_backTitle forSegment:0];
        [control setToolTip:_forwardTitle forSegment:1];
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

- (NSTabViewItem *)selectedTabItem {
    return _tabs.tabView.selectedTabViewItem;
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

#pragma mark - Navigation history

static const NSUInteger kNavigationHistoryLimit = 50;

static SettingsPaneViewController *PaneOfItem(NSTabViewItem *item) {
    NSViewController *pane = item.viewController;
    return [pane isKindOfClass:SettingsPaneViewController.class] ? (SettingsPaneViewController *)pane : nil;
}

- (NSString *)currentLocation {
    NSTabViewItem *item = self.selectedTabItem;
    NSString *identifier = item.identifier;
    NSString *page = PaneOfItem(item).currentPage;
    return page && identifier ? [NSString stringWithFormat:@"%@/%@", identifier, page] : identifier;
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
    NSRange slash = [location rangeOfString:@"/"];
    NSString *identifier = slash.location == NSNotFound ? location : [location substringToIndex:slash.location];
    NSString *page = slash.location == NSNotFound ? nil : [location substringFromIndex:NSMaxRange(slash)];
    NSTabViewItem *item = [self tabItemWithIdentifier:identifier];
    if (!item) {
        return;
    }
    _restoringLocation = YES;
    [PaneOfItem(item) showPage:page];
    [_tabs.tabView selectTabViewItem:item];
    _restoringLocation = NO;
    [self updateNavigation];
}

// A pane picked in the sidebar opens at its top, as System Settings' panes
// do; only Back and Forward reopen a page where it was left.
- (void)paneWillBecomeSelected:(NSTabViewItem *)item {
    if (!_restoringLocation) {
        [PaneOfItem(item) showPage:nil];
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
    _location = target;
    [self goToLocation:target];
}

- (void)navigate:(NSSegmentedControl *)sender {
    [self navigateForward:sender.selectedSegment == 1];
}

- (void)updateNavigation {
    [self noteLocation];
    // A page swap retitles the pane mid-view.
    NSInteger selectedIndex = _tabs.selectedTabViewItemIndex;
    if (selectedIndex >= 0) {
        _tabs.parentViewController.title =
                _tabs.tabViewItems[(NSUInteger)selectedIndex].viewController.title;
    }
    [_navigationControl setEnabled:[self canNavigateForward:NO] forSegment:0];
    [_navigationControl setEnabled:[self canNavigateForward:YES] forSegment:1];
}

- (NSArray<NSString *> *)searchSettingsFor:(NSString *)query {
    _sidebar.searchField.stringValue = query;
    [_sidebar searchChanged:nil];
    return [_sidebar visiblePaneIdentifiers];
}

#pragma mark - Undo

// The selected pane's own undo stack, for a pane that keeps one.
- (NSUndoManager *)selectedPaneUndoManager {
    return PaneOfItem(self.selectedTabItem).paneUndoManager;
}

- (IBAction)undo:(id)sender {
    [self.selectedPaneUndoManager undo];
}

- (IBAction)redo:(id)sender {
    [self.selectedPaneUndoManager redo];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(undo:) || menuItem.action == @selector(redo:)) {
        BOOL forward = menuItem.action == @selector(redo:);
        NSUndoManager *manager = self.selectedPaneUndoManager;
        menuItem.title = forward ? (manager.redoMenuItemTitle ?: _redoTitle)
                                 : (manager.undoMenuItemTitle ?: _undoTitle);
        return forward ? manager.canRedo : manager.canUndo;
    }
    return YES;
}

@end
