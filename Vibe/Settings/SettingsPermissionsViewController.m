//
//  SettingsPermissionsViewController.m
//  Vibe
//

#import "SettingsPermissionsViewController.h"
#import "FolderAccessManager.h"
#import "FolderAccessRules.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <pwd.h>
#import <unistd.h>

static const CGFloat kPermissionsPaneHeight = 330;
static const CGFloat kFolderListWidth = 440;
static const CGFloat kFolderListHeight = 170;
static NSString *const kFolderCellIdentifier = @"FolderCell";

@interface SettingsPermissionsViewController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsPermissionsViewController {
    NSTableView *_tableView;
    NSPopUpButton *_addCommonButton;
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
    _tableView.allowsMultipleSelection = YES;
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
    _addCommonButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [self rebuildCommonFolderMenu];
    _removeButton = [NSButton buttonWithTitle:STR_SETTINGS_REMOVE_FOLDER
                                       target:self action:@selector(removeFolder:)];
    _removeButton.enabled = NO;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[addButton, _addCommonButton, _removeButton]];
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
    _removeButton.enabled = _tableView.selectedRowIndexes.count > 0;
    [self rebuildCommonFolderMenu];
}

// A pull-down takes its button title from the item at index 0, which is never
// chosen. Enablement is ours to set (autoenablesItems off): a folder that is
// not there, or already covered by a grant, stays visible but dead. The button
// itself always opens, so the menu can show why an entry is unavailable.
- (void)rebuildCommonFolderMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    [menu addItemWithTitle:STR_SETTINGS_ADD_COMMON_FOLDER action:NULL keyEquivalent:@""];
    for (NSArray<NSString *> *folder in self.class.commonFolders) {
        NSString *name = folder.firstObject;
        NSString *path = folder.lastObject;
        NSString *title = name;
        BOOL available = YES;
        if (![self.class folderExists:path]) {
            title = [NSString stringWithFormat:STR_SETTINGS_FOLDER_NOT_FOUND, name];
            available = NO;
        } else if ([self.class folderGranted:path in:_paths]) {
            title = [NSString stringWithFormat:STR_SETTINGS_FOLDER_ALREADY_ADDED, name];
            available = NO;
        }
        NSMenuItem *item = [menu addItemWithTitle:title
                                           action:@selector(addCommonFolder:)
                                    keyEquivalent:@""];
        item.target = self;
        item.representedObject = path;
        item.toolTip = [self.class displayPath:path];
        item.enabled = available;
    }
    _addCommonButton.menu = menu;
}

// Name and path of each offered folder. Dropbox moved under
// ~/Library/CloudStorage when it became a file provider — older installs keep
// ~/Dropbox, newer ones leave a symlink there, and neither is guaranteed — so
// offer the classic location and fall back to the new one.
+ (NSArray<NSArray<NSString *> *> *)commonFolders {
    NSString *home = self.homeFolderPath;
    NSString *dropbox = [home stringByAppendingPathComponent:@"Dropbox"];
    if (![self folderExists:dropbox]) {
        dropbox = [home stringByAppendingPathComponent:@"Library/CloudStorage/Dropbox"];
    }
    return @[
        @[STR_SETTINGS_FOLDER_HOME, home],
        @[STR_SETTINGS_FOLDER_DOCUMENTS, [home stringByAppendingPathComponent:@"Documents"]],
        @[VibeNotLocalized(@"iCloud Drive"),
          [home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs"]],
        @[VibeNotLocalized(@"Dropbox"), dropbox],
    ];
}

+ (BOOL)folderExists:(NSString *)path {
    BOOL isDirectory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]
            && isDirectory;
}

+ (BOOL)folderGranted:(NSString *)path in:(NSArray<NSString *> *)paths {
    for (NSString *granted in paths) {
        if (VibePathIsUnderFolder(path, granted)) {
            return YES;
        }
    }
    return NO;
}

// The real home. Inside the sandbox NSHomeDirectory answers with the container
// and NSHomeDirectoryForUser does too, container path and all; getpwuid is the
// documented way to the on-disk home.
+ (NSString *)homeFolderPath {
    struct passwd *entry = getpwuid(getuid());
    if (entry && entry->pw_dir) {
        return [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->pw_dir
                                                                         length:strlen(entry->pw_dir)];
    }
    return NSHomeDirectory();
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

// The sandbox has no way to grant a folder without the user picking it, so the
// menu can only stage the panel: opened on the chosen folder, with nothing
// selected, so confirming returns that folder itself.
- (void)addCommonFolder:(NSMenuItem *)sender {
    NSString *path = sender.representedObject;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.directoryURL = [NSURL fileURLWithPath:path isDirectory:YES];
    panel.message = [NSString stringWithFormat:STR_SETTINGS_FOLDER_GRANT_MESSAGE, sender.title];
    panel.prompt = STR_SETTINGS_FOLDER_GRANT_BUTTON;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [FolderAccessManager.sharedInstance noteOpenedURLs:panel.URLs];
        }
    }];
}

- (void)removeFolder:(id)sender {
    NSIndexSet *rows = _tableView.selectedRowIndexes;
    if (rows.count > 0) {
        [FolderAccessManager.sharedInstance removeFoldersAtIndexes:rows];
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
    // Retained rows deliberately include unmounted and unreachable folders.
    // A path-specific icon lookup can synchronously wake their mount on the
    // main thread, so use the shared folder type icon instead.
    static NSImage *folderIcon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        folderIcon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypeFolder];
    });
    cell.imageView.image = folderIcon;
    cell.textField.stringValue = [self.class displayPath:path];
    cell.textField.toolTip = path;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _removeButton.enabled = _tableView.selectedRowIndexes.count > 0;
}

// stringByAbbreviatingWithTildeInPath abbreviates against the sandbox
// container, not the user's home, so substitute the real home by hand.
// The home folder itself abbreviates to a bare ~, not to its full path: the
// Home Folder grant makes exactly that row, and it would otherwise be the one
// entry spelled out while its own subfolders read as ~/….
+ (NSString *)displayPath:(NSString *)path {
    NSString *home = self.homeFolderPath;
    if (home.length == 0) {
        return path;
    }
    if ([path isEqualToString:home] || [path isEqualToString:[home stringByAppendingString:@"/"]]) {
        return @"~";
    }
    if ([path hasPrefix:[home stringByAppendingString:@"/"]]) {
        return [@"~" stringByAppendingString:[path substringFromIndex:home.length]];
    }
    return path;
}

@end
