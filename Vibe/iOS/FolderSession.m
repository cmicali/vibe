//
//  FolderSession.m
//  Vibe (iOS)
//

#import "FolderSession.h"
#import "AppSettings.h"
#import "AppStats.h"
#import "AudioTrack.h"
#import "DocumentTypes.h"
#import "FavoritesStore.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"
#import "SearchFolderStoreInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>

// iOS app-layer state, so not AppSettings.
static NSString *const kFolderBookmarkKey = @"VibeiOSFolderBookmark";
static NSString *const kAdditionBookmarksKey = @"VibeiOSAdditionBookmarks";
// Holds a standardized path despite its name: the shipped key is kept so a
// bare filename an older build wrote restores through the filename tier.
static NSString *const kLastTrackPathKey = @"VibeiOSLastTrackFileName";
// SearchFolderStore's bound, for its reason: one stalled provider must not
// head-of-line every other bookmark.
static const NSInteger kMaximumConcurrentBookmarkRestorations = 3;

@interface FolderSession () <UIDocumentPickerDelegate>
@end

@implementation FolderSession {
    // Every scope this session started, held for the session (the player,
    // TagLib and the waveform loader read under them at any time) and released
    // only once a successor set is in hand. Main-confined. A URL may appear
    // twice, each start balanced by its own stop.
    NSMutableArray<NSURL *> *_scopedURLs;
    // Persistent-root grants retained for this playlist, same lifetime.
    NSMutableArray<SearchFolderGrant *> *_searchGrants;
    // The BASE: title, star, bookmark. Appends never move it; nil for a
    // single-file base.
    NSURL *_folderURL;
    // Search roots only — never the title or the star.
    NSMutableArray<NSURL *> *_addedFolderURLs;
    // YES when this session's replace wrote the base bookmark, so the
    // persisted addition list is this session's to extend.
    BOOL _additionsPersisted;
    // Replaces run concurrently so a new intent never waits behind an older
    // provider call; the generation decides which result delivers.
    dispatch_queue_t _workQueue;
    // Serial, so two Adds land in order, but never behind a replace.
    dispatch_queue_t _appendQueue;
    _Atomic(uint64_t) _openIntentGeneration;
    // The last SETTLED replace's generation; an append lands only against it.
    // Zero: nothing has landed, so an Add is promoted to an Open. Main-confined.
    uint64_t _landedOpenIntentGeneration;
    // YES from a promotion until that open settles; later Adds park in
    // _addWaiters. Set only by a promotion, so after a failed launch restore
    // the next Add still plays. Main-confined.
    BOOL _promotedOpenInFlight;
    // The generation a promotion created, or zero; see addURLs:token:.
    uint64_t _promotedOpenIntentGeneration;
    // Waiters, delivered once when the promoted open settles, however it
    // settles. Main-confined.
    NSMutableArray<void (^)(void)> *_addWaiters;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
        _workQueue = dispatch_queue_create("FolderSession", attributes);
        _appendQueue = dispatch_queue_create_with_target("FolderSession.append",
                                                         DISPATCH_QUEUE_SERIAL, _workQueue);
        _scopedURLs = [NSMutableArray array];
        _searchGrants = [NSMutableArray array];
        _addedFolderURLs = [NSMutableArray array];
        atomic_init(&_openIntentGeneration, 0);
    }
    return self;
}

- (void)dealloc {
    for (NSURL *url in _scopedURLs) {
        [url stopAccessingSecurityScopedResource];
    }
}

- (NSString *)folderDisplayName {
    return _folderURL ? [[NSFileManager defaultManager] displayNameAtPath:_folderURL.path] : nil;
}

- (NSArray<NSURL *> *)searchRoots {
    return _folderURL ? [@[_folderURL] arrayByAddingObjectsFromArray:_addedFolderURLs]
                      : [_addedFolderURLs copy];
}

- (NSURL *)folderURL {
    return _folderURL;
}

- (uint64_t)beginOpenIntent {
    return atomic_fetch_add_explicit(&_openIntentGeneration, 1, memory_order_acq_rel) + 1;
}

- (BOOL)isCurrentOpenIntent:(uint64_t)openIntentGeneration {
    return atomic_load_explicit(&_openIntentGeneration, memory_order_acquire)
            == openIntentGeneration;
}

