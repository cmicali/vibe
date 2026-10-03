//
//  FavoritesViewController.m
//  Vibe (iOS)
//

#import "FavoritesViewController.h"

#import "AppSettings.h"
#import "BrowserViewController.h"
#import "DropboxMirror.h"
#import "FavoritesStore.h"
#import "PlaybackController.h"
#import "NSURLUtil.h"
#import "VibeStrings.h"

static NSString *const kFavoriteCellIdentifier = @"favorite";

@implementation FavoritesViewController {
    PlaybackController *_playback;
    NSArray<FavoriteFolder *> *_favorites;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _favorites = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = STR_TAB_FAVORITES;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(favoritesDidChange)
                                               name:VibeFavoritesDidChangeNotification
                                             object:nil];
    [self reloadFavorites];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// One delivery drives the table: the store posts for other screens' edits as
// well as this one's, and a local animation beside it would mutate the table
// twice.
- (void)favoritesDidChange {
    [self reloadFavorites];
    [self.tableView reloadData];
}

- (void)reloadFavorites {
    _favorites = FavoritesStore.shared.favorites;
    [self refreshEmptyState];
}

- (void)refreshEmptyState {
    if (_favorites.count > 0) {
        self.contentUnavailableConfiguration = nil;
        return;
    }
    // No button: favorites are made elsewhere, by the Playlist tab's star or
    // the Files tab's menu.
    UIContentUnavailableConfiguration *empty =
            [UIContentUnavailableConfiguration emptyConfiguration];
    empty.image = [UIImage systemImageNamed:@"star"];
    empty.text = STR_LABEL_FAVORITES_EMPTY_TITLE;
    empty.secondaryText = STR_LABEL_FAVORITES_EMPTY_MESSAGE;
    self.contentUnavailableConfiguration = empty;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_favorites.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell =
            [tableView dequeueReusableCellWithIdentifier:kFavoriteCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kFavoriteCellIdentifier];
    }
    FavoriteFolder *favorite = _favorites[(NSUInteger)indexPath.row];
    UIListContentConfiguration *content =
            [UIListContentConfiguration subtitleCellConfiguration];
    content.text = favorite.name;
    // Nil, not empty, so the row draws one line.
    content.secondaryText = favorite.location.length > 0 ? favorite.location : nil;
    content.image = [UIImage systemImageNamed:@"folder"];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    return cell;
}

// The system draws and localizes the Delete swipe.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView
        commitEditingStyle:(UITableViewCellEditingStyle)style
         forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style == UITableViewCellEditingStyleDelete) {
        [FavoritesStore.shared removeFavoriteAtIndex:(NSUInteger)indexPath.row];
    }
}

// A context menu is never the only road to an action. Leading only: a trailing
// configuration would take over the system Delete.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    FavoriteFolder *favorite = _favorites[(NSUInteger)indexPath.row];
    __weak FavoritesViewController *weakSelf = self;
    UIContextualAction *add = [UIContextualAction
            contextualActionWithStyle:UIContextualActionStyleNormal
                                title:STR_MENU_CONTEXT_ADD_TO_PLAYLIST
                              handler:^(UIContextualAction *action, UIView *source,
                                        void (^completion)(BOOL)) {
        [weakSelf openFavorite:favorite appending:YES];
        completion(YES);
    }];
    add.image = [UIImage systemImageNamed:@"text.badge.plus"];
    add.backgroundColor = self.view.tintColor;
    UISwipeActionsConfiguration *config =
            [UISwipeActionsConfiguration configurationWithActions:@[add]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    FavoriteFolder *favorite = _favorites[(NSUInteger)indexPath.row];
    __weak FavoritesViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *play = VibeMenuAction(STR_MENU_CONTEXT_PLAY, @"play.fill", ^{
            [weakSelf openFavorite:favorite appending:NO];
        });
        UIAction *add = VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf openFavorite:favorite appending:YES];
        });
        UIAction *remove = VibeMenuAction(STR_MENU_CONTEXT_REMOVE_FAVORITE, @"star.slash", ^{
            // By path, not row: the list can move while the menu is up.
            [FavoritesStore.shared removeFolderURL:[NSURL fileURLWithPath:favorite.path]];
        });
        remove.attributes = UIMenuElementAttributesDestructive;
        UIMenu *destructive = [UIMenu menuWithTitle:@""
                                              image:nil
                                         identifier:nil
                                            options:UIMenuOptionsDisplayInline
                                           children:@[remove]];
        return [UIMenu menuWithTitle:@"" children:@[play, add, destructive]];
    }];
}

