//
//  SearchViewController.m
//  Vibe (iOS)
//

#import "SearchViewController.h"
#import "AudioTrack.h"
#import "Playlist.h"
#import "VibeStrings.h"

@interface SearchViewController () <UISearchResultsUpdating, UISearchControllerDelegate>
@end

@implementation SearchViewController {
    __weak Playlist *_playlist;
    UISearchController *_searchController;
    // Indexes into the playlist, filtered by the live query. All rows when
    // the query is empty, so the screen doubles as a browse list.
    NSArray<NSNumber *> *_matches;
}

- (instancetype)initWithPlaylist:(Playlist *)playlist {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playlist = playlist;
        _matches = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_LABEL_SEARCH;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                      target:self
                                                      action:@selector(closeTapped)];
    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.delegate = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = STR_LABEL_SEARCH;
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    [self filterWithQuery:@""];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Mail-style: land with the field focused and the keyboard up. Activation
    // presents the field; the focus itself waits for didPresentSearchController:
    // — calling becomeFirstResponder here races the activation and loses on
    // device (the field is not installed yet, so the keyboard never comes up).
    _searchController.active = YES;
}

- (void)didPresentSearchController:(UISearchController *)searchController {
    // Deferred a runloop turn: the presentation callback can still precede the
    // field becoming attachable to the responder chain.
    dispatch_async(dispatch_get_main_queue(), ^{
        [searchController.searchBar becomeFirstResponder];
    });
}

// The sheet, not the search layer: while the search controller is active, a
// plain [self dismiss…] tears down the SEARCH presentation — deactivating the
// field — and leaves the sheet standing. The presenter dismisses the whole
// stack, active search included.
- (void)dismissSheetWithCompletion:(void (^)(void))completion {
    UIViewController *presenter = self.navigationController.presentingViewController
            ?: self.presentingViewController;
    [presenter dismissViewControllerAnimated:YES completion:completion];
}

- (void)closeTapped {
    [self dismissSheetWithCompletion:nil];
}

- (void)reloadAll {
    if (self.isViewLoaded) {
        [self filterWithQuery:_searchController.searchBar.text ?: @""];
    }
}

#pragma mark - Filtering

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self filterWithQuery:searchController.searchBar.text ?: @""];
}

- (void)filterWithQuery:(NSString *)query {
    NSArray<AudioTrack *> *tracks = _playlist.tracks;
    NSMutableArray<NSNumber *> *matches = [NSMutableArray arrayWithCapacity:tracks.count];
    for (NSUInteger i = 0; i < tracks.count; i++) {
        if (query.length == 0 || [self track:tracks[i] matchesQuery:query]) {
            [matches addObject:@(i)];
        }
    }
    _matches = matches;
    [self.tableView reloadData];
}

- (BOOL)track:(AudioTrack *)track matchesQuery:(NSString *)query {
    if ([track.title localizedCaseInsensitiveContainsString:query]) {
        return YES;
    }
    NSString *artist = track.artist;
    if (artist.length && [artist localizedCaseInsensitiveContainsString:query]) {
        return YES;
    }
    return [track.url.lastPathComponent localizedCaseInsensitiveContainsString:query];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_matches.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const identifier = @"result";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    AudioTrack *track = [_playlist trackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = track.displayTitle;
    content.secondaryText = track.displayArtist;
    content.textProperties.numberOfLines = 1;
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUInteger index = _matches[(NSUInteger)indexPath.row].unsignedIntegerValue;
    void (^selectTrack)(NSUInteger) = self.onSelectTrack;
    [self dismissSheetWithCompletion:^{
        if (selectTrack) {
            selectTrack(index);
        }
    }];
}

@end
