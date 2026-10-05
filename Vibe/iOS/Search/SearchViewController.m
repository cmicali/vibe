//
//  SearchViewController.m
//  Vibe (iOS)
//

#import "SearchViewController.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "BrowserViewController.h"
#import "DropboxMirror.h"
#import "DropboxRules.h"
#import "FileSearchIndex.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"
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

// A Dropbox query is a network round trip, so it waits for typing to pause.
static const NSTimeInterval kDropboxSearchDelay = 0.3;

typedef NS_ENUM(NSInteger, VibeSearchSection) {
    VibeSearchSectionPlaylist = 0,
    VibeSearchSectionFiles,
    VibeSearchSectionDropbox,
    VibeSearchSectionCount
};

@interface SearchViewController () <UISearchResultsUpdating, UISearchBarDelegate, PlaybackObserver,
                                    FileSearchIndexDelegate>
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
    // files/search_v2's answer to _dropboxQuery, and the rows drawn from it:
    // those entries minus what the playlist already lists.
    NSString            *_dropboxQuery;
    NSArray<NSDictionary *> *_dropboxEntries;
    NSArray<NSDictionary *> *_dropboxHits;
    // Stamped on each query sent; only the newest answer lands.
    uint64_t            _dropboxSearchGeneration;
    BOOL                _dropboxSearching;
    // The answer to _dropboxQuery was an error, not an empty list.
    BOOL                _dropboxFailed;
    // Of the answer's files, those the mirror holds bytes for, by path_lower;
    // counted once per answer and per download, not per cell.
    NSSet<NSString *>   *_dropboxDownloaded;
    // A files match is out and unanswered; no "No Results" until it lands.
    BOOL                _fileHitsPending;
    // The scope bar: one section, or VibeSearchSectionCount for All. A half
    // outside it shows nothing; Dropbox keeps the answer it has, so a scope
    // switched away and back asks nothing again.
    VibeSearchSection   _scope;
    // The playlist's tracks as lowercase Dropbox paths, for the exclusion.
    NSSet<NSString *>   *_playlistDropboxPaths;
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
        _dropboxEntries = @[];
        _dropboxHits = @[];
        _dropboxDownloaded = [NSSet set];
        _playlistDropboxPaths = [NSSet set];
        _fileIndex = [[FileSearchIndex alloc] init];
        _fileIndex.delegate = self;
        _materialSurfaceVisible = YES;
        _scope = VibeSearchSectionCount;
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
    _searchController.searchBar.delegate = self;
    // Always up, not only while the field is active: the field is in the tab bar.
    _searchController.scopeBarActivation = UISearchControllerScopeBarActivationManual;
    _searchController.searchBar.showsScopeBar = YES;
    [self refreshScopeButtons];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(dropboxAccountDidChange:)
                                               name:VibeDropboxAccountDidChangeNotification
                                             object:DropboxMirror.shared.client];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(dropboxDownloadsDidChange:)
                                               name:VibeDropboxDownloadsDidChangeNotification
                                             object:DropboxMirror.shared];
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
    // A scope left over from the last search made the next one look empty.
    if ([self currentQuery].length == 0 && _scope != VibeSearchSectionCount) {
        _scope = VibeSearchSectionCount;
        [self refreshScopeButtons];
    }
    [self applySearchRoots];
    // Unconditional: reloads are dropped while hidden.
    [self filterWithQuery:[self currentQuery]];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _viewPresentationVisible = NO;
    [_fileIndex cancelPendingHitRequests];
    // A search cut off here asks again on return; an answer in hand stays.
    if (_dropboxSearching) {
        [self resetDropboxSearch];
    }
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
    [self matchPlaylistForQuery:query];
    _fileHits = @[];
    [self updateDropboxForQuery:query];
    [self.tableView reloadData];
    [self requestFileHitsForQuery:query];
    [self refreshEmptyState];
}

