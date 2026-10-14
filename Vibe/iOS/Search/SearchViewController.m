//
//  SearchViewController.m
//  Vibe (iOS)
//

#import "SearchViewController.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AccountMirror.h"
#import "AccountSearch.h"
#import "FileRow.h"
#import "FileSearchIndex.h"
#import "FileSearchRules.h"
#import "FilePaths.h"
#import "PlaybackController.h"
#import "PlaybackController+ReplacePrompt.h"
#import "Playlist.h"
#import "FavoritesStore.h"
#import "LocationStore.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

// A folder scan's metadata stream costs a handful of rebuilds, not one per
// track, and still reads as live.
static const NSTimeInterval kRefilterCoalesceInterval = 0.25;

// Uncapped, a one-letter query reloads thousands of rows per keystroke. The
// playlist section is uncapped: it doubles as the browse list.
static const NSUInteger kMaxFileResults = 200;

// The playlist, the local files, then one section per account in
// AccountMirror.mirrors order: a section past the files is an account's.
typedef NS_ENUM(NSInteger, VibeSearchSection) {
    VibeSearchSectionPlaylist = 0,
    VibeSearchSectionFiles,
    VibeSearchSectionFirstAccount,
};
// The scope bar's All, which is no one section.
static const NSInteger kVibeSearchScopeAll = -1;

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
    // One per account, in section order.
    NSArray<AccountSearch *> *_accountSearches;
    // A files match is out and unanswered; no "No Results" until it lands.
    BOOL                _fileHitsPending;
    // The scope bar: one section, or kVibeSearchScopeAll. A half outside it
    // shows nothing; an account keeps the answer it has, so a scope switched
    // away and back asks nothing again.
    NSInteger           _scope;
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
        NSMutableArray<AccountSearch *> *searches = [NSMutableArray array];
        __weak SearchViewController *weakSelf = self;
        for (AccountMirror *mirror in AccountMirror.mirrors) {
            AccountSearch *search = [[AccountSearch alloc] initWithMirror:mirror];
            __weak AccountSearch *weakSearch = search;
            search.changeHandler = ^{
                [weakSelf reloadSectionOfAccountSearch:weakSearch];
            };
            [searches addObject:search];
        }
        _accountSearches = searches;
        _fileIndex = [[FileSearchIndex alloc] init];
        _fileIndex.delegate = self;
        _materialSurfaceVisible = YES;
        _scope = kVibeSearchScopeAll;
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
                                           selector:@selector(accountDidChange:)
                                               name:VibeAccountDidChangeNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(accountDownloadsDidChange:)
                                               name:VibeAccountDownloadsDidChangeNotification
                                             object:nil];
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
    // An empty field starts a fresh search across all sources.
    if ([self currentQuery].length == 0 && _scope != kVibeSearchScopeAll) {
        _scope = kVibeSearchScopeAll;
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
    for (AccountSearch *search in _accountSearches) {
        if (search.searching) {
            [search reset];
        }
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
    [self updateAccountsForQuery:query];
    [self.tableView reloadData];
    [self requestFileHitsForQuery:query];
    [self refreshEmptyState];
}

// "No Results" once every half in scope has answered with nothing. A half
// still asking, or an account's failure, which says so itself, is not that.
- (void)refreshEmptyState {
    // By the predicates the table draws its sections with, so a half out of
    // scope, whose answer is kept but not drawn, cannot hold No Results off.
    BOOL accountsEmpty = YES;
    for (AccountSearch *search in _accountSearches) {
        accountsEmpty = accountsEmpty && ![self showsSectionOfAccountSearch:search];
    }
    BOOL settledEmpty = [self currentQuery].length > 0 && _matches.count == 0 && !_fileHitsPending
            && ![self showsFilesSection] && accountsEmpty;
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

- (BOOL)scopeIncludes:(NSInteger)section {
    return _scope == kVibeSearchScopeAll || _scope == section;
}

- (NSInteger)sectionOfAccountSearch:(AccountSearch *)search {
    NSUInteger index = [_accountSearches indexOfObjectIdenticalTo:search];
    return index == NSNotFound ? NSNotFound : VibeSearchSectionFirstAccount + (NSInteger)index;
}

// Nil for a section that is not an account's.
- (AccountSearch *)accountSearchInSection:(NSInteger)section {
    NSInteger index = section - VibeSearchSectionFirstAccount;
    return index >= 0 && (NSUInteger)index < _accountSearches.count ? _accountSearches[(NSUInteger)index] : nil;
}

// The buttons in the order the sections are drawn: All, Playlist, Local,
// then each account while linked.
- (NSArray<NSNumber *> *)scopeSections {
    NSMutableArray<NSNumber *> *sections =
            [NSMutableArray arrayWithObjects:@(kVibeSearchScopeAll), @(VibeSearchSectionPlaylist),
                                             @(VibeSearchSectionFiles), nil];
    for (AccountSearch *search in _accountSearches) {
        if (search.mirror.client.isLinked) {
            [sections addObject:@([self sectionOfAccountSearch:search])];
        }
    }
    return sections;
}

// An account's scope that lost its account falls back to All.
- (void)refreshScopeButtons {
    NSArray<NSNumber *> *sections = [self scopeSections];
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:sections.count];
    for (NSNumber *section in sections) {
        NSInteger value = section.integerValue;
        if (value == kVibeSearchScopeAll) {
            [titles addObject:STR_SEARCH_SCOPE_ALL];
        }
        else if (value == VibeSearchSectionPlaylist) {
            [titles addObject:STR_SEARCH_SECTION_PLAYLIST];
        }
        else if (value == VibeSearchSectionFiles) {
            [titles addObject:STR_SEARCH_SECTION_FILES];
        }
        else {
            [titles addObject:[self accountSearchInSection:value].mirror.serviceName ?: @""];
        }
    }
    if (![sections containsObject:@(_scope)]) {
        _scope = kVibeSearchScopeAll;
    }
    _searchController.searchBar.scopeButtonTitles = titles;
    _searchController.searchBar.selectedScopeButtonIndex = (NSInteger)[sections indexOfObject:@(_scope)];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
    _scope = [self scopeSections][(NSUInteger)selectedScope].integerValue;
    [self filterWithQuery:[self currentQuery]];
}

// The answer in hand is the previous account's, hidden or not: kept, the
// same query on return would draw that account's files, and a tap would
// resolve them against this one.
- (void)accountDidChange:(NSNotification *)notification {
    [self refreshScopeButtons];
    for (AccountSearch *search in _accountSearches) {
        if (search.mirror.client == notification.object) {
            [search reset];
        }
    }
    if ([self isMateriallyVisible]) {
        [self filterWithQuery:[self currentQuery]];
    }
}

#pragma mark - Accounts

- (BOOL)searchesAccount:(AccountSearch *)search {
    return search.mirror.client.isLinked && [self currentQuery].length > 0;
}

// Each asks only while linked, with a query, on screen and in scope.
- (void)updateAccountsForQuery:(NSString *)query {
    for (AccountSearch *search in _accountSearches) {
        if (![self searchesAccount:search] || ![self isMateriallyVisible]) {
            [search reset];
            continue;
        }
        if ([self scopeIncludes:[self sectionOfAccountSearch:search]]) {
            [search searchQuery:query];
        }
    }
}

- (void)accountDownloadsDidChange:(NSNotification *)notification {
    for (AccountSearch *search in _accountSearches) {
        if (search.mirror == notification.object) {
            [search downloadsDidChange];
        }
    }
}

- (void)reloadSectionOfAccountSearch:(AccountSearch *)search {
    NSInteger section = search ? [self sectionOfAccountSearch:search] : NSNotFound;
    if (section != NSNotFound && [self isMateriallyVisible]) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)section]
                      withRowAnimation:UITableViewRowAnimationNone];
        [self refreshEmptyState];
    }
}

