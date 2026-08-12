//
//  SettingsPermissionsViewController.m
//  Vibe
//

#import "SettingsPermissionsViewController.h"
#import "FolderAccessManager.h"
#import "VibeStrings.h"

static const CGFloat kPermissionsPaneHeight = 330;
static const CGFloat kFolderListWidth = 440;
static const CGFloat kFolderListHeight = 170;
static NSString *const kFolderCellIdentifier = @"FolderCell";

@interface SettingsPermissionsViewController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsPermissionsViewController {
    NSTableView *_tableView;
    NSButton *_removeButton;
    NSArray<NSString *> *_paths;
}

- (void)loadView {
    _paths = FolderAccessManager.sharedInstance.grantedFolderPaths;

    NSTextField *explain = [NSTextField wrappingLabelWithString:STR_SETTINGS_PERMISSIONS_EXPLAIN];
    explain.selectable = NO;
    explain.textColor = NSColor.secondaryLabelColor;
    explain.preferredMaxLayoutWidth = kFolderListWidth;
    [explain.widthAnchor constraintLessThanOrEqualToConstant:kFolderListWidth].active = YES;

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.headerView = nil;
    _tableView.allowsMultipleSelection = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 22;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:kFolderCellIdentifier];
    [_tableView addTableColumn:column];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = _tableView;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.widthAnchor constraintEqualToConstant:kFolderListWidth],
        [scrollView.heightAnchor constraintEqualToConstant:kFolderListHeight],
    ]];

    NSButton *addButton = [NSButton buttonWithTitle:STR_SETTINGS_ADD_FOLDER
                                             target:self action:@selector(addFolder:)];
    _removeButton = [NSButton buttonWithTitle:STR_SETTINGS_REMOVE_FOLDER
                                       target:self action:@selector(removeFolder:)];
    _removeButton.enabled = NO;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[addButton, _removeButton]];
    buttons.spacing = 8;

    NSGridView *grid = [NSGridView gridViewWithViews:@[@[explain], @[scrollView], @[buttons]]];
    grid.rowSpacing = 12;
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kPermissionsPaneHeight) grid:grid];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(grantedFoldersChanged:)
                                               name:FolderAccessManagerDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)grantedFoldersChanged:(NSNotification *)notification {
    [self refreshFromSettings];
}

- (void)refreshFromSettings {
    _paths = FolderAccessManager.sharedInstance.grantedFolderPaths;
    [_tableView reloadData];
    _removeButton.enabled = _tableView.selectedRow >= 0;
}

#pragma mark - Actions

- (void)addFolder:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [FolderAccessManager.sharedInstance noteOpenedURLs:panel.URLs];
        }
    }];
}

- (void)removeFolder:(id)sender {
    NSInteger row = _tableView.selectedRow;
    if (row >= 0) {
        [FolderAccessManager.sharedInstance removeFolderAtIndex:(NSUInteger)row];
    }
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_paths.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:kFolderCellIdentifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = kFolderCellIdentifier;
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell addSubview:icon];
        [cell addSubview:label];
        cell.imageView = icon;
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:16],
            [icon.heightAnchor constraintEqualToConstant:16],
            [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    NSString *path = _paths[(NSUInteger)row];
    cell.imageView.image = [NSWorkspace.sharedWorkspace iconForFile:path];
    cell.textField.stringValue = [self.class displayPath:path];
    cell.textField.toolTip = path;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _removeButton.enabled = _tableView.selectedRow >= 0;
}

// stringByAbbreviatingWithTildeInPath abbreviates against the sandbox
// container, not the user's home, so substitute the real home by hand.
+ (NSString *)displayPath:(NSString *)path {
    NSString *home = NSHomeDirectoryForUser(NSUserName());
    if (home.length > 0 && [path hasPrefix:[home stringByAppendingString:@"/"]]) {
        return [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return path;
}

@end