// "No Results" once every half in scope has answered with nothing. A half
// still asking, or a Dropbox failure, which says so itself, is not that.
- (void)refreshEmptyState {
    // By the predicates the table draws its sections with, so a half out of
    // scope, whose answer is kept but not drawn, cannot hold No Results off.
    BOOL settledEmpty = [self currentQuery].length > 0 && _matches.count == 0 && !_fileHitsPending
            && ![self showsFilesSection] && ![self showsDropboxSection];
    self.contentUnavailableConfiguration = settledEmpty
            ? [UIContentUnavailableConfiguration searchConfiguration] : nil;
}

- (void)matchPlaylistForQuery:(NSString *)query {
    _matchesStale = NO;
    if (![self scopeIncludes:VibeSearchSectionPlaylist]) {
        _matches = @[];
        return;
    }
    NSArray<AudioTrack *> *tracks = _playlist.tracks;
    NSMutableArray<NSNumber *> *matches = [NSMutableArray arrayWithCapacity:tracks.count];
    for (NSUInteger i = 0; i < tracks.count; i++) {
        if ([self track:tracks[i] matchesQuery:query]) {
            [matches addObject:@(i)];
        }
    }
    _matches = matches;
}

#pragma mark - Scope

- (BOOL)scopeIncludes:(VibeSearchSection)section {
    return _scope == VibeSearchSectionCount || _scope == section;
}

// The buttons in the order the sections are drawn: All, Playlist, Local,
// Dropbox while linked.
- (NSArray<NSNumber *> *)scopeSections {
    return DropboxMirror.shared.client.isLinked
            ? @[@(VibeSearchSectionCount), @(VibeSearchSectionPlaylist), @(VibeSearchSectionFiles), @(VibeSearchSectionDropbox)]
            : @[@(VibeSearchSectionCount), @(VibeSearchSectionPlaylist), @(VibeSearchSectionFiles)];
}

// A Dropbox scope that lost its account falls back to All.
- (void)refreshScopeButtons {
    NSArray<NSNumber *> *sections = [self scopeSections];
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:sections.count];
    for (NSNumber *section in sections) {
        switch ((VibeSearchSection)section.integerValue) {
            case VibeSearchSectionFiles:    [titles addObject:STR_SEARCH_SECTION_FILES]; break;
            case VibeSearchSectionDropbox:  [titles addObject:VibeNotLocalized(@"Dropbox")]; break;
            case VibeSearchSectionPlaylist: [titles addObject:STR_SEARCH_SECTION_PLAYLIST]; break;
            case VibeSearchSectionCount:    [titles addObject:STR_SEARCH_SCOPE_ALL]; break;
        }
    }
    if (![sections containsObject:@(_scope)]) {
        _scope = VibeSearchSectionCount;
    }
    _searchController.searchBar.scopeButtonTitles = titles;
    _searchController.searchBar.selectedScopeButtonIndex = (NSInteger)[sections indexOfObject:@(_scope)];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    _scope = (VibeSearchSection)[self scopeSections][(NSUInteger)selectedScope].integerValue;
    [self filterWithQuery:[self currentQuery]];
}

// The answer in hand is the previous account's, hidden or not: kept, the
// same query on return would draw that account's files, and a tap would
// resolve their paths against this one.
- (void)dropboxAccountDidChange:(NSNotification *)notification {
    [self refreshScopeButtons];
    [self resetDropboxSearch];
    if ([self isMateriallyVisible]) {
        [self filterWithQuery:[self currentQuery]];
    }
}

#pragma mark - Dropbox

- (BOOL)searchesDropbox {
    return DropboxMirror.shared.client.isLinked && [self currentQuery].length > 0;
}

// Only a new query asks Dropbox. The same one — a re-filter for a playlist
// change or a reappearance — re-applies the exclusion to the answer in hand.
- (void)updateDropboxForQuery:(NSString *)query {
    if (![self searchesDropbox] || ![self isMateriallyVisible]) {
        [self resetDropboxSearch];
        return;
    }
    if (![self scopeIncludes:VibeSearchSectionDropbox]) {
        return;
    }
    if ([query isEqualToString:_dropboxQuery]) {
        _dropboxHits = [self dropboxEntriesNotInPlaylist:_dropboxEntries];
        return;
    }
    // Every keystroke restarts the pause and moves the generation, so an
    // answer to a query already typed past is dropped on arrival.
    [self resetDropboxSearch];
    _dropboxQuery = [query copy];
    _dropboxSearching = YES;
    [self performSelector:@selector(runDropboxSearch) withObject:nil afterDelay:kDropboxSearchDelay];
}