// A hit's local URL, and whether it is a folder. An account's hit (mirror
// set) has its folder listed into the mirror first, so the file it names
// exists.
- (void)resolveHit:(id)hit
            mirror:(AccountMirror *)mirror
        completion:(void (^)(NSURL *url, BOOL folder))completion {
    if (!mirror) {
        completion(((FileSearchHit *)hit).url, NO);
        return;
    }
    BOOL folder = [mirror entryIsFolder:hit];
    [mirror localURLForEntry:hit completion:^(NSURL *url, NSError *error) {
        if (url) {
            completion(url, folder);
        }
        else {
            LogWarn(@"%@: could not reach a search hit: %@", mirror.serviceName, error.localizedDescription);
            // Silence would read as a tap that missed.
            [self vibePresentAlertWithTitle:mirror.serviceName
                                    message:[NSString stringWithFormat:STR_SETTINGS_ACCOUNT_CONNECT_FAILED,
                                             mirror.serviceName]];
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
    for (AudioTrack *track in tracks) {
        NSString *path = track.url.path;
        if (path) {
            [paths addObject:path];
        }
    }
    _playlistPaths = paths;
    for (AccountSearch *search in _accountSearches) {
        NSMutableSet<NSString *> *identities = [NSMutableSet set];
        for (AudioTrack *track in tracks) {
            NSString *identity = [search.mirror identityOfURL:track.url];
            if (identity) {
                [identities addObject:identity];
            }
        }
        search.playlistIdentities = identities;
    }
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeSearchSectionFirstAccount + (NSInteger)_accountSearches.count;
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
    AccountSearch *search = [self accountSearchInSection:section];
    if (search) {
        return [self showsSectionOfAccountSearch:search] ? (NSInteger)search.hits.count : 0;
    }
    return [self showsFilesSection] ? (NSInteger)_fileHits.count : 0;
}

- (BOOL)showsSectionOfAccountSearch:(AccountSearch *)search {
    return [self searchesAccount:search] && [self scopeIncludes:[self sectionOfAccountSearch:search]]
            && (search.hits.count > 0 || search.searching || search.failed);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == VibeSearchSectionPlaylist) {
        // No heading over the browse list.
        return (_matches.count > 0 && [self currentQuery].length > 0)
                ? STR_SEARCH_SECTION_PLAYLIST : nil;
    }
    AccountSearch *search = [self accountSearchInSection:section];
    if (search) {
        // While asking, and when the ask failed, the heading says so: a
        // footer under no rows draws above its own section's header.
        if (![self showsSectionOfAccountSearch:search]) {
            return nil;
        }
        NSString *service = search.mirror.serviceName;
        if (search.failed) {
            return [NSString stringWithFormat:STR_BROWSER_ACCOUNT_UNREACHABLE, service];
        }
        return search.searching ? [NSString stringWithFormat:STR_SEARCH_ACCOUNT_SEARCHING, service] : service;
    }
    return [self showsFilesSection] ? STR_SEARCH_SECTION_FILES : nil;
}

// An account's heading spins while it asks: the words alone read as a label.
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    static const NSInteger kSpinnerTag = 0x5350;
    UIActivityIndicatorView *spinner = [view viewWithTag:kSpinnerTag];
    if (![self accountSearchInSection:section].searching) {
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
    AccountSearch *search = [self accountSearchInSection:indexPath.section];
    if (search) {
        return [self accountCellForTableView:tableView search:search row:(NSUInteger)indexPath.row];
    }
    static NSString *const identifier = @"result";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    AudioTrack *track = [_playlist trackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    [content vibeApplyFileIconForName:track.url.lastPathComponent folder:NO art:track.cachedThumbnail];
    content.text = track.displayTitle;
    content.secondaryText = track.displayArtist;
    content.textProperties.numberOfLines = 1;
    cell.contentConfiguration = content;
    return cell;
}

// A file or account hit: no tags (each would be a download), the name over
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
    [content vibeApplyFileIconForName:name folder:isFolder art:nil];
    content.text = name;
    content.secondaryText = folder;
    [content vibeApplyFileNameStyle];
    [cell vibeApplyRowContent:content opening:opening];
    cell.accessoryView = notDownloaded ? VibeNotDownloadedMark() : nil;
    return cell;
}

- (UITableViewCell *)fileCellForTableView:(UITableView *)tableView row:(NSUInteger)row {
    FileSearchHit *hit = _fileHits[row];
    return [self hitCellForTableView:tableView name:hit.fileName folder:hit.folderName isFolder:NO
                       notDownloaded:NO opening:[self hitIsOpening:hit]];
}

// An account's hit has no path on the disk until its resolve, so never spins.
- (BOOL)hitIsOpening:(id)hit {
    return [hit isKindOfClass:FileSearchHit.class]
            && [VibeComparablePath(((FileSearchHit *)hit).url.path) isEqualToString:_playback.openingPath];
}

- (UITableViewCell *)accountCellForTableView:(UITableView *)tableView
                                      search:(AccountSearch *)search
                                         row:(NSUInteger)row {
    NSDictionary *entry = search.hits[row];
    AccountMirror *mirror = search.mirror;
    BOOL folder = [mirror entryIsFolder:entry];
    NSString *identity = [mirror identityOfEntry:entry];
    return [self hitCellForTableView:tableView
                                name:[mirror nameOfEntry:entry]
                              folder:[mirror parentNameOfEntry:entry] ?: mirror.serviceName
                            isFolder:folder
                       notDownloaded:!folder && !(identity && [search.downloaded containsObject:identity])
                             opening:NO];
}

// A playlist row selects and stays; a file row plays that file alone, and an
// account's folder opens in the Files tab.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == VibeSearchSectionPlaylist) {
        [_playback selectTrackAtIndex:_matches[(NSUInteger)indexPath.row].unsignedIntegerValue];
        return;
    }
    // A folder hit opens in the Files tab, as a folder does in the browser:
    // playing it would land nothing when its songs are in subfolders.
    id hit = [self hitAtIndexPath:indexPath];
    AccountMirror *mirror = [self accountSearchInSection:indexPath.section].mirror;
    if (mirror && [mirror entryIsFolder:hit]) {
        [self showFolderOfHit:hit mirror:mirror];
        return;
    }
    // A second tap on the row still opening gives it up.
    if ([self hitIsOpening:hit]) {
        [_playback cancelOpening];
        return;
    }
    [self openHit:hit mirror:mirror inFolder:NO];
}

