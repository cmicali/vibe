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

#pragma mark - Opening

// The row stays selected while the bookmark resolves — on a file provider that
// is IPC and can take a beat, and the highlight is the only thing saying the
// tap landed.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    FavoriteFolder *favorite = _favorites[(NSUInteger)indexPath.row];
    __weak FavoritesViewController *weakSelf = self;
    [FavoritesStore.shared resolveFavorite:favorite completion:^(NSURL *folderURL) {
        [weakSelf finishOpeningFavorite:favorite folderURL:folderURL];
    }];
}

- (void)finishOpeningFavorite:(FavoriteFolder *)favorite folderURL:(NSURL *)folderURL {
    for (NSIndexPath *path in self.tableView.indexPathsForSelectedRows) {
        [self.tableView deselectRowAtIndexPath:path animated:YES];
    }
    if (!folderURL) {
        [self showUnavailableAlertForFavorite:favorite];
        return;
    }
    // openInPlace:YES — the real folder, so this lands in FolderSession's
    // adoptURL: exactly where the document picker's own delegate does.
    [_playback openExternalURL:folderURL openInPlace:YES];
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