// No pending or in-flight answer and none in hand; the next query asks.
- (void)resetDropboxSearch {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runDropboxSearch) object:nil];
    _dropboxSearchGeneration++;
    _dropboxSearching = NO;
    _dropboxFailed = NO;
    _dropboxQuery = nil;
    _dropboxEntries = @[];
    _dropboxHits = @[];
    _dropboxDownloaded = [NSSet set];
}

- (NSArray<NSDictionary *> *)dropboxEntriesNotInPlaylist:(NSArray<NSDictionary *> *)entries {
    NSMutableArray<NSDictionary *> *hits = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *entry in entries) {
        if (![_playlistDropboxPaths containsObject:entry[@"path_lower"]]) {
            [hits addObject:entry];
        }
    }
    return hits;
}

- (void)runDropboxSearch {
    uint64_t generation = _dropboxSearchGeneration;
    __weak SearchViewController *weakSelf = self;
    [DropboxMirror.shared searchQuery:_dropboxQuery
                           completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        SearchViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_dropboxSearchGeneration) {
            return;
        }
        // A failure is an empty answer to this query, not a retry per
        // re-filter; the next keystroke asks again.
        if (error) {
            LogWarn(@"Dropbox: search failed: %@", error.localizedDescription);
        }
        strongSelf->_dropboxSearching = NO;
        strongSelf->_dropboxFailed = error != nil;
        strongSelf->_dropboxEntries = entries ?: @[];
        strongSelf->_dropboxHits = [strongSelf dropboxEntriesNotInPlaylist:strongSelf->_dropboxEntries];
        [strongSelf reloadDropboxSection];
        [strongSelf countDownloadedDropboxEntries];
    }];
}

// Off main, a stat per file hit; the section redraws when it lands. A path
// the mirror spells another way reads as not downloaded, which errs safe.
- (void)countDownloadedDropboxEntries {
    NSArray<NSDictionary *> *entries = _dropboxEntries;
    NSURL *account = DropboxMirror.shared.accountURL;
    uint64_t generation = _dropboxSearchGeneration;
    __weak SearchViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableSet<NSString *> *downloaded = [NSMutableSet set];
        for (NSDictionary *entry in entries) {
            NSString *display = entry[@"path_display"];
            NSString *lower = entry[@"path_lower"];
            if (!account || ![display isKindOfClass:NSString.class] || ![lower isKindOfClass:NSString.class]
                    || VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder) {
                continue;
            }
            NSURL *local = [account URLByAppendingPathComponent:display];
            if ([NSFileManager.defaultManager fileExistsAtPath:local.path]
                    && ![NSURLUtil isRemotePlaceholderFile:local]) {
                [downloaded addObject:lower];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            SearchViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf->_dropboxSearchGeneration) {
                return;
            }
            strongSelf->_dropboxDownloaded = downloaded;
            [strongSelf reloadDropboxSection];
        });
    });
}

- (void)dropboxDownloadsDidChange:(NSNotification *)notification {
    if (_dropboxEntries.count > 0) {
        [self countDownloadedDropboxEntries];
    }
}

- (void)reloadDropboxSection {
    if ([self isMateriallyVisible]) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeSearchSectionDropbox]
                      withRowAnimation:UITableViewRowAnimationNone];
        [self refreshEmptyState];
    }
}

// A hit's local URL, and whether it is a folder. A Dropbox hit's folder is
// listed into the mirror first, so the file it names exists.
- (void)resolveHit:(id)hit completion:(void (^)(NSURL *url, BOOL folder))completion {
    if ([hit isKindOfClass:FileSearchHit.class]) {
        completion(((FileSearchHit *)hit).url, NO);
        return;
    }
    BOOL folder = VibeDropboxEntryKindOf(hit) == VibeDropboxEntryKindFolder;
    [DropboxMirror.shared localURLForEntry:hit completion:^(NSURL *url, NSError *error) {
        if (url) {
            completion(url, folder);
        }
        else {
            LogWarn(@"Dropbox: could not reach a search hit: %@", error.localizedDescription);
            // Silence would read as a tap that missed.
            VibePresentAlert(self, VibeNotLocalized(@"Dropbox"), STR_SETTINGS_DROPBOX_CONNECT_FAILED);
        }
    }];
}