// A FileSearchHit, or an account's entry.
- (id)hitAtIndexPath:(NSIndexPath *)indexPath {
    AccountSearch *search = [self accountSearchInSection:indexPath.section];
    return search ? search.hits[(NSUInteger)indexPath.row] : _fileHits[(NSUInteger)indexPath.row];
}

- (void)openHit:(id)hit mirror:(AccountMirror *)mirror inFolder:(BOOL)inFolder {
    // Resigns the field but keeps the query.
    [_searchController.searchBar resignFirstResponder];
    PlaybackController *playback = _playback;
    // An account hit's resolve lists a folder: the newest request wins. It
    // has no row on the disk to spin until it does.
    NSURL *row = mirror ? nil : ((FileSearchHit *)hit).url;
    uint64_t token = [playback replaceRequestTokenOpening:row];
    __weak SearchViewController *weakSelf = self;
    [self resolveHit:hit mirror:mirror completion:^(NSURL *url, BOOL folder) {
        SearchViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [playback confirmReplacingPlaylistFrom:strongSelf openingURLs:@[url] inFolder:inFolder token:token];
    }];
}

// An account hit's resolve lists a folder, so the Add takes its token first:
// a replace made meanwhile supersedes it.
- (void)addHit:(id)hit mirror:(AccountMirror *)mirror {
    [_searchController.searchBar resignFirstResponder];
    PlaybackController *playback = _playback;
    uint64_t token = [playback addRequestToken];
    [self resolveHit:hit mirror:mirror completion:^(NSURL *url, BOOL folder) {
        [playback addURLs:@[url] token:token];
    }];
}