// Asked of two lists. self.searchRoots, the LOGICAL roots, answers what may be
// LISTED: a container folder is never security-scoped, yet a file picked in it
// must still expand to it. _scopedURLs answers what may be HELD.
// TRAP: a scope is started through the URL the system granted, never a
// path-equivalent one the app derived. A search hit leaves _folderURL a
// derived parent; asked for a hold, it refuses the start, nothing is
// collected, and the landing stops the real grant with no successor — the
// playlist goes unreadable mid-play.
- (NSURL *)rootCoveringPath:(NSString *)path in:(NSArray<NSURL *> *)roots {
    for (NSURL *root in roots) {
        if (VibeSearchRootCoversPath(root.URLByStandardizingPath.path, path)) {
            return root;
        }
    }
    return nil;
}

#pragma mark - Picker

- (void)presentPickerFromViewController:(UIViewController *)presenter {
    NSArray<UTType *> *types = [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    // The app's only multi-select road: the browser's stays off
    // (FilesViewController).
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self addURLs:urls];
}

#pragma mark - External opens

- (void)openURLs:(NSArray<NSURL *> *)urls openInPlace:(BOOL)openInPlace {
    if (!openInPlace) {
        // An inbox copy, readable without a scope. It skips the worker:
        // Documents/Inbox sits under Documents, so with Documents as the base
        // the coverage rule would expand the copy into the whole Inbox. Its
        // rows still come off main, since a large FLAC's are read from its
        // header, and off the work queue, which a walk hung on a provider can
        // hold; the generation drops a result a newer open superseded.
        NSURL *url = urls.firstObject;
        if (!url) {
            return;
        }
        uint64_t openIntentGeneration = [self beginOpenIntent];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<AudioTrack *> *rows = [NSURLUtil rowsForFile:url];
            run_on_main_thread({
                [self finishOpenIntent:openIntentGeneration appending:NO tracks:rows
                             folderURL:nil addedFolders:@[] selectedURL:nil restored:NO
                           ownedScopes:@[] ownedGrants:@[] baseBookmark:nil additionBookmarks:@[]];
            });
        });
        return;
    }
    [self beginOpenURLs:urls appending:NO fromSearchRoots:NO];
}

- (uint64_t)addRequestToken {
    return atomic_load_explicit(&_openIntentGeneration, memory_order_acquire);
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    [self addURLs:urls token:[self addRequestToken]];
}

- (void)addURLs:(NSArray<NSURL *> *)urls token:(uint64_t)token {
    // The token is taken when the USER asks, so a favorite whose resolve
    // outlived a replace is dropped rather than appended to the new playlist.
    //
    // TRAP: a PROMOTION is not a supersession. Promoting the first of several
    // Adds onto an empty playlist bumps the generation; without this exemption
    // its siblings are dropped here before they can park as waiters (seconds
    // on a cold provider). A token one below the live promoted generation is
    // still the user's; a real replace or a clear bumps past it.
    BOOL supersededByOwnPromotion = _promotedOpenIntentGeneration != 0
            && token + 1 == _promotedOpenIntentGeneration
            && [self isCurrentOpenIntent:_promotedOpenIntentGeneration];
    if (![self isCurrentOpenIntent:token] && !supersededByOwnPromotion) {
        LogInfo(@"FolderSession: dropping an Add superseded while its URL resolved");
        return;
    }
    [self beginOpenURLs:urls appending:YES fromSearchRoots:NO];
}

- (void)openFileFromSearchRoots:(NSURL *)url {
    [self beginOpenURLs:@[url] appending:NO fromSearchRoots:YES];
}

- (void)clearSession {
    // FIRST: an open in flight is superseded and releases its own scopes on
    // its own path. No successor set, so acquire-before-release does not apply.
    [self beginOpenIntent];
    for (NSURL *url in _scopedURLs) {
        [url stopAccessingSecurityScopedResource];
    }
    _scopedURLs = [NSMutableArray array];
    _searchGrants = [NSMutableArray array];
    _folderURL = nil;
    _addedFolderURLs = [NSMutableArray array];
    _additionsPersisted = NO;
    // Nothing has landed, so the next Add is promoted to an Open.
    _landedOpenIntentGeneration = 0;
    _promotedOpenInFlight = NO;
    _promotedOpenIntentGeneration = 0;
    _addWaiters = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kAdditionBookmarksKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastTrackPathKey];
}

