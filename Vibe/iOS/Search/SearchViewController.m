//
//  SearchViewController.m
//  Vibe (iOS)
//

#import "SearchViewController.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "FileSearchIndex.h"
#import "FileSearchRules.h"
#import "PlaybackController.h"
#import "Playlist.h"
#import "FavoritesStore.h"
#import "SearchFolderStore.h"
#import "VibeStrings.h"

// A folder scan's metadata stream costs a handful of rebuilds, not one per
// track, and still reads as live.
static const NSTimeInterval kRefilterCoalesceInterval = 0.25;

// Uncapped, a one-letter query reloads thousands of rows per keystroke. The
// playlist section is uncapped: it doubles as the browse list.
static const NSUInteger kMaxFileResults = 200;

typedef NS_ENUM(NSInteger, VibeSearchSection) {
    VibeSearchSectionPlaylist = 0,
    VibeSearchSectionFiles,
    VibeSearchSectionCount
};

@interface SearchViewController () <UISearchResultsUpdating, PlaybackObserver, FileSearchIndexDelegate>
@end

@implementation SearchViewController {
    PlaybackController *_playback;
    Playlist           *_playlist;
    UISearchController *_searchController;
    // Indexes into the playlist; all of them for an empty query.
    NSArray<NSNumber *> *_matches;
    // The playlist's paths, so a listed track is not offered twice; rebuilt
    // per playlist change, not per keystroke.
    FileSearchIndex     *_fileIndex;
    NSArray<FileSearchHit *> *_fileHits;
    NSSet<NSString *>   *_playlistPaths;
    BOOL                _matchesStale;
    BOOL                _refilterScheduled;
    BOOL                _viewPresentationVisible;
    BOOL                _materialSurfaceVisible;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _playback = playback;
        _playlist = playback.playlist;
        _matches = @[];
        _fileHits = @[];
        _playlistPaths = [NSSet set];
        _fileIndex = [[FileSearchIndex alloc] init];
        _fileIndex.delegate = self;
        _materialSurfaceVisible = YES;
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
    // Nothing else dismisses the keyboard, which covers the list. Not
    // `interactive`: that tracks a field the scroll view contains, and this
    // one is in the tab bar.
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // Not focused on appear: this is a tab root.
    [_playback addObserver:self];
    // Launch restores can land while this screen is up.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(searchFoldersDidChange:)
                                               name:VibeSearchFoldersDidChangeNotification
                                             object:nil];
    // Starred roots resolve off main and arrive after this screen is up.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(searchFoldersDidChange:)
                                               name:VibeFavoritesDidChangeNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
    [self rebuildPlaylistPaths];
    [self filterWithQuery:@""];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    if (![self isMateriallyVisible]) {
        return;
    }
    NSMutableArray<NSIndexPath *> *matchingPaths = [NSMutableArray array];
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.section != VibeSearchSectionPlaylist ||
            (NSUInteger)path.row >= _matches.count) {
            continue;
        }
        NSUInteger trackIndex = _matches[(NSUInteger)path.row].unsignedIntegerValue;
        if (trackIndex < _playlist.count &&
            [_playlist trackAtIndex:trackIndex].metadata == notification.object) {
            [matchingPaths addObject:path];
        }
    }
    if (matchingPaths.count > 0) {
        [self.tableView reloadRowsAtIndexPaths:matchingPaths
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)searchFoldersDidChange:(NSNotification *)notification {
    [self applySearchRoots];
    _fileHits = @[];
    if ([self isMateriallyVisible]) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeSearchSectionFiles]
                     withRowAnimation:UITableViewRowAnimationNone];
        [self requestFileHitsForQuery:[self currentQuery]];
    }
}

// Cheap on every appearance: the same roots are a no-op. Builds only from a
// screen that is up.
- (BOOL)isBuildingFileIndex {
    return _fileIndex.isBuilding;
}

