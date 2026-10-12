//
//  FilesRootViewController.m
//  Vibe (iOS)
//

#import "FilesRootViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AudioTrackMetadataCache.h"
#import "BrowserRules.h"
#import "DocumentTypes.h"
#import "DropboxMirror.h"
#import "FileRow.h"
#import "FileSearchRules.h"
#import "FilePaths.h"
#import "FolderViewController.h"
#import "LinkDropRules.h"
#import "LinkStore.h"
#import "LocationStore.h"
#import "OpenURLSheetController.h"
#import "OpenURLSheetController+Debug.h"
#import "PlaybackController.h"
#import "PlaybackController+ReplacePrompt.h"
#import "RecentsViewController.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

static NSString *const kSourceCellIdentifier = @"source";
static NSString *const kActionCellIdentifier = @"action";

@interface FilesRootViewController () <UIDocumentPickerDelegate>
@end

// Each pasted item's URL and text, by the pasteboard types a drop is read
// for (VibeDropURLsOfItems). The providers load off main. Completes on main.
static void VibeLoadPastedItems(NSArray<NSItemProvider *> *providers,
                                void (^completion)(NSArray<NSDictionary<NSString *, NSString *> *> *items)) {
    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    for (NSItemProvider *provider in providers) {
        NSMutableDictionary<NSString *, NSString *> *item = [NSMutableDictionary dictionary];
        [items addObject:item];
        if ([provider canLoadObjectOfClass:NSURL.class]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:NSURL.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                NSURL *url = [(NSObject *)object isKindOfClass:NSURL.class] ? (NSURL *)object : nil;
                @synchronized (item) {
                    if (url) {
                        item[url.isFileURL ? kVibeDropTypeFileURL : kVibeDropTypeURL] = url.absoluteString;
                    }
                }
                dispatch_group_leave(group);
            }];
        }
        if ([provider canLoadObjectOfClass:NSString.class]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:NSString.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                NSString *text = [(NSObject *)object isKindOfClass:NSString.class] ? (NSString *)object : nil;
                @synchronized (item) {
                    if (text) {
                        item[kVibeDropTypeText] = text;
                    }
                }
                dispatch_group_leave(group);
            }];
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(items);
    });
}

@implementation FilesRootViewController {
    PlaybackController *_playback;
    BOOL _appending;
    // The stack's one metadata cache, made when its first folder needs art.
    AudioTrackMetadataCache *_artCache;

    // Which picker is up: a location grant, or a one-off pick.
    BOOL _pickingLocation;
    // Cancels the link Open URL's sheet or the paste row is resolving. The
    // paste row spins while it is set and no sheet is up.
    dispatch_block_t _cancelLinkResolve;
    // The clipboard's change count when it was last checked, and whether it
    // then probably held a web link. The paste row shows only while it does.
    NSInteger _clipboardChangeCount;
    BOOL _clipboardHasLink;
    // Whether Dropbox was linked when the root last reloaded. The rows read
    // this, never the live account. The account flips off main before its
    // change is posted. A live read in that gap maps a folder's row to the
    // folder beside it.
    BOOL _dropboxLinked;
    // Open URL's sheet while it is up.
    OpenURLSheetController *_linkSheet;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _playback = playback;
        _appending = appending;
        _clipboardChangeCount = NSIntegerMin;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // The add sheet says what a tap in it does: it is the Files tab's
    // twin, and there a tap plays.
    self.navigationItem.title = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : STR_TAB_FILES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sourcesDidChange:)
                                               name:VibeSearchFoldersDidChangeNotification
                                             object:LocationStore.shared];
    if (_appending && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                              target:self
                                                              action:@selector(dismissSheet)];
    }
    UIBarButtonItem *addLocation = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                                     menu:[self addLocationMenu]];
    addLocation.accessibilityLabel = STR_BROWSER_ADD_LOCATION;
    self.navigationItem.rightBarButtonItem = addLocation;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(clipboardMayHaveChanged:)
                                               name:UIPasteboardChangedNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(clipboardMayHaveChanged:)
                                               name:UISceneDidActivateNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(sourcesDidChange:)
                                               name:VibeDropboxAccountDidChangeNotification
                                             object:DropboxMirror.shared.client];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshClipboardLink];
    _dropboxLinked = DropboxMirror.shared.client.isLinked;
    [self.tableView reloadData];
}