#pragma mark - Persistence

- (BOOL)restorePersistedFolder {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
    if (!bookmark) {
        return NO;
    }
    NSArray *additions =
            [NSUserDefaults.standardUserDefaults arrayForKey:kAdditionBookmarksKey] ?: @[];
    // Base first, then additions, in persisted order: the dedupe and the
    // first-contributor base rule rest on it.
    NSMutableArray<NSData *> *bookmarks = [NSMutableArray arrayWithObject:bookmark];
    for (id data in additions) {
        if ([data isKindOfClass:NSData.class]) {
            [bookmarks addObject:data];
        }
        else {
            LogWarn(@"FolderSession: an addition bookmark is not data");
        }
    }
    uint64_t openIntentGeneration = [self beginOpenIntent];
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    dispatch_async(_workQueue, ^{
        if (![self isCurrentOpenIntent:openIntentGeneration]) {
            return;
        }
        // No refresh of a stale bookmark here: minting needs the scope OPEN,
        // and the landing re-persists anyway.
        NSArray<NSURL *> *urls = [self resolveBookmarksConcurrently:bookmarks
                                              openIntentGeneration:openIntentGeneration];
        // Only a restore where NOTHING resolved fails. A dead base's
        // surviving additions restore, the first becoming the base.
        if (urls.count == 0 || ![self isCurrentOpenIntent:openIntentGeneration]) {
            if (urls.count == 0) {
                LogWarn(@"FolderSession: no persisted bookmark resolves");
            }
            run_on_main_thread({
                if ([self isCurrentOpenIntent:openIntentGeneration]) {
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:kAdditionBookmarksKey];
                    [self.delegate folderSessionRestoreDidFail:self];
                }
            });
            return;
        }
        [self openURLsOnWorkQueue:urls appending:NO restored:YES fromSearchRoots:NO
                         sortedBy:sort coveringRootPaths:@[] holds:@[] grants:@[]
             openIntentGeneration:openIntentGeneration];
    });
    return YES;
}

// Answers the URLs that resolved, IN THE ORDER PASSED; a failure, the base
// included, is simply missing, and the landing's rewrite of both keys is the
// pruning. Parallel because a concurrent queue does not parallelize inside
// one block, and resolving in a row cost the sum. It still waits for the
// slowest bookmark, since the walk needs the whole union. The listing and
// minting that follow stay serial on purpose: one order-dependent loop owns
// the dedupe, the base rule and each scope's start-stop pairing.
- (NSArray<NSURL *> *)resolveBookmarksConcurrently:(NSArray<NSData *> *)bookmarks
                              openIntentGeneration:(uint64_t)openIntentGeneration {
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:bookmarks.count];
    for (NSUInteger i = 0; i < bookmarks.count; i++) {
        [slots addObject:NSNull.null];
    }
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.name = @"FolderSession.restore";
    queue.qualityOfService = NSQualityOfServiceUserInitiated;
    queue.maxConcurrentOperationCount = kMaximumConcurrentBookmarkRestorations;
    [bookmarks enumerateObjectsUsingBlock:^(NSData *data, NSUInteger index, BOOL *stop) {
        [queue addOperationWithBlock:^{
            if (![self isCurrentOpenIntent:openIntentGeneration]) {
                return;
            }
            NSError *error = nil;
            NSURL *url = [self resolveBookmark:data error:&error];
            if (!url) {
                LogWarn(@"FolderSession: a bookmark no longer resolves (%@)", error);
                return;
            }
            // Its own slot: completion order must not become playlist order.
            @synchronized (slots) {
                slots[index] = url;
            }
        }];
    }];
    [queue waitUntilAllOperationsAreFinished];
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:slots.count];
    for (id slot in slots) {
        if (slot != NSNull.null) {
            [urls addObject:slot];
        }
    }
    return urls;
}

- (NSString *)persistedTrackKey {
    return [NSUserDefaults.standardUserDefaults stringForKey:kLastTrackPathKey];
}