// The field is the query's home: requestFileHitsForQuery: drops a delivery
// whose query no longer matches it.
- (void)setQueryText:(NSString *)query {
    _searchController.searchBar.text = query;
    [self filterWithQuery:query];
}

- (void)applySearchRoots {
    // A saved grant is worth opening only once something will walk it.
    [FavoritesStore.shared prepareSearchScope];
    [_fileIndex setRoots:_playback.searchRoots];
    if ([self isMateriallyVisible]) {
        [_fileIndex beginBuildIfNeeded];
    }
}

// Hidden, the matches go stale and deliveries schedule nothing. The file walk
// starts here, not on the first keystroke, so the first query answers off an
// index already filling.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _viewPresentationVisible = YES;
    [self applySearchRoots];
    // Unconditional: reloads are dropped while hidden.
    [self filterWithQuery:[self currentQuery]];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _viewPresentationVisible = NO;
    [_fileIndex cancelPendingHitRequests];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)isMateriallyVisible {
    return _viewPresentationVisible && _materialSurfaceVisible;
}

- (void)setMaterialSurfaceVisible:(BOOL)materialSurfaceVisible {
    if (_materialSurfaceVisible == materialSurfaceVisible) {
        return;
    }
    _materialSurfaceVisible = materialSurfaceVisible;
    if (![self isMateriallyVisible]) {
        [_fileIndex cancelPendingHitRequests];
        return;
    }
    [_fileIndex beginBuildIfNeeded];
    [self filterWithQuery:[self currentQuery]];
}

- (BOOL)isMaterialSurfaceVisible {
    return _materialSurfaceVisible;
}

#pragma mark - Filtering

- (NSString *)currentQuery {
    return _searchController.searchBar.text ?: @"";
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self filterWithQuery:[self currentQuery]];
}

// The playlist half lands on this turn; the files half matches off main, later
// batches superseding it. Neither waits on the other or on a provider.
- (void)filterWithQuery:(NSString *)query {
    _matchesStale = NO;
    NSArray<AudioTrack *> *tracks = _playlist.tracks;
    NSMutableArray<NSNumber *> *matches = [NSMutableArray arrayWithCapacity:tracks.count];
    for (NSUInteger i = 0; i < tracks.count; i++) {
        if ([self track:tracks[i] matchesQuery:query]) {
            [matches addObject:@(i)];
        }
    }
    _matches = matches;
    _fileHits = @[];
    [self.tableView reloadData];
    [self requestFileHitsForQuery:query];
}

- (void)requestFileHitsForQuery:(NSString *)query {
    if (![self isMateriallyVisible] || query.length == 0) {
        [_fileIndex cancelPendingHitRequests];
        return;
    }
    NSString *querySnapshot = [query copy];
    NSSet<NSString *> *playlistPathsSnapshot = _playlistPaths;
    __weak SearchViewController *weakSelf = self;
    [_fileIndex requestHitsMatchingQuery:querySnapshot
                               excluding:playlistPathsSnapshot
                                   limit:kMaxFileResults
                              completion:^(NSArray<FileSearchHit *> *hits) {
        SearchViewController *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf isMateriallyVisible]
                || ![querySnapshot isEqualToString:[strongSelf currentQuery]]
                || strongSelf->_playlistPaths != playlistPathsSnapshot) {
            return;
        }
        strongSelf->_fileHits = hits;
        [strongSelf.tableView reloadSections:
                [NSIndexSet indexSetWithIndex:VibeSearchSectionFiles]
                            withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (BOOL)track:(AudioTrack *)track matchesQuery:(NSString *)query {
    return VibeSearchTrackMatchesQuery(track.title, track.artist,
                                       track.url.lastPathComponent, query);
}

- (void)rebuildPlaylistPaths {
    NSArray<AudioTrack *> *tracks = _playlist.tracks;
    NSMutableSet<NSString *> *paths = [NSMutableSet setWithCapacity:tracks.count];
    for (AudioTrack *track in tracks) {
        NSString *path = track.url.path;
        if (path) {
            [paths addObject:path];
        }
    }
    _playlistPaths = paths;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeSearchSectionCount;
}

// An empty section draws no header, except while the walk runs.
- (BOOL)showsFilesSection {
    return [self currentQuery].length > 0 && (_fileHits.count > 0 || _fileIndex.isBuilding);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == VibeSearchSectionPlaylist) {
        return (NSInteger)_matches.count;
    }
    return [self showsFilesSection] ? (NSInteger)_fileHits.count : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == VibeSearchSectionPlaylist) {
        // No heading over the browse list.
        return (_matches.count > 0 && [self currentQuery].length > 0)
                ? STR_SEARCH_SECTION_PLAYLIST : nil;
    }
    return [self showsFilesSection] ? STR_SEARCH_SECTION_FILES : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == VibeSearchSectionFiles && [self showsFilesSection] && _fileIndex.isBuilding) {
        return STR_SEARCH_FILES_SCANNING;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == VibeSearchSectionFiles) {
        return [self fileCellForTableView:tableView row:(NSUInteger)indexPath.row];
    }
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