- (void)requestFileHitsForQuery:(NSString *)query {
    if (![self isMateriallyVisible] || query.length == 0 || ![self scopeIncludes:VibeSearchSectionFiles]) {
        [_fileIndex cancelPendingHitRequests];
        _fileHitsPending = NO;
        return;
    }
    _fileHitsPending = YES;
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
        // By name, as a folder lists them: the walk's order is the disk's.
        strongSelf->_fileHits = [hits sortedArrayUsingComparator:^NSComparisonResult(FileSearchHit *a, FileSearchHit *b) {
            return [a.fileName localizedStandardCompare:b.fileName];
        }];
        strongSelf->_fileHitsPending = NO;
        [strongSelf.tableView reloadSections:
                [NSIndexSet indexSetWithIndex:VibeSearchSectionFiles]
                            withRowAnimation:UITableViewRowAnimationNone];
        [strongSelf refreshEmptyState];
    }];
}

- (BOOL)track:(AudioTrack *)track matchesQuery:(NSString *)query {
    return VibeSearchTrackMatchesQuery(track.title, track.artist,
                                       track.url.lastPathComponent, query);
}

- (void)rebuildPlaylistPaths {
    NSArray<AudioTrack *> *tracks = _playlist.tracks;
    NSMutableSet<NSString *> *paths = [NSMutableSet setWithCapacity:tracks.count];
    NSMutableSet<NSString *> *dropboxPaths = [NSMutableSet set];
    DropboxMirror *mirror = DropboxMirror.shared;
    for (AudioTrack *track in tracks) {
        NSString *path = track.url.path;
        if (path) {
            [paths addObject:path];
        }
        NSString *dropboxPath = [mirror dropboxPathForURL:track.url].lowercaseString;
        if (dropboxPath) {
            [dropboxPaths addObject:dropboxPath];
        }
    }
    _playlistPaths = paths;
    _playlistDropboxPaths = dropboxPaths;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeSearchSectionCount;
}

// An empty section draws no header, except while the walk runs.
- (BOOL)showsFilesSection {
    return [self currentQuery].length > 0 && [self scopeIncludes:VibeSearchSectionFiles]
            && (_fileHits.count > 0 || _fileIndex.isBuilding);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == VibeSearchSectionPlaylist) {
        return (NSInteger)_matches.count;
    }
    if (section == VibeSearchSectionDropbox) {
        return [self showsDropboxSection] ? (NSInteger)_dropboxHits.count : 0;
    }
    return [self showsFilesSection] ? (NSInteger)_fileHits.count : 0;
}

- (BOOL)showsDropboxSection {
    return [self searchesDropbox] && [self scopeIncludes:VibeSearchSectionDropbox]
            && (_dropboxHits.count > 0 || _dropboxSearching || _dropboxFailed);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == VibeSearchSectionPlaylist) {
        // No heading over the browse list.
        return (_matches.count > 0 && [self currentQuery].length > 0)
                ? STR_SEARCH_SECTION_PLAYLIST : nil;
    }
    if (section == VibeSearchSectionDropbox) {
        // While asking, and when the ask failed, the heading says so: a
        // footer under no rows draws above its own section's header.
        if (![self showsDropboxSection]) {
            return nil;
        }
        if (_dropboxFailed) {
            return STR_BROWSER_DROPBOX_UNREACHABLE;
        }
        return _dropboxSearching ? STR_SEARCH_DROPBOX_SEARCHING : VibeNotLocalized(@"Dropbox");
    }
    return [self showsFilesSection] ? STR_SEARCH_SECTION_FILES : nil;
}

