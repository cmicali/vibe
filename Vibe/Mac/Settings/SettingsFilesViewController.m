//
//  SettingsFilesViewController.m
//  Vibe
//

#import "SettingsFilesViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "FolderAccessManager.h"
#import "MainPlayerController+Settings.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kFolderCellIdentifier = @"FolderCell";
// Stable identifiers, so the debug channel can pick an item by name.
static NSString *const kAlbumArtFileOnly = @"file_only";
static NSString *const kAlbumArtFolder = @"file_then_folder";

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
    VibeSwitch *_convertEnabledSwitch, *_deleteOriginalSwitch;
    NSPopUpButton *_convertDestinationPopUp;
    NSArray<VibeGrantedFolder *> *_folders;
    // Probed off main: two candidates are file-provider roots, where a stat
    // blocks for as long as the provider takes. No entry means not yet probed.
    NSDictionary<NSString *, NSNumber *> *_commonFolderExists;
    uint64_t _commonFolderProbeGeneration;
}

- (void)loadView {
    _folders = @[];

    // The items carry the enum; the stored identifiers are AppSettings'.
    _folderSortPopUp = [self popUpButtonWithWidth:260 action:@selector(folderOpenSortChanged:)];
    for (VibeFolderOpenSort sort = VibeFolderOpenSortName; sort <= VibeFolderOpenSortAsReceived; sort++) {
        [self addItem:VibeFolderOpenSortDisplayName(sort) value:@(sort) to:_folderSortPopUp];
    }

    _albumArtPopUp = [self popUpButtonWithWidth:260 action:@selector(albumArtSourceChanged:)];
    [self addItem:STR_SETTINGS_ALBUM_ART_FILE_ONLY value:kAlbumArtFileOnly to:_albumArtPopUp];
    [self addItem:STR_SETTINGS_ALBUM_ART_FOLDER value:kAlbumArtFolder to:_albumArtPopUp];
    NSTextField *explainLabel = [self wrappingLabelWithString:STR_SETTINGS_PERMISSIONS_EXPLAIN];

    _tableView = [SettingsRowView listTableWithColumnIdentifiers:@[kFolderCellIdentifier] delegate:self];
    _tableView.allowsMultipleSelection = YES;
    // File URLs only: NSPasteboardTypeURL would show a copy cursor for a
    // browser-link drag the drop then rejects.
    [_tableView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    SettingsRowView *listRow = [SettingsRowView rowWithTableView:_tableView rowCount:7];

    NSButton *addButton = [NSButton buttonWithTitle:STR_SETTINGS_ADD_FOLDER
                                             target:self action:@selector(addFolder:)];
    _addCommonButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    // Unprobed, for layout; refreshFromSettings probes.
    [self rebuildCommonFolderMenu];
    _removeButton = [NSButton buttonWithTitle:STR_SETTINGS_REMOVE_FOLDER
                                       target:self action:@selector(removeFolder:)];
    [SettingsRowView setControl:_removeButton enabled:NO];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[addButton, _addCommonButton, _removeButton]];
    buttons.spacing = 8;
    SettingsRowView *buttonRow = [SettingsRowView rowWithContentView:buttons];

    _convertEnabledSwitch = [self switchWithAction:@selector(toggleConversion:)];
    _deleteOriginalSwitch = [self switchWithAction:@selector(toggleDeleteOriginal:)];
    _convertDestinationPopUp = [self popUpButtonWithWidth:220 action:@selector(conversionDestinationChanged:)];
    [self addItem:STR_SETTINGS_CONVERT_DEST_BESIDE value:@NO to:_convertDestinationPopUp];
    [self addItem:STR_SETTINGS_CONVERT_DEST_ASK value:@YES to:_convertDestinationPopUp];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_FOLDER_SORT_LABEL control:_folderSortPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALBUM_ART_LABEL control:_albumArtPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PERMISSIONS_LABEL rows:@[
            [SettingsRowView rowWithContentView:explainLabel],
            listRow,
            buttonRow,
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_CONVERT_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_CONVERT_ENABLED control:_convertEnabledSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_CONVERT_DEST_LABEL control:_convertDestinationPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_DELETE_ORIGINAL control:_deleteOriginalSwitch],
        ]],
    ]];
    // The list is its own divider; the section's hairlines would double it.
    listRow.showsTopSeparator = NO;
    buttonRow.showsTopSeparator = NO;
}

// Observed only while on screen: the pane outlives the window, and each
// appearance's refresh covers what changed while hidden.
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
    // Only the list; folder art observes this notification itself.
    [self refreshFromSettings];
}

- (void)refreshFromSettings {
    _folders = FolderAccessManager.sharedInstance.grantedFolders;
    [_tableView reloadData];
    [SettingsRowView setControl:_removeButton enabled:_tableView.selectedRowIndexes.count > 0];
    [self refreshCommonFolderMenu];
    NSString *albumArtSource = AppSettings.sharedInstance.useFolderArt ? kAlbumArtFolder : kAlbumArtFileOnly;
    [self selectValue:albumArtSource in:_albumArtPopUp];
    [self selectValue:@(AppSettings.sharedInstance.folderOpenSort) in:_folderSortPopUp];
    BOOL enabled = AppSettings.sharedInstance.convertEnabled;
    _convertEnabledSwitch.state = StateForBOOL(enabled);
    [SettingsRowView setControl:_deleteOriginalSwitch enabled:enabled];
    [SettingsRowView setControl:_convertDestinationPopUp enabled:enabled];
    _deleteOriginalSwitch.state = StateForBOOL(AppSettings.sharedInstance.deleteOriginalAfterConvert);
    [self selectValue:@(AppSettings.sharedInstance.convertAsksWhereToSave) in:_convertDestinationPopUp];
}