- (void)setPersistedTrackKey:(NSString *)key {
    if (key) {
        [NSUserDefaults.standardUserDefaults setObject:key forKey:kLastTrackPathKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastTrackPathKey];
    }
}

- (NSURL *)resolveBookmark:(NSData *)bookmark error:(NSError **)error {
    BOOL stale = NO;
    return [NSURL URLByResolvingBookmarkData:bookmark
                                     options:0
                               relativeToURL:nil
                         bookmarkDataIsStale:&stale
                                       error:error];
}

- (NSData *)bookmarkForURL:(NSURL *)url {
    // iOS has no WithSecurityScope option: a default bookmark of a granted
    // URL carries the scope. Requires the scope open, which every caller holds.
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (!bookmark) {
        LogWarn(@"FolderSession: could not bookmark %@ (%@)", url, error);
    }
    return bookmark;
}

// Only this session's own base may be extended: after a search hit, an inbox
// copy or a one-file open over a folder bookmark, it is an earlier playlist's.
- (void)persistAdditionBookmarks:(NSArray<NSData *> *)additionBookmarks {
    if (additionBookmarks.count == 0) {
        return;
    }
    if (!_additionsPersisted) {
        LogInfo(@"FolderSession: addition is session-only — the persisted base is not this session's");
        return;
    }
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kAdditionBookmarksKey] ?: @[];
    [NSUserDefaults.standardUserDefaults setObject:[list arrayByAddingObjectsFromArray:additionBookmarks]
                                            forKey:kAdditionBookmarksKey];
}

// The hold makes this safe off main: a newer open landing releases the
// previous scopes, and a mint under a closed scope fails.
- (void)bookmarkOpenFolderWithCompletion:(void (^)(NSURL *folderURL,
                                                   NSData *bookmark))completion {
    NSURL *folderURL = _folderURL;
    if (!folderURL) {
        completion(nil, nil);
        return;
    }
    // The scoped list, not the search roots: see rootCoveringPath:in:.
    NSURL *scopedURL = [self rootCoveringPath:folderURL.URLByStandardizingPath.path
                                           in:_scopedURLs];
    BOOL scopeHoldStarted = [scopedURL startAccessingSecurityScopedResource];
    dispatch_async(_workQueue, ^{
        NSData *bookmark = [self bookmarkForURL:folderURL];
        if (scopeHoldStarted) {
            [scopedURL stopAccessingSecurityScopedResource];
        }
        run_on_main_thread({
            completion(bookmark ? folderURL : nil, bookmark);
        });
    });
}

// The URL arrives with the browser's grant, so its scope is started directly.
- (void)bookmarkFolderURL:(NSURL *)folderURL
               completion:(void (^)(NSData *bookmark))completion {
    if (!folderURL) {
        completion(nil);
        return;
    }
    // NO is not failure: the app's own container is not security-scoped.
    BOOL scopeHoldStarted = [folderURL startAccessingSecurityScopedResource];
    dispatch_async(_workQueue, ^{
        NSData *bookmark = [self bookmarkForURL:folderURL];
        if (scopeHoldStarted) {
            [folderURL stopAccessingSecurityScopedResource];
        }
        run_on_main_thread({
            completion(bookmark);
        });
    });
}

#pragma mark - Opening