#pragma mark - What the stack shares

// One cache for a stack of folders, made by the first screen that needs it:
// each cache opens its own store, which lists the whole metadata cache
// directory when made.
- (AudioTrackMetadataCache *)stackArtCache {
    if (!_artCache) {
        _artCache = [[AudioTrackMetadataCache alloc] init];
    }
    return _artCache;
}

// Every folder of the stack follows. A folder pushed later is handed it.
- (void)setEqualizerSurfaceVisible:(BOOL)equalizerSurfaceVisible {
    if (_equalizerSurfaceVisible == equalizerSurfaceVisible) {
        return;
    }
    _equalizerSurfaceVisible = equalizerSurfaceVisible;
    for (UIViewController *controller in self.navigationController.viewControllers) {
        if ([controller isKindOfClass:FolderViewController.class]) {
            ((FolderViewController *)controller).equalizerSurfaceVisible = equalizerSurfaceVisible;
        }
    }
}

// The account went or came, or a location was granted or removed.
- (void)sourcesDidChange:(NSNotification *)notification {
    _dropboxLinked = DropboxMirror.shared.client.isLinked;
    [self.tableView reloadData];
}

// The root's plus. It is built each time it opens. Connect to Dropbox then
// follows the account.
- (UIMenu *)addLocationMenu {
    __weak FilesRootViewController *weakSelf = self;
    UIDeferredMenuElement *items = [UIDeferredMenuElement elementWithUncachedProvider:
            ^(void (^completion)(NSArray<UIMenuElement *> *)) {
        UIAction *addFolder = VibeMenuAction(STR_SETTINGS_ADD_FOLDER, @"folder.badge.plus", ^{
            [weakSelf presentPickerForLocation:YES];
        });
        // iCloud Drive named here: it is where most music on a phone is.
        addFolder.subtitle = STR_BROWSER_ADD_FOLDER_CAPTION;
        if (DropboxMirror.shared.client.isLinked) {
            completion(@[addFolder]);
            return;
        }
        UIAction *connect = [UIAction actionWithTitle:STR_SETTINGS_DROPBOX_CONNECT
                                                image:[UIImage imageNamed:@"dropbox-glyph"]
                                           identifier:nil
                                              handler:^(UIAction *action) {
            [weakSelf connectDropbox];
        }];
        completion(@[addFolder, connect]);
    }];
    return [UIMenu menuWithChildren:@[items]];
}

#pragma mark - Open URL

// The sheet stays up while the link resolves. Every way it closes cancels
// that.
- (void)presentLinkSheet {
    __weak FilesRootViewController *weakSelf = self;
    OpenURLSheetController *sheet = [[OpenURLSheetController alloc] initWithOpen:^(NSString *text) {
        [weakSelf openLinkText:text];
    } cancel:^{
        [weakSelf cancelLinkSheet];
    }];
    _linkSheet = sheet;
    [sheet presentFrom:self];
}

// Cancel: the sheet closes, and a link still resolving stops.
- (void)cancelLinkSheet {
    dispatch_block_t cancel = _cancelLinkResolve;
    [self closeLinkSheetThen:nil];
    if (cancel) {
        cancel();
    }
}

// Closes the sheet, then runs then. With no sheet up, then runs at once.
- (void)closeLinkSheetThen:(nullable dispatch_block_t)then {
    OpenURLSheetController *sheet = _linkSheet;
    _linkSheet = nil;
    if (sheet) {
        [sheet dismissThen:then];
    }
    else if (then) {
        then();
    }
}

