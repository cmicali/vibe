//
//  RecentsViewController.m
//  Vibe (iOS)
//

#import "RecentsViewController.h"

#import "BrowserViewController.h"
#import "FileRow.h"
#import "LinkStore.h"
#import "FilePaths.h"
#import "PlaybackController+ReplacePrompt.h"
#import "PlaylistFile.h"
#import "RecentsStore.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

static NSString *const kItemCellIdentifier = @"item";

@implementation RecentsViewController {
    PlaybackController *_playback;
    BOOL _appending;
    // Snapshotted per appearance, so an open landing under the finger does
    // not move the rows.
    NSArray<NSDictionary *> *_items;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _appending = appending;
        _items = @[];
        [playback addObserver:self];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = STR_BROWSER_RECENTS;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.prompt = _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : nil;
    // The add sheet adds; it is no place to manage the list, and its bar
    // carries the way out instead.
    if (_appending) {
        self.navigationItem.rightBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                              target:self
                                                              action:@selector(dismissSheet)];
        return;
    }
    // A menu, so one stray tap cannot empty the list.
    __weak RecentsViewController *weakSelf = self;
    UIAction *clear = [UIAction actionWithTitle:STR_BROWSER_RECENTS_CLEAR_CONFIRM
                                          image:[UIImage systemImageNamed:@"trash"]
                                     identifier:nil
                                        handler:^(UIAction *action) {
        [weakSelf clearRecents];
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:STR_BUTTON_CLEAR
                                              menu:[UIMenu menuWithChildren:@[clear]]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadItems];
}

- (void)dismissSheet {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)clearRecents {
    [RecentsStore.shared clearRecentItems];
    [self reloadItems];
}

- (void)reloadItems {
    _items = RecentsStore.shared.recentItems;
    [self.tableView reloadData];
    // Absent, not disabled, with nothing to clear.
    self.navigationItem.rightBarButtonItem.hidden = !_appending && _items.count == 0;
    if (_items.count > 0) {
        self.contentUnavailableConfiguration = nil;
        return;
    }
    UIContentUnavailableConfiguration *empty = [UIContentUnavailableConfiguration emptyConfiguration];
    empty.image = [UIImage systemImageNamed:@"clock"];
    empty.text = STR_BROWSER_RECENTS_EMPTY;
    self.contentUnavailableConfiguration = empty;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kItemCellIdentifier]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kItemCellIdentifier];
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    NSString *path = item[@"path"];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = path.lastPathComponent;
    // The folder's name as recorded with the item: the path can outlive the
    // container it names, and then says nothing a user would recognize.
    content.secondaryText = item[@"location"];
    [content vibeApplyFileNameStyle];
    [content vibeApplyFileIconForName:path folder:[item[@"folder"] boolValue] art:nil];
    [cell vibeApplyRowContent:content opening:[VibeComparablePath(path) isEqualToString:_playback.openingPath]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    // A folder opens in the browser, as a folder row does there; its long
    // press plays it.
    if ([item[@"folder"] boolValue]) {
        [self showFolderOfItem:item];
        return;
    }
    // A second tap on the row still opening gives it up.
    if ([VibeComparablePath(item[@"path"]) isEqualToString:_playback.openingPath]) {
        [_playback cancelOpening];
        return;
    }
    [self openItem:item appending:_appending inFolder:NO];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    NSDictionary *item = _items[(NSUInteger)indexPath.row];
    BOOL folder = [item[@"folder"] boolValue];
    // A link's folder is the store's, named by a hash and holding the one
    // file: no Play in Folder, no Open Folder.
    BOOL folderActions = ![LinkStore.shared containsURL:[NSURL fileURLWithPath:item[@"path"] isDirectory:folder]];
    BOOL appendingSheet = _appending;
    __weak RecentsViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        if (!appendingSheet) {
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY, @"play.fill", ^{
                [weakSelf openItem:item appending:NO inFolder:NO];
            })];
            if (!folder && folderActions
                    && ![PlaylistFile isM3UExtension:[item[@"path"] pathExtension].lowercaseString]) {
                [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY_IN_FOLDER, @"play.square.stack", ^{
                    [weakSelf openItem:item appending:NO inFolder:YES];
                })];
            }
        }
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf openItem:item appending:YES inFolder:NO];
        })];
        if (folderActions) {
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_OPEN_FOLDER, @"folder", ^{
                [weakSelf showFolderOfItem:item];
            })];
        }
        return [UIMenu menuWithTitle:@"" children:items];
    }];
}

// The resolve is provider IPC, so the token is taken first: an open the user
// makes while it runs supersedes an Add (FolderSession) and a replace alike.
- (void)openItem:(NSDictionary *)item appending:(BOOL)appending inFolder:(BOOL)inFolder {
    PlaybackController *playback = _playback;
    uint64_t token = appending ? [playback addRequestToken]
                               : [playback replaceRequestTokenOpening:[NSURL fileURLWithPath:item[@"path"]
                                                                                isDirectory:[item[@"folder"] boolValue]]];
    NSString *name = [item[@"path"] lastPathComponent];
    __weak RecentsViewController *weakSelf = self;
    [RecentsStore.shared resolveRecentItem:item completion:^(NSURL *url) {
        if (!url) {
            if (!appending) {
                [playback endOpeningForReplaceRequest:token];
            }
            [weakSelf showUnavailableAlertForName:name];
        }
        else if (appending) {
            [playback addURLs:@[url] token:token];
        }
        else {
            RecentsViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [playback confirmReplacingPlaylistFrom:strongSelf openingURLs:@[url] inFolder:inFolder token:token];
        }
    }];
    if (_appending) {
        [self dismissSheet];
    }
}

// The browser at the bottom of this stack shows the folder: the item
// itself, or the one holding it.
- (void)showFolderOfItem:(NSDictionary *)item {
    NSString *name = [item[@"path"] lastPathComponent];
    BOOL folder = [item[@"folder"] boolValue];
    __weak RecentsViewController *weakSelf = self;
    [RecentsStore.shared resolveRecentItem:item completion:^(NSURL *url) {
        RecentsViewController *strongSelf = weakSelf;
        BrowserViewController *root = (BrowserViewController *)strongSelf.navigationController.viewControllers.firstObject;
        if (!url) {
            [strongSelf showUnavailableAlertForName:name];
        }
        else if ([root isKindOfClass:BrowserViewController.class]) {
            [root showDirectory:folder ? url : url.URLByDeletingLastPathComponent
                   highlighting:folder ? nil : url];
        }
    }];
}

- (void)showUnavailableAlertForName:(NSString *)name {
    // In the add sheet the open already dismissed it.
    UIViewController *presenter = self.view.window ? self : self.navigationController.presentingViewController;
    if (presenter) {
        [presenter vibePresentAlertWithTitle:name message:STR_ERROR_RECENT_UNAVAILABLE];
    }
}

#pragma mark - PlaybackObserver

- (void)playbackDidChangeOpening:(PlaybackController *)playback {
    if (self.viewIfLoaded.window) {
        [self.tableView reloadRowsAtIndexPaths:self.tableView.indexPathsForVisibleRows
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

@end