// Separate from rebuildCommonFolderMenu so the redraw cannot re-trigger the probe.
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
                return;
            }
            strongSelf->_commonFolderExists = exists;
            [strongSelf rebuildCommonFolderMenu];
        });
    });
}

// A pull-down takes its title from item 0. Main thread, so no file system:
// existence comes from the probe, and an unprobed path is offered rather than
// dimmed on a guess.
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

// Dropbox lives at either spelling depending on the install; the probe decides.
static NSString *const kDropboxClassicSubpath = @"Dropbox";
static NSString *const kDropboxCloudStorageSubpath = @"Library/CloudStorage/Dropbox";

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

// No file system, so safe on main. An unprobed path counts as present.
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

// The manager's rule, so "Already accessible" cannot drift from what adding
// the folder would do.
+ (BOOL)folderGranted:(NSString *)path in:(NSArray<NSString *> *)paths {
    return [FolderAccessManager path:path isCoveredByAnyOf:paths];
}

// An unavailable grant is the folder worth offering again; a restoring one
// still counts, or the menu briefly offers a duplicate at launch.
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

- (void)toggleConversion:(VibeSwitch *)sender {
    AppSettings.sharedInstance.convertEnabled = sender.state == NSControlStateValueOn;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectConvertMenu];
    [self refreshFromSettings];
}

- (void)toggleDeleteOriginal:(VibeSwitch *)sender {
    AppSettings.sharedInstance.deleteOriginalAfterConvert = sender.state == NSControlStateValueOn;
}

- (void)conversionDestinationChanged:(id)sender {
    AppSettings.sharedInstance.convertAsksWhereToSave = [_convertDestinationPopUp.selectedItem.representedObject boolValue];
}

// No live effect: re-sorting the playlist on screen would discard an order
// built by hand.
- (void)folderOpenSortChanged:(id)sender {
    AppSettings.sharedInstance.folderOpenSort =
            (VibeFolderOpenSort)[_folderSortPopUp.selectedItem.representedObject integerValue];
}

- (void)albumArtSourceChanged:(id)sender {
    AppSettings.sharedInstance.useFolderArt = [_albumArtPopUp.selectedItem.representedObject isEqual:kAlbumArtFolder];
    // TRAP: the resolver caches this setting and FolderArt is its only re-read;
    // without it the write is never observed.
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

// The sandbox grants nothing unpicked, so stage the panel on the folder with
// nothing selected: confirming returns the folder itself.
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

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [SettingsRowView listRowViewForRow:row];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:kFolderCellIdentifier
                                                        inTableView:tableView imagePosition:NSImageLeft];
    cell.textField.lineBreakMode = NSLineBreakByTruncatingMiddle;
    VibeGrantedFolder *folder = _folders[(NSUInteger)row];
    static NSImage *folderIcon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        folderIcon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypeFolder];
    });
    cell.imageView.image = folderIcon;
    // TRAP: never stat a row, path-specific icon lookups included. This runs
    // on main per reload, and a dead mount blocks for an automounter timeout;
    // the state is the manager's resolve, which costs no I/O.
    BOOL unavailable = folder.state == VibeGrantedFolderStateUnavailable;
    NSString *display = [self.class displayPath:folder.path];
    cell.alphaValue = unavailable ? 0.5 : 1;
    cell.textField.stringValue = unavailable
            ? [NSString stringWithFormat:STR_SETTINGS_FOLDER_UNAVAILABLE, display]
            : display;
    cell.textField.toolTip = unavailable
            ? [NSString stringWithFormat:@"%@\n%@", folder.path,
                                         [NSString stringWithFormat:STR_SETTINGS_FOLDER_UNAVAILABLE_TIP,
                                                                    VibeAppName()]]
            : folder.path;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [SettingsRowView setControl:_removeButton enabled:_tableView.selectedRowIndexes.count > 0];
}

#pragma mark - Dropping folders in

// TRAP: never stat a drag. Validation runs on main per mouse move, so
// folder-ness is asked of the pasteboard; public.folder also refuses a package.
+ (NSDictionary<NSPasteboardReadingOptionKey, id> *)folderReadingOptions {
    return @{
        NSPasteboardURLReadingFileURLsOnlyKey: @YES,
        NSPasteboardURLReadingContentsConformToTypesKey: @[UTTypeFolder.identifier],
    };
}

// Retargeted onto the whole list: grants keep the order they were added in.
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
    // TRAP: a Finder drag delivers file-reference URLs (file:///.file/id=…);
    // a grant is stored against a path, so pin each to its current one.
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:dropped.count];
    for (NSURL *url in dropped) {
        NSString *path = url.path;
        [urls addObject:path ? [NSURL fileURLWithPath:path isDirectory:YES] : url];
    }
    // The drag carries the sandbox grant the bookmark is made from.
    [FolderAccessManager.sharedInstance noteOpenedURLs:urls];
    return YES;
}

// stringByAbbreviatingWithTildeInPath abbreviates against the sandbox
// container, not the real home.
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
