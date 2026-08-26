//
//  SettingsFilesViewController.m
//  Vibe
//

#import "SettingsFilesViewController.h"
#import "AppSettings.h"
#import "FolderAccessManager.h"
#import "MainPlayerController+Settings.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Sized so the list's card matches the other panes' width: the row insets it
// 16 on each side of the pane's 440-point content column.
static const CGFloat kFolderListWidth = 408;
static const CGFloat kFolderListHeight = 170;
static NSString *const kFolderCellIdentifier = @"FolderCell";
// Stable identifiers for the album-art choices, so the debug channel can pick
// one without touching localized text.
static NSString *const kAlbumArtFileOnly = @"file_only";
static NSString *const kAlbumArtFolder = @"file_then_folder";

// One Add Common Folder candidate, so call sites read .name/.path rather than
// decoding positional two-element arrays.
@interface VibeCommonFolder : NSObject
+ (instancetype)folderWithName:(NSString *)name path:(NSString *)path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@end

@implementation VibeCommonFolder

+ (instancetype)folderWithName:(NSString *)name path:(NSString *)path {
    VibeCommonFolder *folder = [[self alloc] init];
    folder.name = name;
    folder.path = path;
    return folder;
}

@end

@interface SettingsFilesViewController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsFilesViewController {
    NSTableView *_tableView;
    NSPopUpButton *_addCommonButton;
    NSButton *_removeButton;
    NSPopUpButton *_albumArtPopUp;
    NSPopUpButton *_folderSortPopUp;
    NSArray<VibeGrantedFolder *> *_folders;
    // Which of the Add Common Folder candidates are on disk, probed off the
    // main thread; nil, or a path with no entry, means not yet probed. Two of
    // the four are file-provider roots — iCloud Drive and Dropbox under
    // CloudStorage — where a stat can block for as long as the provider takes,
    // which is the same reason grantedFolders costs no I/O. Main-confined,
    // with the generation dropping a probe a newer one has overtaken.
    NSDictionary<NSString *, NSNumber *> *_commonFolderExists;
    uint64_t _commonFolderProbeGeneration;
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
    _folders = @[];

    // The choices carry the VibeFolderOpenSort itself: the stored identifiers
    // are AppSettings' business, and a menu item has no reason to know them.
    _folderSortPopUp = [self popUpButtonWithWidth:260 action:@selector(folderOpenSortChanged:)];
    [_folderSortPopUp addItemWithTitle:STR_SETTINGS_FOLDER_SORT_NAME];
    _folderSortPopUp.lastItem.representedObject = @(VibeFolderOpenSortName);
    [_folderSortPopUp addItemWithTitle:STR_SETTINGS_FOLDER_SORT_NEWEST_FIRST];
    _folderSortPopUp.lastItem.representedObject = @(VibeFolderOpenSortNewestFirst);
    [_folderSortPopUp addItemWithTitle:STR_SETTINGS_FOLDER_SORT_AS_RECEIVED];
    _folderSortPopUp.lastItem.representedObject = @(VibeFolderOpenSortAsReceived);

    _albumArtPopUp = [self popUpButtonWithWidth:260 action:@selector(albumArtSourceChanged:)];
    [_albumArtPopUp addItemWithTitle:STR_SETTINGS_ALBUM_ART_FILE_ONLY];
    _albumArtPopUp.lastItem.representedObject = kAlbumArtFileOnly;
    [_albumArtPopUp addItemWithTitle:STR_SETTINGS_ALBUM_ART_FOLDER];
    _albumArtPopUp.lastItem.representedObject = kAlbumArtFolder;
    NSTextField *explain = [self explainLabel:[NSString stringWithFormat:STR_SETTINGS_PERMISSIONS_EXPLAIN,
                                                                        VibeAppName()]];

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
    // Build an unprobed menu for layout; selection triggers the real refresh.
    [self rebuildCommonFolderMenu];
    _removeButton = [NSButton buttonWithTitle:STR_SETTINGS_REMOVE_FOLDER
                                       target:self action:@selector(removeFolder:)];
    _removeButton.enabled = NO;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[addButton, _addCommonButton, _removeButton]];
    buttons.spacing = 8;

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_FOLDER_SORT_LABEL control:_folderSortPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALBUM_ART_LABEL control:_albumArtPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PERMISSIONS_LABEL rows:@[
            [SettingsRowView rowWithContentView:explain],
            [SettingsRowView rowWithContentView:scrollView],
            [SettingsRowView rowWithContentView:buttons],
        ]],
    ]];
}

// Observed only while visible, like the base class's own observers: the window
// controller keeps every pane alive forever, so a loadView-registered observer
// would reload the list and stat the file-provider roots on every folder open
// for a pane nobody can see. refreshFromSettings on each appearance covers
// whatever changed while hidden.
- (void)viewDidAppear {
    [super viewDidAppear];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(grantedFoldersChanged:)
                                               name:FolderAccessManagerDidChangeNotification
                                             object:nil];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:FolderAccessManagerDidChangeNotification
                                                object:nil];
}

- (void)grantedFoldersChanged:(NSNotification *)notification {
    // Only the list. A new grant's effect on folder art is the player
    // controller's own observation of this notification, which runs whether or
    // not this pane was ever opened.
    [self refreshFromSettings];
}