// The one prologue for every URL list. Main thread, no I/O. Each request holds
// each covering scope, so an older worker can finish after a newer result has
// replaced it.
//
// fromSearchRoots: a search hit, whose parent a root in hand already covers.
// It is listed unconditionally and leaves the persisted bookmark alone:
// re-pointing it at a subfolder would shrink next launch's searchable root.
- (void)beginOpenURLs:(NSArray<NSURL *> *)urls
            appending:(BOOL)appending
      fromSearchRoots:(BOOL)fromSearchRoots {
    if (urls.count == 0) {
        return;
    }
    // An Add onto nothing IS an open, including after a failed launch restore.
    // TRAP: only the FIRST such Add may promote. Each promotion bumps the
    // generation, so two promoted Adds cancel each other and a selection
    // vanishes. The rest park as waiters, replayed when it settles.
    BOOL promoting = NO;
    if (appending && _landedOpenIntentGeneration == 0) {
        if (_promotedOpenInFlight) {
            if (!_addWaiters) {
                _addWaiters = [NSMutableArray array];
            }
            NSArray<NSURL *> *parked = [urls copy];
            // Weak: the waiter is stored on self.
            __weak FolderSession *weakSelf = self;
            [_addWaiters addObject:^{
                [weakSelf beginOpenURLs:parked appending:YES fromSearchRoots:fromSearchRoots];
            }];
            return;
        }
        appending = NO;
        promoting = YES;
        _promotedOpenInFlight = YES;
    }
    uint64_t openIntentGeneration = appending
            ? atomic_load_explicit(&_openIntentGeneration, memory_order_acquire)
            : [self beginOpenIntent];
    if (promoting) {
        _promotedOpenIntentGeneration = openIntentGeneration;
    }
    // Snapshotted: an open must not straddle a Settings change.
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    // Every root this request may read under, as paths: one list for reading,
    // while holds and grants stay separate lists for lifetime.
    NSMutableArray<NSString *> *coveringRootPaths = [NSMutableArray array];
    for (NSURL *folder in self.searchRoots) {
        [coveringRootPaths addObject:folder.URLByStandardizingPath.path ?: @""];
    }
    NSMutableArray<NSURL *> *holds = [NSMutableArray array];
    NSMutableArray<SearchFolderGrant *> *grants = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *path = url.URLByStandardizingPath.path;
        // The scoped list, never the search roots (rootCoveringPath:in:);
        // a derived root would also mask the favorites lookup below.
        NSURL *root = [self rootCoveringPath:path in:_scopedURLs];
        SearchFolderGrant *grant = [SearchFolderStore.shared grantCoveringURL:url];
        if (!grant) {
            // A removed Settings row: carry the current playlist's retained
            // grant over rather than revoke it when this result wins.
            for (SearchFolderGrant *held in _searchGrants) {
                if (VibeSearchRootCoversPath(held.rootURL.URLByStandardizingPath.path, path)) {
                    grant = held;
                    break;
                }
            }
        }
        // Inside a STARRED folder: the session takes its own hold, so the
        // playlist stays readable after an unstar.
        if (!root && !grant) {
            root = [FavoritesStore.shared resolvedRootCoveringURL:url];
        }
        // Only a start that returned YES is collected: the worker balances holds.
        if (root && ![holds containsObject:root]
                && [root startAccessingSecurityScopedResource]) {
            [holds addObject:root];
            [coveringRootPaths addObject:root.URLByStandardizingPath.path ?: @""];
        }
        if (grant && ![grants containsObject:grant]) {
            [grants addObject:grant];
            [coveringRootPaths addObject:grant.rootURL.URLByStandardizingPath.path ?: @""];
        }
    }
    dispatch_async(appending ? _appendQueue : _workQueue, ^{
        [self openURLsOnWorkQueue:urls appending:appending restored:NO
                  fromSearchRoots:fromSearchRoots sortedBy:sort
                coveringRootPaths:coveringRootPaths holds:holds grants:grants
             openIntentGeneration:openIntentGeneration];
    });
}

// Answers how many it took, so a caller can tell "contributed nothing". Keyed
// by what sounds: rows of one file are distinct, a file twice is not.
- (NSUInteger)appendFresh:(NSArray<AudioTrack *> *)rows
                       to:(NSMutableArray<AudioTrack *> *)tracks
                     seen:(NSMutableSet<NSString *> *)seenKeys {
    NSUInteger taken = 0;
    for (AudioTrack *row in rows) {
        NSString *key = row.standardizedSourceKey;
        if (key && ![seenKeys containsObject:key]) {
            [seenKeys addObject:key];
            [tracks addObject:row];
            taken++;
        }
    }
    return taken;
}