// The sheet's Open and the paste row both come here, and only while no link
// resolves. The add sheet takes the Add token before the resolve, as
// Favorites does, and closes once the link is added. A failure closes Open
// URL's sheet first, then shows its alert. Never the inbox road: it does not
// persist.
- (void)openLinkText:(NSString *)text {
    if (VibeLinkTextIsBlank(text) || _cancelLinkResolve) {
        return;
    }
    // Found when the failure lands: the add sheet may be gone by then, and
    // the card may be up.
    __weak UIWindow *window = self.view.window;
    __weak FilesRootViewController *weakSelf = self;
    void (^settled)(NSURL *, NSError *) = ^(NSURL *file, NSError *error) {
        NSString *message = error ? [LinkStore messageForError:error brief:NO] : nil;
        dispatch_block_t alert = ^{
            UIViewController *root = window.rootViewController;
            if (message && root) {
                [root.vibeTopmostPresenter vibePresentAlertWithTitle:STR_LINK_ERROR_TITLE message:message];
            }
        };
        FilesRootViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            alert();
            return;
        }
        strongSelf->_cancelLinkResolve = nil;
        [strongSelf reloadPasteRow];
        if (file && strongSelf->_appending) {
            // The add sheet takes Open URL's sheet with it.
            strongSelf->_linkSheet = nil;
            [strongSelf dismissSheet];
            return;
        }
        [strongSelf closeLinkSheetThen:alert];
    };
    if (!_appending) {
        _cancelLinkResolve = [_playback openLinkString:text replacingPlaylistFrom:self completion:settled];
    }
    else {
        PlaybackController *playback = _playback;
        uint64_t token = [playback addRequestToken];
        _cancelLinkResolve = [LinkStore.shared resolveURLString:text completion:^(NSURL *file, NSError *error) {
            if (file) {
                [playback addURLs:@[file] token:token];
            }
            settled(file, error);
        }];
    }
    [self reloadPasteRow];
    _linkSheet.resolving = _cancelLinkResolve != nil;
}

#pragma mark - The paste row

// Neither question reads the clipboard, so neither raises the paste prompt:
// pattern detection, and whether it holds a URL at all. A change count
// already checked asks nothing.
- (void)refreshClipboardLink {
    UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
    NSInteger changeCount = pasteboard.changeCount;
    if (changeCount == _clipboardChangeCount) {
        return;
    }
    _clipboardChangeCount = changeCount;
    BOOL hasURLs = pasteboard.hasURLs;
    __weak FilesRootViewController *weakSelf = self;
    [pasteboard detectPatternsForPatterns:[NSSet setWithObject:UIPasteboardDetectionPatternProbableWebURL]
                        completionHandler:^(NSSet<UIPasteboardDetectionPattern> *patterns, NSError *error) {
        BOOL hasLink = hasURLs || [patterns containsObject:UIPasteboardDetectionPatternProbableWebURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf clipboardHasLink:hasLink changeCount:changeCount];
        });
    }];
}

- (void)clipboardMayHaveChanged:(NSNotification *)notification {
    [self refreshClipboardLink];
}

- (void)clipboardHasLink:(BOOL)hasLink changeCount:(NSInteger)changeCount {
    if (changeCount != _clipboardChangeCount || hasLink == _clipboardHasLink) {
        return;
    }
    _clipboardHasLink = hasLink;
    if (self.viewIfLoaded.window) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeBrowserRootSectionActions]
                      withRowAnimation:UITableViewRowAnimationFade];
    }
}

// The paste row's tap. Listing the clipboard's providers asks nothing. Loading
// one raises the system's Allow Paste prompt, unless the user set Paste from
// Other Apps to Allow.
- (void)pasteClipboardLink {
    [self pasteItemProviders:UIPasteboard.generalPasteboard.itemProviders];
}

// The paste row's items. The first web link opens as the sheet's Open does.
// Other text fails as an address that is no link. A paste while a link
// resolves gives that link up and loads nothing, as a second tap on a
// spinning row does.
- (void)pasteItemProviders:(NSArray<NSItemProvider *> *)itemProviders {
    dispatch_block_t cancel = _cancelLinkResolve;
    if (cancel) {
        cancel();
        return;
    }
    __weak FilesRootViewController *weakSelf = self;
    VibeLoadPastedItems(itemProviders, ^(NSArray<NSDictionary<NSString *, NSString *> *> *items) {
        FilesRootViewController *strongSelf = weakSelf;
        NSURL *link = VibePasteLinkOfItems(items);
        // TRAP: a denied paste still lists its items, with their types. Only
        // the loads fail (PBErrorDomain 13). Nothing was read, so nothing is
        // said.
        BOOL read = NO;
        for (NSDictionary<NSString *, NSString *> *item in items) {
            read = read || item.count > 0;
        }
        if (link) {
            [strongSelf openLinkText:link.absoluteString];
        }
        else if (read && strongSelf.viewIfLoaded.window) {
            NSError *invalid = [NSError errorWithDomain:VibeLinkErrorDomain code:VibeLinkErrorInvalid userInfo:nil];
            [strongSelf.vibeTopmostPresenter vibePresentAlertWithTitle:STR_LINK_ERROR_TITLE
                                                               message:[LinkStore messageForError:invalid brief:NO]];
        }
    });
}