- (void)refreshFromSettings {
    _folders = FolderAccessManager.sharedInstance.grantedFolders;
    [_tableView reloadData];
    _removeButton.enabled = _tableView.selectedRowIndexes.count > 0;
    [self refreshCommonFolderMenu];
    NSString *albumArtSource = AppSettings.sharedInstance.useFolderArt ? kAlbumArtFolder : kAlbumArtFileOnly;
    [_albumArtPopUp selectItemAtIndex:[_albumArtPopUp indexOfItemWithRepresentedObject:albumArtSource]];
    [_folderSortPopUp selectItemAtIndex:[_folderSortPopUp indexOfItemWithRepresentedObject:
            @(AppSettings.sharedInstance.folderOpenSort)]];
}

// Draws the menu from what is known now, then re-probes the candidate paths
// off the main thread and redraws when the answers land. The two steps are
// separate methods so the redraw cannot re-trigger the probe.
- (void)refreshCommonFolderMenu {
    [self rebuildCommonFolderMenu];
    uint64_t generation = ++_commonFolderProbeGeneration;
    NSArray<NSString *> *paths = SettingsFilesViewController.commonFolderCandidatePaths;
    __weak SettingsFilesViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary<NSString *, NSNumber *> *exists =
                [NSMutableDictionary dictionaryWithCapacity:paths.count];
        for (NSString *path in paths) {
            exists[path] = @([SettingsFilesViewController folderExists:path]);
        }
        run_on_main_thread({
            SettingsFilesViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_commonFolderProbeGeneration) {
                return; // a newer probe owns the answer now
            }
            strongSelf->_commonFolderExists = exists;
            [strongSelf rebuildCommonFolderMenu];
        });
    });
}

// A pull-down takes its button title from the item at index 0, which is never
// chosen. Enablement is ours to set (autoenablesItems off): a folder that is
// not there, or already covered by a grant, stays visible but dead. The button
// itself always opens, so the menu can show why an entry is unavailable.
//
// No file system here: it runs on the main thread, and every existence answer
// comes from the probed cache. A path with no answer yet is offered as
// available — the panel simply opens staged on it — rather than dimmed on a
// guess the probe may contradict a moment later.
- (void)rebuildCommonFolderMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    [menu addItemWithTitle:STR_SETTINGS_ADD_COMMON_FOLDER action:NULL keyEquivalent:@""];
    for (VibeCommonFolder *folder in [self.class commonFoldersWithExistence:_commonFolderExists]) {
        NSString *name = folder.name;
        NSString *path = folder.path;
        NSString *title = name;
        BOOL available = YES;
        NSNumber *exists = _commonFolderExists[path];
        if (exists && !exists.boolValue) {
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

// Dropbox moved under ~/Library/CloudStorage when it became a file provider —
// older installs keep ~/Dropbox, newer ones leave a symlink there, and neither
// is guaranteed — so both spellings are candidates and the probe decides.
static NSString *const kDropboxClassicSubpath = @"Dropbox";
static NSString *const kDropboxCloudStorageSubpath = @"Library/CloudStorage/Dropbox";

// Every path the menu may offer, for the off-main existence probe. Both
// Dropbox spellings are here; commonFoldersWithExistence: picks one.
+ (NSArray<NSString *> *)commonFolderCandidatePaths {
    NSString *home = self.homeFolderPath;
    return @[
        home,
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs"],
        [home stringByAppendingPathComponent:kDropboxClassicSubpath],
        [home stringByAppendingPathComponent:kDropboxCloudStorageSubpath],
    ];
}

// Name and path of each offered folder, resolved against the probed existence
// answers. Pure — no file system — so it is safe on the main thread; an
// unprobed path counts as present, which is what keeps the classic Dropbox
// location the one offered until the probe says otherwise.
+ (NSArray<VibeCommonFolder *> *)commonFoldersWithExistence:
        (NSDictionary<NSString *, NSNumber *> *)existsByPath {
    NSString *home = self.homeFolderPath;
    NSString *dropbox = [home stringByAppendingPathComponent:kDropboxClassicSubpath];
    NSNumber *classicExists = existsByPath[dropbox];
    if (classicExists && !classicExists.boolValue) {
        dropbox = [home stringByAppendingPathComponent:kDropboxCloudStorageSubpath];
    }
    return @[
        [VibeCommonFolder folderWithName:STR_SETTINGS_FOLDER_HOME path:home],
        [VibeCommonFolder folderWithName:STR_SETTINGS_FOLDER_DOCUMENTS
                                    path:[home stringByAppendingPathComponent:@"Documents"]],
        [VibeCommonFolder folderWithName:VibeNotLocalized(@"iCloud Drive")
                                    path:[home stringByAppendingPathComponent:
                                            @"Library/Mobile Documents/com~apple~CloudDocs"]],
        [VibeCommonFolder folderWithName:VibeNotLocalized(@"Dropbox") path:dropbox],
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

// No live effect: the order governs the next open, and re-sorting the playlist
// already on screen would throw away an order the user may have built by hand.
- (void)folderOpenSortChanged:(id)sender {
    AppSettings.sharedInstance.folderOpenSort =
            (VibeFolderOpenSort)[_folderSortPopUp.selectedItem.representedObject integerValue];
}

- (void)albumArtSourceChanged:(id)sender {
    AppSettings.sharedInstance.useFolderArt = [_albumArtPopUp.selectedItem.representedObject isEqual:kAlbumArtFolder];
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectFolderArt];
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
    panel.message = [NSString stringWithFormat:STR_SETTINGS_FOLDER_GRANT_MESSAGE,
                                               VibeAppName(), sender.title];
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
            ? [NSString stringWithFormat:@"%@\n%@", folder.path,
                                         [NSString stringWithFormat:STR_SETTINGS_FOLDER_UNAVAILABLE_TIP,
                                                                    VibeAppName()]]
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
