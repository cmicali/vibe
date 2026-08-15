//
//  SettingsFilesViewController.m
//  Vibe
//

#import "SettingsFilesViewController.h"
#import "AppSettings.h"
#import "FolderAccessManager.h"
#import "MainPlayerController.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const CGFloat kFilesPaneHeight = 345;
static const CGFloat kFolderListWidth = 440;
static const CGFloat kFolderListHeight = 170;
static NSString *const kFolderCellIdentifier = @"FolderCell";
// Stable identifiers for the album-art choices, so the debug channel can pick
// one without touching localized text.
static NSString *const kAlbumArtFileOnly = @"file_only";
static NSString *const kAlbumArtFolder = @"file_then_folder";

@interface SettingsFilesViewController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsFilesViewController {
    NSTableView *_tableView;
    NSPopUpButton *_addCommonButton;
    NSButton *_removeButton;
    NSPopUpButton *_albumArtPopUp;
    NSArray<VibeGrantedFolder *> *_folders;
}

// Wraps at the folder list's width, so the pane has one text measure rather
// than two.
- (NSTextField *)explainLabel:(NSString *)text {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.selectable = NO;
    label.textColor = NSColor.secondaryLabelColor;
    label.preferredMaxLayoutWidth = kFolderListWidth;
    [label.widthAnchor constraintLessThanOrEqualToConstant:kFolderListWidth].active = YES;
    return label;
}

- (void)loadView {
    _folders = FolderAccessManager.sharedInstance.grantedFolders;

    _albumArtPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _albumArtPopUp.target = self;
    _albumArtPopUp.action = @selector(albumArtSourceChanged:);
    [_albumArtPopUp addItemWithTitle:STR_SETTINGS_ALBUM_ART_FILE_ONLY];
    _albumArtPopUp.lastItem.representedObject = kAlbumArtFileOnly;
    [_albumArtPopUp addItemWithTitle:STR_SETTINGS_ALBUM_ART_FOLDER];
    _albumArtPopUp.lastItem.representedObject = kAlbumArtFolder;
    NSTextField *explain = [self explainLabel:STR_SETTINGS_PERMISSIONS_EXPLAIN];

    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.headerView = nil;
    _tableView.allowsMultipleSelection = YES;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 22;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:kFolderCellIdentifier];
    [_tableView addTableColumn:column];
    // File URLs only: the drop reads with FileURLsOnly, so registering
    // NSPasteboardTypeURL too would show a copy cursor for a browser-link drag
    // the drop then rejects.
    [_tableView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

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

    NSStackView *permissions = [NSStackView stackViewWithViews:@[explain, scrollView, buttons]];
    permissions.orientation = NSUserInterfaceLayoutOrientationVertical;
    permissions.alignment = NSLayoutAttributeLeading;
    permissions.spacing = 12;

    // The window's standard form: label left, control right. The list keeps its
    // width, so this pane grows wider than the others rather than squeezing it.
    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_ALBUM_ART_LABEL], _albumArtPopUp],
        @[[NSTextField labelWithString:STR_SETTINGS_PERMISSIONS_LABEL], permissions],
    ]];
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementLeading;
    [grid rowAtIndex:0].bottomPadding = 8;
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kFilesPaneHeight) grid:grid];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(grantedFoldersChanged:)
                                               name:FolderAccessManagerDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)grantedFoldersChanged:(NSNotification *)notification {
    // Only the list. A new grant's effect on folder artwork is the player
    // controller's own observation of this notification, which runs whether or
    // not this pane was ever opened.
    [self refreshFromSettings];
}

- (void)refreshFromSettings {
    _folders = FolderAccessManager.sharedInstance.grantedFolders;
    [_tableView reloadData];
    _removeButton.enabled = _tableView.selectedRowIndexes.count > 0;
    [self rebuildCommonFolderMenu];
    NSString *albumArtSource = Settings.useFolderArtwork ? kAlbumArtFolder : kAlbumArtFileOnly;
    [_albumArtPopUp selectItemAtIndex:[_albumArtPopUp indexOfItemWithRepresentedObject:albumArtSource]];
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
        } else if ([self.class folderGranted:path in:self.grantedPaths]) {
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

// The manager owns the rule, alias spellings and the standing ~/Music grant
// included, so the menu's "(Already accessible)" state cannot drift from what
// adding the folder would actually do.
+ (BOOL)folderGranted:(NSString *)path in:(NSArray<NSString *> *)paths {
    return [FolderAccessManager path:path isCoveredByAnyOf:paths];
}

// An unavailable grant must not make the menu claim a folder is already
// accessible: it is exactly the one worth offering to add again. A restoring
// one still counts, so the menu does not briefly offer a duplicate at launch.
- (NSArray<NSString *> *)grantedPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:_folders.count];
    for (VibeGrantedFolder *folder in _folders) {
        if (folder.state != VibeGrantedFolderStateUnavailable) {
            [paths addObject:folder.path];
        }
    }
    return paths;
}