- (void)reloadPasteRow {
    NSUInteger row = [[self rootRowsInSection:VibeBrowserRootSectionActions]
            indexOfObject:@(VibeBrowserRootRowPasteURL)];
    if (self.viewIfLoaded.window && row != NSNotFound) {
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row
                                                                    inSection:VibeBrowserRootSectionActions]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

#pragma mark - Opening

// Every open is one of PlaybackController's roads.
- (void)addURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }
    [_playback addURLs:urls];
    if (_appending) {
        [self dismissSheet];
    }
}

// A replace — a file alone, a file with its folder, a folder, or a pick of
// several — unless this is the add sheet, where the same pick is added.
- (void)openURLs:(NSArray<NSURL *> *)urls inFolder:(BOOL)inFolder {
    if (_appending) {
        [self addURLs:urls];
        return;
    }
    NSURL *row = urls.count == 1 ? urls.firstObject : nil;
    [_playback confirmReplacingPlaylistFrom:self
                                openingURLs:urls
                                   inFolder:inFolder
                                      token:[_playback replaceRequestTokenOpening:row]];
}

// By its presenter, so Open URL's sheet over it closes with it.
- (void)dismissSheet {
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

// A screen of this stack. Open Folder hands its last one the file to
// highlight, and a scope to hold.
- (FolderViewController *)folderForDirectory:(NSURL *)url highlighting:(NSURL *)file holdsScope:(BOOL)holdsScope {
    __weak FilesRootViewController *weakSelf = self;
    FolderViewController *folder = [[FolderViewController alloc] initWithPlayback:_playback
                                                                     directoryURL:url
                                                                        appending:_appending
                                                                    stackArtCache:^AudioTrackMetadataCache *{
        return [weakSelf stackArtCache];
    }
                                                                     highlighting:file
                                                                       holdsScope:holdsScope];
    folder.addedRowsHandler = _addedRowsHandler;
    folder.equalizerSurfaceVisible = _equalizerSurfaceVisible;
    return folder;
}

- (void)pushDirectory:(NSURL *)url {
    [self.navigationController pushViewController:[self folderForDirectory:url highlighting:nil holdsScope:NO]
                                         animated:YES];
}

- (void)showDirectory:(NSURL *)directory highlighting:(NSURL *)file {
    NSMutableArray<NSURL *> *sources = [NSMutableArray array];
    if (DropboxMirror.shared.accountURL) {
        [sources addObject:DropboxMirror.shared.accountURL];
    }
    [sources addObjectsFromArray:LocationStore.shared.searchRoots];
    NSMutableArray<NSString *> *sourcePaths = [NSMutableArray arrayWithCapacity:sources.count];
    for (NSURL *source in sources) {
        [sourcePaths addObject:VibeComparablePath(source.path) ?: @""];
    }
    NSString *standardized = VibeComparablePath(directory.path);
    NSUInteger index = VibeSearchFolderCoveringRootIndex(sourcePaths, standardized);
    NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:self];
    if (index == NSNotFound) {
        // A bookmark's URL carries the grant; a path-derived one answers NO.
        BOOL holdsScope = [directory startAccessingSecurityScopedResource];
        [stack addObject:[self folderForDirectory:directory highlighting:file holdsScope:holdsScope]];
    }
    else {
        NSMutableArray<NSURL *> *steps = [NSMutableArray arrayWithObject:sources[index]];
        NSArray<NSString *> *components = standardized.pathComponents;
        NSUInteger depth = sourcePaths[index].pathComponents.count;
        for (NSUInteger i = depth; i < components.count; i++) {
            [steps addObject:[steps.lastObject URLByAppendingPathComponent:components[i] isDirectory:YES]];
        }
        for (NSURL *step in steps) {
            [stack addObject:[self folderForDirectory:step
                                         highlighting:step == steps.lastObject ? file : nil
                                           holdsScope:NO]];
        }
    }
    [self.navigationController setViewControllers:stack animated:NO];
}

#pragma mark - Table

- (NSArray<NSNumber *> *)rootRowsInSection:(NSInteger)section {
    return VibeBrowserRootRows((VibeBrowserRootSection)section, _dropboxLinked,
                               LocationStore.shared.folderURLs.count, _clipboardHasLink);
}

