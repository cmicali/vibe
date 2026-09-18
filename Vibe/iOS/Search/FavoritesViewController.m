//
//  FavoritesViewController.m
//  Vibe (iOS)
//

#import "FavoritesViewController.h"

#import "FavoritesStore.h"
#import "PlaybackController.h"
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

// One delivery drives the whole table, rather than a local insert/delete beside
// the notification: the store posts for the star on the Playlist tab as well as
// for this screen's own swipe, and animating one while reloading for the other
// would mutate the table twice.
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
    // The Playlist tab's empty state without its Open button: a favorite is
    // made by starring an open folder, so there is nothing to offer here that
    // would create one.
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
    // Nil rather than empty, so a folder with no parent worth naming draws one
    // line instead of a line and a gap.
    content.secondaryText = favorite.location.length > 0 ? favorite.location : nil;
    content.image = [UIImage systemImageNamed:@"folder"];
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    cell.contentConfiguration = content;
    return cell;
}

// Swipe to delete, the same shape Settings' search-folder rows use. The system
// draws and localizes the action, so there is no string here.
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

// Apple's guidance is that a context menu is never the only road to an action,
// so Add gets this swipe as well. Leading only: the trailing side stays the
// legacy Delete above, which UIKit draws and localizes itself.
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
        UIAction *play = [UIAction actionWithTitle:STR_MENU_CONTEXT_PLAY
                                             image:[UIImage systemImageNamed:@"play.fill"]
                                        identifier:nil
                                           handler:^(UIAction *action) {
            [weakSelf openFavorite:favorite appending:NO];
        }];
        UIAction *add = [UIAction actionWithTitle:STR_MENU_CONTEXT_ADD_TO_PLAYLIST
                                            image:[UIImage systemImageNamed:@"text.badge.plus"]
                                       identifier:nil
                                          handler:^(UIAction *action) {
            [weakSelf openFavorite:favorite appending:YES];
        }];
        UIAction *remove = [UIAction actionWithTitle:STR_MENU_CONTEXT_REMOVE_FAVORITE
                                               image:[UIImage systemImageNamed:@"star.slash"]
                                          identifier:nil
                                             handler:^(UIAction *action) {
            // By the favorite's own path, not the row index: the list can move
            // while the menu is up.
            [FavoritesStore.shared removeFolderURL:[NSURL fileURLWithPath:favorite.path]];
        }];
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

// The row stays selected while the bookmark resolves — on a file provider that
// is IPC and can take a beat, and the highlight is the only thing saying the
// tap landed.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self openFavorite:_favorites[(NSUInteger)indexPath.row] appending:NO];
}

// The one opening path: the tap and every row action take it, so the resolve
// and the unreachable-folder alert are the same for all of them.
- (void)openFavorite:(FavoriteFolder *)favorite appending:(BOOL)appending {
    __weak FavoritesViewController *weakSelf = self;
    [FavoritesStore.shared resolveFavorite:favorite completion:^(NSURL *folderURL) {
        [weakSelf finishOpeningFavorite:favorite folderURL:folderURL appending:appending];
    }];
}

- (void)finishOpeningFavorite:(FavoriteFolder *)favorite
                    folderURL:(NSURL *)folderURL
                    appending:(BOOL)appending {
    for (NSIndexPath *path in self.tableView.indexPathsForSelectedRows) {
        [self.tableView deselectRowAtIndexPath:path animated:YES];
    }
    if (!folderURL) {
        [self showUnavailableAlertForFavorite:favorite];
        return;
    }
    // openInPlace:YES — the real folder, so this lands in FolderSession's open
    // prologue exactly where the document picker's own delegate does.
    if (appending) {
        [_playback addURLs:@[folderURL]];
    }
    else {
        [_playback openURLs:@[folderURL] openInPlace:YES];
    }
}

// The row is deliberately left in place. A provider signed out or a volume not
// mounted is temporary, and dropping a favorite the user just asked for is a
// worse answer than saying it is unreachable right now.
- (void)showUnavailableAlertForFavorite:(FavoriteFolder *)favorite {
    UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:favorite.name
                                                message:STR_ERROR_FAVORITE_UNAVAILABLE
                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_OK
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