// The Dropbox heading spins while it asks: the words alone read as a label.
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    static const NSInteger kSpinnerTag = 0x5350;
    UIActivityIndicatorView *spinner = [view viewWithTag:kSpinnerTag];
    if (section != VibeSearchSectionDropbox || !_dropboxSearching) {
        [spinner removeFromSuperview];
        return;
    }
    if (!spinner) {
        spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.tag = kSpinnerTag;
        spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin
                | UIViewAutoresizingFlexibleBottomMargin;
        [view addSubview:spinner];
    }
    BOOL rightToLeft = view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat inset = view.layoutMargins.right + CGRectGetWidth(spinner.bounds) / 2;
    spinner.center = CGPointMake(rightToLeft ? inset : CGRectGetWidth(view.bounds) - inset,
                                 CGRectGetMidY(view.bounds));
    [spinner startAnimating];
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
    if (indexPath.section == VibeSearchSectionDropbox) {
        return [self dropboxCellForTableView:tableView row:(NSUInteger)indexPath.row];
    }
    static NSString *const identifier = @"result";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    AudioTrack *track = [_playlist trackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    VibeApplyFileIcon(content, track.url.lastPathComponent, NO, track.cachedThumbnail);
    content.text = track.displayTitle;
    content.secondaryText = track.displayArtist;
    content.textProperties.numberOfLines = 1;
    cell.contentConfiguration = content;
    return cell;
}

// A file or Dropbox hit: no tags (each would be a download), the name over
// its folder, the browser's folder glyph or file tile, no art.
- (UITableViewCell *)hitCellForTableView:(UITableView *)tableView
                                    name:(NSString *)name
                                  folder:(NSString *)folder
                                isFolder:(BOOL)isFolder
                           notDownloaded:(BOOL)notDownloaded
                                 opening:(BOOL)opening {
    static NSString *const identifier = @"hit";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    VibeApplyFileIcon(content, name, isFolder, nil);
    content.text = name;
    content.secondaryText = folder;
    VibeApplyFileNameStyle(content);
    VibeApplyRowContent(cell, content, opening);
    cell.accessoryView = notDownloaded ? VibeNotDownloadedMark() : nil;
    return cell;
}

- (UITableViewCell *)fileCellForTableView:(UITableView *)tableView row:(NSUInteger)row {
    FileSearchHit *hit = _fileHits[row];
    return [self hitCellForTableView:tableView name:hit.fileName folder:hit.folderName isFolder:NO
                       notDownloaded:NO opening:[self hitIsOpening:hit]];
}

// A Dropbox hit has no path on the disk until its resolve, so never spins.
- (BOOL)hitIsOpening:(id)hit {
    return [hit isKindOfClass:FileSearchHit.class]
            && [VibeComparablePath(((FileSearchHit *)hit).url.path) isEqualToString:_playback.openingPath];
}

- (UITableViewCell *)dropboxCellForTableView:(UITableView *)tableView row:(NSUInteger)row {
    NSDictionary *entry = _dropboxHits[row];
    NSString *display = entry[@"path_display"] ?: entry[@"path_lower"];
    NSString *parent = display.stringByDeletingLastPathComponent.lastPathComponent;
    BOOL folder = VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder;
    return [self hitCellForTableView:tableView
                                name:entry[@"name"]
                              folder:[parent isEqualToString:@"/"] ? VibeNotLocalized(@"Dropbox") : parent
                            isFolder:folder
                       notDownloaded:!folder && ![_dropboxDownloaded containsObject:entry[@"path_lower"]]
                             opening:NO];
}

// A playlist row selects and stays; a file row plays that file alone, and a
// Dropbox folder opens as the playlist.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == VibeSearchSectionPlaylist) {
        [_playback selectTrackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
        return;
    }
    // A folder hit opens in the Files tab, as a folder does in the browser:
    // playing it would land nothing when its songs are in subfolders.
    id hit = [self hitAtIndexPath:indexPath];
    if ([hit isKindOfClass:NSDictionary.class] && VibeDropboxEntryKindOf(hit) == VibeDropboxEntryKindFolder) {
        [self showFolderOfHit:hit];
        return;
    }
    // A second tap on the row still opening gives it up.
    if ([self hitIsOpening:hit]) {
        [_playback cancelOpening];
        return;
    }
    [self openHit:hit inFolder:NO];
}