- (void)openURLsOnWorkQueue:(NSArray<NSURL *> *)urls
                  appending:(BOOL)appending
                   restored:(BOOL)restored
            fromSearchRoots:(BOOL)fromSearchRoots
                   sortedBy:(VibeFolderOpenSort)sort
          coveringRootPaths:(NSArray<NSString *> *)coveringRootPaths
                      holds:(NSArray<NSURL *> *)holds
                     grants:(NSArray<SearchFolderGrant *> *)grants
       openIntentGeneration:(uint64_t)openIntentGeneration {
    if (![self isCurrentOpenIntent:openIntentGeneration]) {
        for (NSURL *hold in holds) {
            [hold stopAccessingSecurityScopedResource];
        }
        return;
    }
    NSMutableArray<AudioTrack *> *tracks = [NSMutableArray array];
    // One delivery names each row once. A restore's list can overlap and is
    // delivered as a REPLACE, which does not dedupe: without this, every
    // relaunch grows a copy of each re-added folder.
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    NSMutableArray<NSURL *> *ownedScopes = [NSMutableArray array];
    NSMutableArray<NSURL *> *addedFolders = [NSMutableArray array];
    // The URLs that produced tracks, in pick order. Bookmarks are minted from
    // these, never from urls, so a folder with no audio persists nothing.
    NSMutableArray<NSURL *> *contributors = [NSMutableArray array];
    NSURL *folderURL = nil;
    NSURL *selectedURL = nil;
    BOOL expands = !appending && urls.count == 1;
    // Resolved lazily and at most once: a resolve is provider IPC, and a
    // folder open never needs it.
    __block BOOL persistedBaseResolved = NO;
    __block NSURL *persistedBase = nil;
    NSURL *(^resolvePersistedBase)(void) = ^NSURL *{
        if (!persistedBaseResolved) {
            persistedBaseResolved = YES;
            NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
            persistedBase = data ? [self resolveBookmark:data error:NULL] : nil;
        }
        return persistedBase;
    };

    for (NSURL *url in urls) {
        // NO is not failure: the app's own container is not security-scoped.
        BOOL started = [url startAccessingSecurityScopedResource];
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        // The key is absent for a URL the provider has not resolved yet. An
        // explicit nil test: the analyzer flags an NSNumber * used as a BOOL.
        BOOL isDir = isDirectory != nil ? isDirectory.boolValue : url.hasDirectoryPath;

        // A file grant reaches only the file, but a folder in hand may cover
        // it; then the file expands to its directory, selected. Otherwise it
        // is a one-track playlist.
        if (!isDir && expands) {
            NSURL *parent = url.URLByDeletingLastPathComponent;
            NSString *parentPath = parent.URLByStandardizingPath.path;
            NSURL *bookmarkRoot = nil;
            BOOL bookmarkScopeStarted = NO;
            BOOL listable = fromSearchRoots
                    || VibeSearchFolderCoveringRootIndex(coveringRootPaths, parentPath) != NSNotFound;
            if (!listable) {
                // A cold "Open in Vibe" arrives before any restore ran.
                NSURL *candidate = resolvePersistedBase();
                if (candidate && VibeSearchRootCoversPath(
                        candidate.URLByStandardizingPath.path, parentPath)) {
                    bookmarkScopeStarted = [candidate startAccessingSecurityScopedResource];
                    bookmarkRoot = candidate;
                    listable = YES;
                }
            }
            if (listable) {
                if ([self appendFresh:[NSURLUtil rowsInDirectory:parent sortedBy:sort]
                                   to:tracks
                                 seen:seenKeys] > 0) {
                    if (started) {
                        [url stopAccessingSecurityScopedResource];   // the root covers it
                    }
                    if (bookmarkScopeStarted) {
                        [ownedScopes addObject:bookmarkRoot];
                    }
                    folderURL = parent;
                    selectedURL = url;
                    [contributors addObject:parent];
                    continue;
                }
                if (bookmarkScopeStarted) {
                    [bookmarkRoot stopAccessingSecurityScopedResource];
                }
            }
        }

        // A URL that added nothing is not persisted: that prunes a redundant
        // addition.
        NSArray<AudioTrack *> *produced = isDir ? [NSURLUtil rowsInDirectory:url sortedBy:sort]
                                                : [NSURLUtil rowsForFile:url];
        if ([self appendFresh:produced to:tracks seen:seenKeys] == 0) {
            if (started) {
                [url stopAccessingSecurityScopedResource];
            }
            continue;
        }
        if (started) {
            [ownedScopes addObject:url];
        }
        [contributors addObject:url];
        if (isDir) {
            // TRAP: the base is the FIRST contributor, even a file. A restore
            // delivers base-then-additions, so a folder behind a file base
            // that claimed the base would rewrite the base bookmark and
            // reorder the union at the next relaunch.
            if (!appending && contributors.count == 1) {
                folderURL = url;
            }
            else {
                [addedFolders addObject:url];
            }
        }
    }

    if (tracks.count == 0) {
        for (NSURL *hold in holds) {
            [hold stopAccessingSecurityScopedResource];
        }
        for (NSURL *owned in ownedScopes) {
            [owned stopAccessingSecurityScopedResource];
        }
        // Still settles (finishOpenIntent:).
        run_on_main_thread({
            [self finishOpenIntent:openIntentGeneration appending:appending tracks:@[]
                         folderURL:nil addedFolders:@[] selectedURL:nil restored:restored
                       ownedScopes:@[] ownedGrants:@[] baseBookmark:nil additionBookmarks:@[]];
        });
        return;
    }

    // A hold covering no contributor is released; the rest are adopted.
    // Contributors, not tracks: the listing is flat, so covering a contributor
    // is covering its tracks, and there are far fewer of them.
    NSMutableArray<NSString *> *contributorPaths = [NSMutableArray arrayWithCapacity:contributors.count];
    for (NSURL *contributor in contributors) {
        [contributorPaths addObject:contributor.URLByStandardizingPath.path ?: @""];
    }
    for (NSURL *hold in holds) {
        NSString *holdPath = hold.URLByStandardizingPath.path;
        BOOL covers = NO;
        for (NSString *contributorPath in contributorPaths) {
            if (VibeSearchRootCoversPath(holdPath, contributorPath)) {
                covers = YES;
                break;
            }
        }
        if (covers) {
            [ownedScopes addObject:hold];
        }
        else {
            [hold stopAccessingSecurityScopedResource];
        }
    }

    // Minting needs the scope OPEN, so it runs before any release.
    NSData *baseBookmark = nil;
    NSMutableArray<NSData *> *additionBookmarks = [NSMutableArray array];
    NSURL *base = appending ? nil : (folderURL ?: contributors.firstObject);
    if ([self isCurrentOpenIntent:openIntentGeneration]) {
        // A one-file open never replaces a folder bookmark, whose broader
        // grant powers expansion and restore. An open that brought any folder
        // in is not that case, whatever its base.
        BOOL openedNoFolder = !folderURL && addedFolders.count == 0;
        BOOL persistedBaseIsFolder = NO;
        if (base && !fromSearchRoots && openedNoFolder) {
            NSNumber *isDirectory = nil;
            [resolvePersistedBase() getResourceValue:&isDirectory
                                              forKey:NSURLIsDirectoryKey
                                               error:NULL];
            persistedBaseIsFolder = isDirectory.boolValue;
        }
        if (base && !fromSearchRoots && (!openedNoFolder || !persistedBaseIsFolder)) {
            baseBookmark = [self bookmarkForURL:base];
        }
        if (appending || baseBookmark) {
            for (NSURL *contributor in contributors) {
                NSData *bookmark = contributor == base ? nil : [self bookmarkForURL:contributor];
                if (bookmark) {
                    [additionBookmarks addObject:bookmark];
                }
            }
        }
    }

    run_on_main_thread({
        [self finishOpenIntent:openIntentGeneration appending:appending tracks:tracks
                     folderURL:folderURL addedFolders:addedFolders selectedURL:selectedURL
                      restored:restored ownedScopes:ownedScopes ownedGrants:grants
                  baseBookmark:baseBookmark additionBookmarks:additionBookmarks];
    });
}