- (VibeBrowserRootRow)rootRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSNumber *> *rows = [self rootRowsInSection:indexPath.section];
    return (NSUInteger)indexPath.row < rows.count
            ? (VibeBrowserRootRow)rows[(NSUInteger)indexPath.row].integerValue : VibeBrowserRootRowChooseFile;
}

- (NSUInteger)locationIndexAtIndexPath:(NSIndexPath *)indexPath {
    return VibeBrowserRootLocationIndex((VibeBrowserRootSection)indexPath.section, (NSUInteger)indexPath.row,
                                        _dropboxLinked, LocationStore.shared.folderURLs.count);
}

// The granted folder a Locations row shows. Nil for any other row.
- (NSURL *)locationAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger index = [self locationIndexAtIndexPath:indexPath];
    return index == NSNotFound ? nil : LocationStore.shared.folderURLs[index];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)VibeBrowserRootSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self rootRowsInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == VibeBrowserRootSectionLocations) {
        return STR_BROWSER_LOCATIONS;
    }
    return nil;
}

- (UITableViewCell *)cellWithIdentifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    // The Dropbox glyph is a 28pt asset, wider than a symbol's reservation,
    // so every row reserves its width and the labels line up.
    content.imageProperties.reservedLayoutSize = CGSizeMake(28, 28);
    BOOL action = NO;
    BOOL opening = NO;
    VibeBrowserRootRow row = [self rootRowAtIndexPath:indexPath];
    switch (row) {
        case VibeBrowserRootRowDevice:
            content.text = [LocationStore displayNameForFolderURL:LocationStore.containerDocumentsURL];
            content.image = [UIImage systemImageNamed:
                    UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"ipad" : @"iphone"];
            break;
        case VibeBrowserRootRowDropbox:
            content.text = VibeNotLocalized(@"Dropbox");
            content.secondaryText = DropboxMirror.shared.client.accountName;
            content.image = [UIImage imageNamed:@"dropbox-glyph"];
            break;
        case VibeBrowserRootRowRecents:
            content.text = STR_BROWSER_RECENTS;
            content.image = [UIImage systemImageNamed:@"clock"];
            break;
        case VibeBrowserRootRowLocation:
            content.text = [LocationStore displayNameForFolderURL:[self locationAtIndexPath:indexPath]];
            content.image = [UIImage systemImageNamed:@"folder"];
            break;
        case VibeBrowserRootRowChooseFile:
            content.text = STR_BROWSER_CHOOSE_FILE;
            content.image = [UIImage systemImageNamed:@"doc.badge.ellipsis"];
            action = YES;
            break;
        case VibeBrowserRootRowOpenURL:
            content.text = STR_BROWSER_OPEN_URL;
            content.image = [UIImage systemImageNamed:@"link"];
            action = YES;
            break;
        case VibeBrowserRootRowPasteURL:
            content.text = _appending ? STR_BROWSER_ADD_CLIPBOARD_LINK : STR_BROWSER_OPEN_CLIPBOARD_LINK;
            content.image = [UIImage systemImageNamed:@"doc.on.clipboard"];
            action = YES;
            // It spins while its link resolves. Open URL's sheet shows its own.
            opening = _cancelLinkResolve != nil && _linkSheet == nil;
            break;
    }
    UITableViewCell *cell = [self cellWithIdentifier:action ? kActionCellIdentifier : kSourceCellIdentifier];
    if (action) {
        // TRAP: the dynamic tint, never self.view.tintColor's value. That
        // value is gray while a sheet or alert dims the tint, and a row made
        // then kept it after the dimming ended.
        content.textProperties.color = UIColor.tintColor;
        content.imageProperties.tintColor = UIColor.tintColor;
    }
    else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    [cell vibeApplyRowContent:content opening:opening];
    return cell;
}

#pragma mark - Selection