// A FileSearchHit or a Dropbox entry.
- (id)hitAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == VibeSearchSectionFiles ? _fileHits[(NSUInteger)indexPath.row]
                                                       : _dropboxHits[(NSUInteger)indexPath.row];
}

- (void)openHit:(id)hit inFolder:(BOOL)inFolder {
    // Resigns the field but keeps the query.
    [_searchController.searchBar resignFirstResponder];
    PlaybackController *playback = _playback;
    // A Dropbox hit's resolve lists a folder: the newest request wins. A
    // Dropbox hit has no row on the disk to spin until it does.
    NSURL *row = [hit isKindOfClass:FileSearchHit.class] ? ((FileSearchHit *)hit).url : nil;
    uint64_t token = [playback replaceRequestTokenOpening:row];
    __weak SearchViewController *weakSelf = self;
    [self resolveHit:hit completion:^(NSURL *url, BOOL folder) {
        SearchViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [BrowserViewController confirmReplacingPlaylistOf:playback from:strongSelf
                                              openingURLs:@[url] inFolder:inFolder token:token];
    }];
}

// A Dropbox hit's resolve lists a folder, so the Add takes its token first:
// a replace made meanwhile supersedes it.
- (void)addHit:(id)hit {
    [_searchController.searchBar resignFirstResponder];
    PlaybackController *playback = _playback;
    uint64_t token = [playback addRequestToken];
    [self resolveHit:hit completion:^(NSURL *url, BOOL folder) {
        [playback addURLs:@[url] token:token];
    }];
}

- (void)showFolderOfHit:(id)hit {
    void (^handler)(NSURL *, NSURL *) = _showDirectoryHandler;
    if (!handler) {
        return;
    }
    [_searchController.searchBar resignFirstResponder];
    [self resolveHit:hit completion:^(NSURL *url, BOOL folder) {
        handler(folder ? url : url.URLByDeletingLastPathComponent, folder ? nil : url);
    }];
}

// A hit's long press, the rule Recents follows too: Play, Play in Folder for
// a file, Add to Playlist, and Open Folder, its directory in the Files tab.
// The hit, not the row, is captured: a late answer can reload the section
// while the menu is up.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                            point:(CGPoint)point {
    if (indexPath.section == VibeSearchSectionPlaylist) {
        return nil;
    }
    id hit = [self hitAtIndexPath:indexPath];
    BOOL folder = [hit isKindOfClass:NSDictionary.class]
            && VibeDropboxEntryKindOf(hit) == VibeDropboxEntryKindFolder;
    __weak SearchViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY, @"play.fill", ^{
            [weakSelf openHit:hit inFolder:NO];
        })];
        if (!folder) {
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY_IN_FOLDER, @"play.square.stack", ^{
                [weakSelf openHit:hit inFolder:YES];
            })];
        }
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf addHit:hit];
        })];
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_OPEN_FOLDER, @"folder", ^{
            [weakSelf showFolderOfHit:hit];
        })];
        return [UIMenu menuWithChildren:items];
    }];
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

// TRAP: hidden, the file hits are emptied without a reload (playlistDidChange),
// so reloading the table's cached rows here throws; showing re-filters anyway.
- (void)playbackDidChangeOpening:(PlaybackController *)playback {
    if (![self isMateriallyVisible]) {
        return;
    }
    NSMutableArray<NSIndexPath *> *rows = [NSMutableArray array];
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.section == VibeSearchSectionFiles) {
            [rows addObject:path];
        }
    }
    [self.tableView reloadRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationNone];
}

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

// A metadata delivery changes what the playlist's rows say, nothing else:
// the files and Dropbox halves keep their answers, which a full re-filter
// blanked and re-asked for on every delivery of a scan.
- (void)refilterIfStale {
    _refilterScheduled = NO;
    if (_matchesStale && [self isMateriallyVisible]) {
        [self matchPlaylistForQuery:[self currentQuery]];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:VibeSearchSectionPlaylist]
                      withRowAnimation:UITableViewRowAnimationNone];
        // An artist's tags arriving can be the first match, or the last.
        [self refreshEmptyState];
    }
}

@end