// Main thread; the one place session state and bookmarks move. Every request
// ends here, an empty one included; a stale one only releases its scopes.
- (void)finishOpenIntent:(uint64_t)openIntentGeneration
               appending:(BOOL)appending
                  tracks:(NSArray<AudioTrack *> *)tracks
               folderURL:(NSURL *)folderURL
            addedFolders:(NSArray<NSURL *> *)addedFolders
             selectedURL:(NSURL *)selectedURL
                restored:(BOOL)restored
             ownedScopes:(NSArray<NSURL *> *)ownedScopes
             ownedGrants:(NSArray<SearchFolderGrant *> *)ownedGrants
            baseBookmark:(NSData *)baseBookmark
       additionBookmarks:(NSArray<NSData *> *)additionBookmarks {
    BOOL current = [self isCurrentOpenIntent:openIntentGeneration];
    if (current && appending && _landedOpenIntentGeneration != openIntentGeneration) {
        LogWarn(@"FolderSession: dropping an append whose open never landed");
        current = NO;
    }
    if (!current) {
        for (NSURL *url in ownedScopes) {
            [url stopAccessingSecurityScopedResource];
        }
        return;
    }
    if (tracks.count == 0) {
        // TRAP: an empty open still SETTLES its generation: the playlist left
        // standing answers for it. Without the carry, every later Add is
        // captured at a generation nothing landed and Add is dead for the
        // session. Zero stays zero, so an Add is still promoted, and an append
        // carries nothing.
        if (!appending && _landedOpenIntentGeneration != 0) {
            _landedOpenIntentGeneration = openIntentGeneration;
        }
        if (appending) {
            LogInfo(@"FolderSession: nothing to append");
        }
        else if (restored) {
            [self.delegate folderSessionRestoreDidFail:self];
        }
        else {
            [self.delegate folderSessionDidOpenEmptyFolder:self];
        }
        // Replayed, not left hanging; the first promotes in its turn.
        if (!appending) {
            [self releaseAddWaitersAfterSettle];
        }
        return;
    }
    // A restore is not a user open; counted, every cold start adds a folder.
    if (!restored) {
        [[AppStats sharedInstance] recordOpenedFiles:tracks.count
                                             folders:(folderURL ? 1 : 0) + addedFolders.count];
    }
    if (appending) {
        [_scopedURLs addObjectsFromArray:ownedScopes];
        [_searchGrants addObjectsFromArray:ownedGrants];
        // A folder already covered adds no search root, or a twice-added
        // favorite is walked twice. Reach, not lifetime, so the SEARCH ROOTS
        // answer; its scope is still adopted above.
        for (NSURL *folder in addedFolders) {
            if (![self rootCoveringPath:folder.URLByStandardizingPath.path
                                     in:self.searchRoots]) {
                [_addedFolderURLs addObject:folder];
            }
        }
        [self persistAdditionBookmarks:additionBookmarks];
        [self.delegate folderSession:self didAppendTracks:tracks];
        return;
    }
    // TRAP: acquire before release. The previous set is stopped only here,
    // after the successor is installed, so a failed or superseded pick never
    // strands the current playlist unreadable. A URL may sit in both sets,
    // started once for each.
    NSArray<NSURL *> *previous = _scopedURLs;
    _scopedURLs = [ownedScopes mutableCopy];
    _searchGrants = [ownedGrants mutableCopy];
    _folderURL = folderURL;
    _addedFolderURLs = [addedFolders mutableCopy];
    _landedOpenIntentGeneration = openIntentGeneration;
    _additionsPersisted = baseBookmark != nil;
    if (baseBookmark) {
        [NSUserDefaults.standardUserDefaults setObject:baseBookmark forKey:kFolderBookmarkKey];
        if (additionBookmarks.count > 0) {
            [NSUserDefaults.standardUserDefaults setObject:additionBookmarks
                                                    forKey:kAdditionBookmarksKey];
        }
        else {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kAdditionBookmarksKey];
        }
    }
    for (NSURL *url in previous) {
        [url stopAccessingSecurityScopedResource];
    }
    [self.delegate folderSession:self didOpenTracks:tracks folderURL:folderURL
                     selectedURL:selectedURL restored:restored];
    // Last, so a replayed Add appends to this landing's playlist.
    [self releaseAddWaitersAfterSettle];
}

// For any REPLACE settling, which also releases the waiters of a promoted open
// a user's replace superseded. Each replays through the prologue, which
// decides afresh; drained first, so a waiter that parks again parks behind
// the new promotion.
- (void)releaseAddWaitersAfterSettle {
    _promotedOpenInFlight = NO;
    NSArray<void (^)(void)> *waiters = _addWaiters;
    _addWaiters = nil;
    for (void (^waiter)(void) in waiters) {
        waiter();
    }
}

@end
