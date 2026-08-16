//
//  SearchViewController.m
//  Vibe (iOS)
//

#import "SearchViewController.h"

#import "AudioTrack.h"
#import "PlaybackController.h"
#import "Playlist.h"
#import "VibeStrings.h"

@interface SearchViewController () <UISearchResultsUpdating, PlaybackObserver>
@end

@implementation SearchViewController {
    PlaybackController *_playback;
    Playlist           *_playlist;
    UISearchController *_searchController;
    // Indexes into the playlist, filtered by the live query. All rows when
    // the query is empty, so the screen doubles as a browse list.
    NSArray<NSNumber *> *_matches;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _playlist = playback.playlist;
        _matches = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_LABEL_SEARCH;
    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = STR_LABEL_SEARCH;
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    // Deliberately not focused on appear: this is a tab root, and seizing the
    // keyboard on every switch to it is not what a tab does.
    [_playback addObserver:self];
    [self filterWithQuery:@""];
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
    content.image = track.cachedThumbnail ?: [UIImage imageNamed:@"record-bg"];
    content.imageProperties.maximumSize = CGSizeMake(40, 40);
    content.imageProperties.cornerRadius = 4;
    content.text = track.displayTitle;
    content.secondaryText = track.displayArtist;
    content.textProperties.numberOfLines = 1;
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_playback selectTrackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
}

#pragma mark - PlaybackObserver

// Re-filter rather than reload: the matches are indexes into a playlist that
// has just been replaced, so every one of them is stale.
- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    [self filterWithQuery:_searchController.searchBar.text ?: @""];
}

- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [self filterWithQuery:_searchController.searchBar.text ?: @""];
}

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    // Tags can change what a row says and what the query matches.
    [self filterWithQuery:_searchController.searchBar.text ?: @""];
}

@end
