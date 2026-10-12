//
//  SettingsSidebarController.m
//  Vibe
//

#import "SettingsSidebarController.h"
#import "SettingsPaneViewController.h"
#import "SettingsWindowController.h"
#import "VibeStrings.h"

// Rows come from the tab controller's items, so the two cannot drift. A group
// starts at each of these panes, after a spacer row.
static NSSet<NSString *> *SidebarGroupStarts(void) {
    return [NSSet setWithArray:@[@"playback", @"shortcuts", @"advanced"]];
}

static const CGFloat kSidebarSpacerHeight = 12;

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