+ (NSString *)homeFolderPath {
    return FolderAccessManager.realHomeDirectory;
}

#pragma mark - Actions

- (void)albumArtSourceChanged:(id)sender {
    Settings.useFolderArtwork = [_albumArtPopUp.selectedItem.representedObject isEqual:kAlbumArtFolder];
    [self.playerController refreshFolderArtwork];
}

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
    return (NSInteger)_folders.count;
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
    VibeGrantedFolder *folder = _folders[(NSUInteger)row];
    // Rows include unmounted and unreachable folders, and a path-specific icon
    // lookup can synchronously wake their mount on the main thread. Use the
    // shared folder type icon instead.
    static NSImage *folderIcon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        folderIcon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypeFolder];
    });
    cell.imageView.image = folderIcon;
    // The manager's own answer, which costs no I/O: a row dims because its
    // bookmark would not resolve, never because this pane stat-ed the path.
    // Every branch sets both properties — the cells are recycled.
    BOOL unavailable = folder.state == VibeGrantedFolderStateUnavailable;
    NSString *display = [self.class displayPath:folder.path];
    cell.imageView.alphaValue = unavailable ? 0.4 : 1.0;
    cell.textField.textColor = unavailable ? NSColor.secondaryLabelColor : NSColor.labelColor;
    cell.textField.stringValue = unavailable
            ? [NSString stringWithFormat:STR_SETTINGS_FOLDER_UNAVAILABLE, display]
            : display;
    // The label truncates in the middle, so the tooltip carries the whole path
    // either way, and for a dead row says why it is still listed.
    cell.textField.toolTip = unavailable
            ? [NSString stringWithFormat:@"%@\n%@", folder.path, STR_SETTINGS_FOLDER_UNAVAILABLE_TIP]
            : folder.path;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _removeButton.enabled = _tableView.selectedRowIndexes.count > 0;
}

#pragma mark - Dropping folders in

// Folders only, asked of the pasteboard rather than the file system: this runs
// on the main thread for every mouse move of the drag, and a stat can block on
// an unreachable mount. A package is a directory but not a folder in UTI
// terms, so an app bundle is refused here rather than silently dropped later.
+ (NSDictionary<NSPasteboardReadingOptionKey, id> *)folderReadingOptions {
    return @{
        NSPasteboardURLReadingFileURLsOnlyKey: @YES,
        NSPasteboardURLReadingContentsConformToTypesKey: @[UTTypeFolder.identifier],
    };
}

// Retargeted onto the list as a whole: the rows are in the order the grants
// were added, so an insertion point between two of them would promise
// something the store cannot honor.
- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)operation {
    if (![info.draggingPasteboard canReadObjectForClasses:@[NSURL.class]
                                                  options:self.class.folderReadingOptions]) {
        return NSDragOperationNone;
    }
    [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
    return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)operation {
    NSArray<NSURL *> *dropped = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                                       options:self.class.folderReadingOptions];
    if (dropped.count == 0) {
        return NO;
    }
    // TRAP: a Finder drag delivers file-reference URLs (file:///.file/id=…),
    // which resolve to wherever the folder currently is. A grant is stored
    // against a path, so pin every drop to the one it has right now.
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:dropped.count];
    for (NSURL *url in dropped) {
        NSString *path = url.path;
        [urls addObject:path ? [NSURL fileURLWithPath:path isDirectory:YES] : url];
    }
    // The same funnel as Add Folder: the drag carries the sandbox grant, so the
    // bookmark can be made from it, and anything already covered is skipped.
    [FolderAccessManager.sharedInstance noteOpenedURLs:urls];
    return YES;
}

// stringByAbbreviatingWithTildeInPath abbreviates against the sandbox
// container, not the user's home, so substitute the real home by hand. The home
// folder itself abbreviates to a bare ~ — the Home Folder grant makes exactly
// that row, which would otherwise be the one entry spelled out in full.
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