- (void)showFolderOfHit:(id)hit mirror:(AccountMirror *)mirror {
    void (^handler)(NSURL *, NSURL *) = _showDirectoryHandler;
    if (!handler) {
        return;
    }
    [_searchController.searchBar resignFirstResponder];
    [self resolveHit:hit mirror:mirror completion:^(NSURL *url, BOOL folder) {
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
    AccountMirror *mirror = [self accountSearchInSection:indexPath.section].mirror;
    BOOL folder = mirror && [mirror entryIsFolder:hit];
    __weak SearchViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY, @"play.fill", ^{
            [weakSelf openHit:hit mirror:mirror inFolder:NO];
        })];
        if (!folder) {
            [items addObject:VibeMenuAction(STR_MENU_CONTEXT_PLAY_IN_FOLDER, @"play.square.stack", ^{
                [weakSelf openHit:hit mirror:mirror inFolder:YES];
            })];
        }
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_ADD_TO_PLAYLIST, @"text.badge.plus", ^{
            [weakSelf addHit:hit mirror:mirror];
        })];
        [items addObject:VibeMenuAction(STR_MENU_CONTEXT_OPEN_FOLDER, @"folder", ^{
            [weakSelf showFolderOfHit:hit mirror:mirror];
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

// Metadata affects only playlist matches. Keep the file and account answers.
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
