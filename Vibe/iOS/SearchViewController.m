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
#import "SearchFolderStore.h"
#import "VibeStrings.h"

// How long a burst of metadata deliveries is allowed to gather before the
// matches are rebuilt. Long enough that a folder scan's stream of them costs a
// handful of passes rather than one per track, short enough to read as live.
static const NSTimeInterval kRefilterCoalesceInterval = 0.25;

// The files section is capped: it draws off a walk of up to twenty thousand
// files, and a query of one letter would otherwise reload thousands of rows on
// every keystroke. The playlist section is uncapped — it is what the user
// already has open, and it doubles as the browse list.
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
    // Indexes into the playlist, filtered by the live query. All rows when
    // the query is empty, so the screen doubles as a browse list.
    NSArray<NSNumber *> *_matches;
    // The files section: the walk, its current answer, and the playlist's paths
    // so a track the playlist already lists is not offered twice. The path set
    // is rebuilt on a playlist change, not per keystroke.
    FileSearchIndex     *_fileIndex;
    NSArray<FileSearchHit *> *_fileHits;
    NSSet<NSString *>   *_playlistPaths;
    // Tags have landed that the matches have not been rebuilt for, and whether
    // a rebuild is already parked.
    BOOL                _matchesStale;
    BOOL                _refilterScheduled;
    // The controller owns presentation visibility; RootViewController supplies
    // whether its custom card leaves this tab's pixels materially exposed.
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
    // Dragging the results puts the keyboard away, which is the only way to see
    // the bottom half of them: UISearchTab hoists the field into the tab bar, so
    // the keyboard covers the LIST rather than sitting under a field inside it,
    // and nothing else here would ever dismiss it. Not `interactive` — that mode
    // tracks a field the scroll view contains, and this one does not contain it.
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // Deliberately not focused on appear: this is a tab root, and seizing the
    // keyboard on every switch to it is not what a tab does.
    [_playback addObserver:self];
    // The settings screen adds folders on the PLAYLIST tab, so this screen's own
    // appearance would usually be enough to notice — but the launch resolve of
    // the persisted grants is asynchronous and can land while this screen is
    // already up, and then nothing else would ever tell it.
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(searchFoldersDidChange:)
                                               name:VibeSearchFoldersDidChangeNotification
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

// Different roots discard the index and re-walk; the same ones are a no-op, so
// this is cheap to call on every appearance. The build is started only from a
// screen that is up: arriving here is the signal the work is wanted.
- (void)applySearchRoots {
    [_fileIndex setRoots:_playback.searchRoots];
    if ([self isMateriallyVisible]) {
        [_fileIndex beginBuildIfNeeded];
    }
}

// Off screen the matches are left to go stale; deliveries schedule nothing
// while the tab is not showing, so a folder scan behind another tab costs
// this screen nothing at all.
//
// The FILE walk starts here rather than on the first keystroke: arriving on this
// screen is the signal it is wanted, and starting it now is what lets the first
// query answer off an index that is already filling. It is idempotent, so the
// second appearance costs nothing.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _viewPresentationVisible = YES;
    [_fileIndex setRoots:_playback.searchRoots];
    if ([self isMateriallyVisible]) {
        [_fileIndex beginBuildIfNeeded];
    }
    // Unconditional, not gated on _matchesStale: the walk delivers while this
    // screen is off in the wings and its reloads are dropped there, so appearing
    // is the one place both sections are known to be drawn from what is current.
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

// The playlist half is a synchronous pass and lands on this run loop turn. The
// files half snapshots whatever the walk has delivered and does its localized
// matching away from main; later batches supersede that work instead of stacking
// passes. Neither waits on the other or on a provider listing.
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

// An empty section draws no header, so a search with no file matches does not
// leave a bare "Files" heading behind — except while the walk is still running,
// where the heading and its footer are how a partial answer says so.
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
        // No heading over a browse list: with an empty query this section is
        // the whole screen and has nothing to be distinguished from.
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

// A file the walk found carries no tags — reading them would be a download each
// — so the row is its filename over its folder, and a glyph rather than art.
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

// A playlist row is a selection and stays here, as the library's rows do. A file
// row is an OPEN: its folder becomes the playlist, so the card presents, exactly
// as it does for any other open.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // Picking something is the end of typing. The query is left in the field, so
    // the results stay put and a second pick needs no re-typing.
    [_searchController.searchBar resignFirstResponder];
    if (indexPath.section == VibeSearchSectionFiles) {
        [_playback openSearchResultURL:_fileHits[(NSUInteger)indexPath.row].url];
        return;
    }
    [_playback selectTrackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
}

#pragma mark - FileSearchIndexDelegate

// The index grew, so the files section can only have gained rows; the playlist
// section is untouched. Refiltering the whole screen would be a wasted pass
// over the playlist a few times a second for the length of the walk.
- (void)fileSearchIndexDidGrow:(FileSearchIndex *)index {
    [self reloadFilesSection];
}

- (void)fileSearchIndexDidFinishBuilding:(FileSearchIndex *)index {
    [self reloadFilesSection];   // drops the "searching" footer
}

- (void)reloadFilesSection {
    if (![self isMateriallyVisible]) {
        return;
    }
    NSString *query = [self currentQuery];
    if (query.length == 0 && _fileHits.count == 0) {
        return;   // browsing: the walk's batches have nothing to draw
    }
    [self requestFileHitsForQuery:query];
}

#pragma mark - PlaybackObserver

// Re-filter rather than reload: the matches are indexes into a playlist that
// has just been replaced, so every one of them is stale. The new playlist is
// also a new exclusion set, and — when the open changed folders — new search
// roots, which discard the index and re-walk on the next appearance.
- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    [self rebuildPlaylistPaths];
    [self applySearchRoots];
    [self refreshAfterPlaylistChange];
}

- (void)playback:(PlaybackController *)playback didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [self rebuildPlaylistPaths];
    [self refreshAfterPlaylistChange];
}

- (void)refreshAfterPlaylistChange {
    if ([self isMateriallyVisible]) {
        [self filterWithQuery:[self currentQuery]];
    }
    else {
        _matchesStale = YES;
        _fileHits = @[];
        [_fileIndex cancelPendingHitRequests];
    }
}

// Tags can change what a row says and what the query matches, but a folder
// scan delivers one of these per track, and a re-filter is a pass over the
// whole playlist plus a reloadData — thousands of them, on main, while the
// player is opening a file. Coalesce instead of answering each one.
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