// No tags (each would be a download): filename over folder, a glyph, no art.
- (UITableViewCell *)fileCellForTableView:(UITableView *)tableView row:(NSUInteger)row {
    static NSString *const identifier = @"file";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    FileSearchHit *hit = _fileHits[row];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.image = [UIImage systemImageNamed:@"music.note"];
    content.imageProperties.maximumSize = CGSizeMake(40, 40);
    content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    content.text = hit.fileName;
    content.secondaryText = hit.folderName;
    content.textProperties.numberOfLines = 1;
    content.secondaryTextProperties.numberOfLines = 1;
    cell.contentConfiguration = content;
    return cell;
}

// A playlist row selects and stays; a file row is an OPEN, like any other.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // Resigns the field but keeps the query.
    [_searchController.searchBar resignFirstResponder];
    if (indexPath.section == VibeSearchSectionFiles) {
        [_playback openSearchResultURL:_fileHits[(NSUInteger)indexPath.row].url];
        return;
    }
    [_playback selectTrackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
}

#pragma mark - FileSearchIndexDelegate

// Only the files section can have changed.
- (void)fileSearchIndexDidGrow:(FileSearchIndex *)index {
    [self reloadFilesSection];
}

- (void)fileSearchIndexDidFinishBuilding:(FileSearchIndex *)index {
    [self reloadFilesSection];   // drops the footer
}

- (void)reloadFilesSection {
    if (![self isMateriallyVisible]) {
        return;
    }
    NSString *query = [self currentQuery];
    if (query.length == 0 && _fileHits.count == 0) {
        return;   // browsing
    }
    [self requestFileHitsForQuery:query];
}

#pragma mark - PlaybackObserver

// Re-filter, not reload: every match is an index into the old playlist, and
// the exclusion set and roots may have changed too. Replace and append alike.
- (void)playlistDidChange {
    [self rebuildPlaylistPaths];
    [self applySearchRoots];
    if ([self isMateriallyVisible]) {
        [self filterWithQuery:[self currentQuery]];
    }
    else {
        _matchesStale = YES;
        _fileHits = @[];
        [_fileIndex cancelPendingHitRequests];
    }
}

- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    [self playlistDidChange];
}

- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [self playlistDidChange];
}

// Coalesced: a scan delivers one per track, and each re-filter is a playlist
// pass plus a reloadData on main while the player opens a file.
- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    _matchesStale = YES;
    [self scheduleRefilter];
}

- (void)scheduleRefilter {
    if (_refilterScheduled || ![self isMateriallyVisible]) {
        return;
    }
    _refilterScheduled = YES;
    [self performSelector:@selector(refilterIfStale)
               withObject:nil
               afterDelay:kRefilterCoalesceInterval];
}

- (void)refilterIfStale {
    _refilterScheduled = NO;
    if (_matchesStale && [self isMateriallyVisible]) {
        [self filterWithQuery:[self currentQuery]];
    }
}

@end