// A swipe's Delete sets isEditing.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    VibeBrowserRootRow row = [self rootRowAtIndexPath:indexPath];
    switch (row) {
        case VibeBrowserRootRowDevice:
            [self pushDirectory:LocationStore.containerDocumentsURL];
            return;
        case VibeBrowserRootRowDropbox:
            if (DropboxMirror.shared.accountURL) {
                [self pushDirectory:DropboxMirror.shared.accountURL];
            }
            return;
        case VibeBrowserRootRowRecents:
            [self.navigationController pushViewController:[[RecentsViewController alloc] initWithPlayback:_playback
                                                                                                appending:_appending]
                                                 animated:YES];
            return;
        case VibeBrowserRootRowLocation:
            [self pushDirectory:[self locationAtIndexPath:indexPath]];
            return;
        case VibeBrowserRootRowChooseFile:
            [self presentPickerForLocation:NO];
            return;
        case VibeBrowserRootRowOpenURL:
            // A newer link supersedes the pasted one still resolving.
            if (_cancelLinkResolve) {
                _cancelLinkResolve();
            }
            [self presentLinkSheet];
            return;
        case VibeBrowserRootRowPasteURL:
            [self pasteClipboardLink];
            return;
    }
}

// A sign-in that lands goes straight into the account: the plus's Connect to
// Dropbox was tapped to get there.
- (void)connectDropbox {
    __weak FilesRootViewController *weakSelf = self;
    [DropboxMirror.shared.client signInWithPresentationAnchor:self.view.window completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FilesRootViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (error) {
                LogWarn(@"Dropbox: sign-in failed: %@", error.localizedDescription);
                [strongSelf vibePresentAlertWithTitle:VibeNotLocalized(@"Dropbox")
                                              message:STR_SETTINGS_DROPBOX_CONNECT_FAILED];
            }
            else if (DropboxMirror.shared.accountURL
                    && strongSelf.navigationController.topViewController == strongSelf) {
                [strongSelf pushDirectory:DropboxMirror.shared.accountURL];
            }
        });
    }];
}

#pragma mark - Row actions

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self locationIndexAtIndexPath:indexPath] != NSNotFound;
}

// The system draws and localizes Delete, which forgets a location.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSUInteger index = [self locationIndexAtIndexPath:indexPath];
    if (style == UITableViewCellEditingStyleDelete && index != NSNotFound) {
        [LocationStore.shared removeFolderAtIndex:index];
    }
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    if (tableView.isEditing) {
        return nil;
    }
    // The swipe's Delete, where a long press finds it too.
    NSURL *location = [self locationAtIndexPath:indexPath];
    if (!location) {
        return nil;
    }
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *remove = VibeMenuAction(STR_BROWSER_REMOVE_LOCATION, @"minus.circle", ^{
            // By URL: the list can move while the menu is up.
            NSUInteger index = [LocationStore.shared.folderURLs indexOfObject:location];
            if (index != NSNotFound) {
                [LocationStore.shared removeFolderAtIndex:index];
            }
        });
        remove.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithChildren:@[remove]];
    }];
}

#pragma mark - The system pickers

// A location: one folder, granted for good (LocationStore). Anything else:
// files and folders from anywhere, for one open.
- (void)presentPickerForLocation:(BOOL)location {
    NSArray<UTType *> *types = location
            ? @[UTTypeFolder]
            : [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    // asCopy:NO: the grant must be to the real items.
    UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.allowsMultipleSelection = !location;
    picker.delegate = self;
    _pickingLocation = location;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!_pickingLocation) {
        // One picked file expands to its folder.
        [self openURLs:urls inFolder:YES];
        return;
    }
    NSURL *url = urls.firstObject;
    if (!url) {
        return;
    }
    if ([LocationStore.shared addFolderURL:url]) {
        // Opened, not played: adding a folder leaves playback alone.
        [self pushDirectory:url];
    }
    else {
        // Silence would read as a failed pick.
        [self vibePresentAlertWithTitle:STR_BROWSER_LOCATIONS message:STR_SETTINGS_SEARCH_FOLDERS_COVERED];
    }
}

#if DEBUG
- (NSDictionary *)debugLinkState {
    NSDictionary *sheet = _linkSheet ? @{
        @"shown": @YES,
        @"text": _linkSheet.debugField.text ?: @"",
        @"resolving": @((BOOL)(_cancelLinkResolve != nil)),
        @"openEnabled": @(_linkSheet.debugOpenEnabled),
    } : @{@"shown": @NO};
    return @{
        @"pasteRowShown": @([[self rootRowsInSection:VibeBrowserRootSectionActions]
                containsObject:@(VibeBrowserRootRowPasteURL)]),
        @"pasteRowResolving": @((BOOL)(_cancelLinkResolve != nil && _linkSheet == nil)),
        @"linkSheet": sheet,
    };
}

- (OpenURLSheetController *)debugLinkSheet {
    return _linkSheet;
}
#endif

@end