#pragma mark - Opening

// The row stays selected while the bookmark resolves, the only sign the tap
// landed.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self openFavorite:_favorites[(NSUInteger)indexPath.row] appending:NO];
}

// The one opening path for the tap and every row action.
- (void)openFavorite:(FavoriteFolder *)favorite appending:(BOOL)appending {
    // The token is taken HERE, before the resolve: an Add outliving a replace
    // would append to the new playlist, and a replace landing after a newer
    // open would take its place (the session and the replace funnel drop them).
    uint64_t token = [_playback addRequestToken];
    __weak FavoritesViewController *weakSelf = self;
    [FavoritesStore.shared resolveFavorite:favorite completion:^(NSURL *folderURL) {
        [weakSelf finishOpeningFavorite:favorite folderURL:folderURL
                              appending:appending token:token];
    }];
}

- (void)finishOpeningFavorite:(FavoriteFolder *)favorite
                    folderURL:(NSURL *)folderURL
                    appending:(BOOL)appending
                        token:(uint64_t)token {
    for (NSIndexPath *path in self.tableView.indexPathsForSelectedRows) {
        [self.tableView deselectRowAtIndexPath:path animated:YES];
    }
    if (!folderURL) {
        [self showUnavailableAlertForFavorite:favorite];
        return;
    }
    if (appending) {
        [_playback addURLs:@[folderURL] token:token];
        return;
    }
    // A Dropbox folder of folders has nothing to play: it opens in the Files
    // tab, where its subfolders are, not as an empty playlist.
    NSString *dropboxPath = [DropboxMirror.shared dropboxPathForURL:folderURL];
    void (^showDirectory)(NSURL *) = _showDirectoryHandler;
    if (!dropboxPath || !showDirectory) {
        [self playFolderURL:folderURL token:token];
        return;
    }
    __weak FavoritesViewController *weakSelf = self;
    // Listed first: the mirror holds only what something has listed, so a
    // folder never browsed is empty on disk whatever Dropbox holds. A failed
    // listing falls back on what the disk has; the open that follows reads
    // the listed folder as it is.
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    [DropboxMirror.shared refreshDropboxFolder:dropboxPath completion:^(NSURL *listedURL, NSError *error) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSURL *> *audio = @[];
            [NSURLUtil listDirectory:folderURL sortedBy:sort folders:NULL audio:&audio];
            dispatch_async(dispatch_get_main_queue(), ^{
                FavoritesViewController *strongSelf = weakSelf;
                if (audio.count > 0) {
                    [strongSelf playFolderURL:folderURL token:token];
                }
                // Not a replace, so the funnel does not judge it: the same
                // rule, another open asked for meanwhile wins.
                else if (strongSelf && [strongSelf->_playback addRequestToken] == token) {
                    showDirectory(folderURL);
                }
            });
        });
    }];
}

- (void)playFolderURL:(NSURL *)folderURL token:(uint64_t)token {
    [BrowserViewController confirmReplacingPlaylistOf:_playback from:self openingURLs:@[folderURL] inFolder:NO
                                                token:token];
}

// The row stays: a signed-out provider or an unmounted volume is temporary.
- (void)showUnavailableAlertForFavorite:(FavoriteFolder *)favorite {
    VibePresentAlert(self, favorite.name, STR_ERROR_FAVORITE_UNAVAILABLE);
}

@end
