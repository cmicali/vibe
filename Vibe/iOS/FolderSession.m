//
//  FolderSession.m
//  Vibe (iOS)
//

#import "FolderSessionInternal.h"
#import "AppSettings.h"
#import "AppStats.h"
#import "AudioTrack.h"
#import "DropboxMirror.h"
#import "FavoritesStore.h"
#import "FileSearchRules.h"
#import "FolderSessionRules.h"
#import "LinkStore.h"
#import "LocationStoreInternal.h"
#import "FilePaths.h"
#import "FolderWalk.h"
#import "PlaylistFile.h"
#import "RecentsStore.h"
#import <stdatomic.h>

// Past this many contributors an open is ONE recent, the folder they share.
static const NSUInteger kMaximumRecentItemsPerOpen = 5;
// An open waits this long for Dropbox to list a folder before reading what
// the disk has.
static const NSTimeInterval kDropboxListingTimeout = 20;

// One open on the work queue, handed from phase to phase. The request is set
// before the first phase. Each phase fills in what the next one reads.
@interface FolderSessionOpen : NSObject
@property (nonatomic) NSArray<NSURL *> *urls;
@property (nonatomic) BOOL appending;
@property (nonatomic) BOOL restored;
@property (nonatomic) BOOL keepsSessionBookmark;
@property (nonatomic) BOOL expandsFile;
@property (nonatomic) VibeFolderOpenSort sort;
@property (nonatomic) NSArray<NSString *> *coveringRootPaths;
@property (nonatomic, copy) NSURL *(^resolvePersistedBase)(void);
// resolveRowsOfOpen:
@property (nonatomic, readonly) NSMutableArray<AudioTrack *> *tracks;
@property (nonatomic, readonly) NSMutableArray<NSURL *> *ownedScopes;
@property (nonatomic, readonly) NSMutableArray<NSURL *> *addedFolders;
@property (nonatomic, readonly) NSMutableArray<NSURL *> *contributors;
@property (nonatomic) NSURL *folderURL;
@property (nonatomic) NSURL *selectedURL;
@property (nonatomic) NSURL *deniedSheetURL;
// mintBookmarksOfOpen:
@property (nonatomic) NSData *baseBookmark;
@property (nonatomic, readonly) NSMutableArray<NSData *> *additionBookmarks;
@property (nonatomic, readonly) NSMutableDictionary<NSURL *, NSData *> *minted;
@end

@implementation FolderSessionOpen

- (instancetype)init {
    self = [super init];
    if (self) {
        _tracks = [NSMutableArray array];
        _ownedScopes = [NSMutableArray array];
        _addedFolders = [NSMutableArray array];
        _contributors = [NSMutableArray array];
        _additionBookmarks = [NSMutableArray array];
        _minted = [NSMutableDictionary dictionary];
    }
    return self;
}

@end

@implementation FolderSession

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
    return _folderURL ? [LocationStore displayNameForFolderURL:_folderURL] : nil;
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
        if (VibeSearchRootCoversPath(VibeComparablePath(root.path), path)) {
            return root;
        }
    }
    return nil;
}

#pragma mark - Opening

// The one prologue for every URL list. Main thread, no I/O. Each request holds
// each covering scope, so an older worker can finish after a newer result has
// replaced it.
//
// An open strictly inside a grant only this session holds — a one-off pick,
// which nothing else persists — leaves the session bookmark alone:
// re-pointing it at a subfolder would shrink next launch's reach to the
// subfolder. Under a Location, a favorite or the app's own trees the grant
// persists by itself, so the open is remembered like any other.
// expandsFile: one file opened alone becomes its directory with it selected,
// where a root covers that; NO keeps it a one-track playlist. grantedFolder:
// a folder the user just granted for a sheet's audio, held like a starred
// folder's root.
- (void)beginOpenURLs:(NSArray<NSURL *> *)urls
            appending:(BOOL)appending
          expandsFile:(BOOL)expandsFile
        grantedFolder:(NSURL *)grantedFolder {
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
                [weakSelf beginOpenURLs:parked appending:YES expandsFile:NO grantedFolder:grantedFolder];
            }];
            return;
        }
        appending = NO;
        expandsFile = YES;
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
        [coveringRootPaths addObject:VibeComparablePath(folder.path) ?: @""];
    }
    // The app's own trees need no grant, so a file picked in one always
    // reaches its folder: Documents, and the Dropbox mirror.
    NSString *documents = VibeComparablePath(LocationStore.containerDocumentsURL.path);
    NSString *dropbox = VibeComparablePath(DropboxMirror.shared.accountURL.path);
    if (documents) {
        [coveringRootPaths addObject:documents];
    }
    if (dropbox) {
        [coveringRootPaths addObject:dropbox];
    }
    NSMutableArray<NSURL *> *holds = [NSMutableArray array];
    NSMutableArray<LocationGrant *> *grants = [NSMutableArray array];
    BOOL keepsSessionBookmark = NO;
    for (NSURL *url in urls) {
        NSString *path = VibeComparablePath(url.path);
        // The scoped list, never the search roots (rootCoveringPath:in:);
        // a derived root would also mask the favorites lookup below.
        NSURL *root = [self rootCoveringPath:path in:_scopedURLs];
        NSURL *sessionRoot = root;
        LocationGrant *grant = [LocationStore.shared grantCoveringURL:url];
        if (!grant) {
            // A removed Settings row: carry the current playlist's retained
            // grant over rather than revoke it when this result wins.
            for (LocationGrant *held in _searchGrants) {
                if (VibeSearchRootCoversPath(VibeComparablePath(held.rootURL.path), path)) {
                    grant = held;
                    break;
                }
            }
        }
        // Inside a STARRED folder: the session takes its own hold, so the
        // playlist stays readable after an unstar.
        NSURL *favoriteRoot = grant ? nil : [FavoritesStore.shared resolvedRootCoveringURL:url];
        if (!root) {
            root = favoriteRoot;
        }
        if (!root && grantedFolder
                && VibeSearchRootCoversPath(VibeComparablePath(grantedFolder.path), path)) {
            root = grantedFolder;
        }
        if (sessionRoot && !grant && !favoriteRoot
                && ![VibeComparablePath(sessionRoot.path) isEqualToString:path]) {
            keepsSessionBookmark = YES;
        }
        // Only a start that returned YES is collected: the worker balances holds.
        if (root && ![holds containsObject:root]
                && [root startAccessingSecurityScopedResource]) {
            [holds addObject:root];
            [coveringRootPaths addObject:VibeComparablePath(root.path) ?: @""];
        }
        if (grant && ![grants containsObject:grant]) {
            [grants addObject:grant];
            [coveringRootPaths addObject:VibeComparablePath(grant.rootURL.path) ?: @""];
        }
    }
    dispatch_async(appending ? _appendQueue : _workQueue, ^{
        [self openURLsOnWorkQueue:urls appending:appending restored:NO
                  keepsSessionBookmark:keepsSessionBookmark expandsFile:expandsFile sortedBy:sort
                coveringRootPaths:coveringRootPaths holds:holds grants:grants
             openIntentGeneration:openIntentGeneration];
    });
}

// Work queue. A Dropbox folder nothing has listed yet is listed from Dropbox
// before it is read: the mirror holds only what something has listed, so a
// folder played or added from its parent's listing, never browsed into, was
// empty on disk and the open landed nothing. One already listed is read as it
// is — the browser relists it when shown — so a restore never waits on the
// network. Bounded, so an open offline still reads the disk.
- (void)listFromDropboxIfMirrored:(NSURL *)url {
    DropboxMirror *mirror = DropboxMirror.shared;
    NSString *dropboxPath = [mirror dropboxPathForURL:url];
    if (!dropboxPath || [mirror hasListedDirectory:url]) {
        return;
    }
    dispatch_semaphore_t listed = dispatch_semaphore_create(0);
    [DropboxMirror.shared refreshDropboxFolder:dropboxPath completion:^(NSURL *folderURL, NSError *error) {
        if (error) {
            LogWarn(@"FolderSession: could not list %@ from Dropbox: %@", url.lastPathComponent,
                    error.localizedDescription);
        }
        dispatch_semaphore_signal(listed);
    }];
    dispatch_semaphore_wait(listed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDropboxListingTimeout * NSEC_PER_SEC)));
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

// Work queue. Each phase hands the next its result through open: the rows,
// then the holds adopted, then the bookmarks, then the recents.
- (void)openURLsOnWorkQueue:(NSArray<NSURL *> *)urls
                  appending:(BOOL)appending
                   restored:(BOOL)restored
       keepsSessionBookmark:(BOOL)keepsSessionBookmark
                expandsFile:(BOOL)expandsFile
                   sortedBy:(VibeFolderOpenSort)sort
          coveringRootPaths:(NSArray<NSString *> *)coveringRootPaths
                      holds:(NSArray<NSURL *> *)holds
                     grants:(NSArray<LocationGrant *> *)grants
       openIntentGeneration:(uint64_t)openIntentGeneration {
    if (![self isCurrentOpenIntent:openIntentGeneration]) {
        for (NSURL *hold in holds) {
            [hold stopAccessingSecurityScopedResource];
        }
        return;
    }
    FolderSessionOpen *open = [[FolderSessionOpen alloc] init];
    open.urls = urls;
    open.appending = appending;
    open.restored = restored;
    open.keepsSessionBookmark = keepsSessionBookmark;
    open.expandsFile = expandsFile;
    open.sort = sort;
    open.coveringRootPaths = coveringRootPaths;
    // Resolved lazily and at most once: a resolve is provider IPC, and a
    // folder open never needs it.
    __block BOOL persistedBaseResolved = NO;
    __block NSURL *persistedBase = nil;
    open.resolvePersistedBase = ^NSURL *{
        if (!persistedBaseResolved) {
            persistedBaseResolved = YES;
            NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
            persistedBase = data ? [self resolveBookmark:data error:NULL] : nil;
        }
        return persistedBase;
    };
    [self resolveRowsOfOpen:open];

    if (open.tracks.count == 0) {
        for (NSURL *hold in holds) {
            [hold stopAccessingSecurityScopedResource];
        }
        for (NSURL *owned in open.ownedScopes) {
            [owned stopAccessingSecurityScopedResource];
        }
        NSURL *deniedSheetURL = open.deniedSheetURL;
        // Still settles (finishOpenIntent:), and only then asks.
        run_on_main_thread({
            if ([self finishOpenIntent:openIntentGeneration appending:appending tracks:@[]
                             folderURL:nil addedFolders:@[] selectedURL:nil restored:restored
                           ownedScopes:@[] ownedGrants:@[] baseBookmark:nil additionBookmarks:@[]]
                    && deniedSheetURL) {
                [self.delegate folderSession:self needsFolderOfSheetAtURL:deniedSheetURL
                                   appending:appending];
            }
        });
        return;
    }

    [self adoptHolds:holds coveringContributorsOfOpen:open];

    // Minting needs the scope OPEN, so it runs before any release.
    if ([self isCurrentOpenIntent:openIntentGeneration]) {
        [self mintBookmarksOfOpen:open];
        if (!restored) {
            [self recordRecentsOfOpen:open];
        }
    }

    run_on_main_thread({
        [self finishOpenIntent:openIntentGeneration appending:appending tracks:open.tracks
                     folderURL:open.folderURL addedFolders:open.addedFolders selectedURL:open.selectedURL
                      restored:restored ownedScopes:open.ownedScopes ownedGrants:grants
                  baseBookmark:open.baseBookmark additionBookmarks:open.additionBookmarks];
    });
}

// Work queue. Lists every picked URL into open.tracks, and records which URLs
// contributed and which scopes the rows need.
- (void)resolveRowsOfOpen:(FolderSessionOpen *)open {
    NSArray<NSURL *> *urls = open.urls;
    BOOL appending = open.appending;
    BOOL restored = open.restored;
    VibeFolderOpenSort sort = open.sort;
    BOOL expandsFile = open.expandsFile;
    NSArray<NSString *> *coveringRootPaths = open.coveringRootPaths;
    NSURL *(^resolvePersistedBase)(void) = open.resolvePersistedBase;
    NSMutableArray<AudioTrack *> *tracks = open.tracks;
    // One delivery names each row once. A restore's list can overlap and is
    // delivered as a REPLACE, which does not dedupe: without this, every
    // relaunch grows a copy of each re-added folder.
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    NSMutableArray<NSURL *> *ownedScopes = open.ownedScopes;
    NSMutableArray<NSURL *> *addedFolders = open.addedFolders;
    // The URLs that produced tracks, in pick order. Bookmarks are minted from
    // these, never from urls, so a folder with no audio persists nothing.
    NSMutableArray<NSURL *> *contributors = open.contributors;
    NSURL *folderURL = nil;
    NSURL *selectedURL = nil;
    // The first picked sheet that found nothing because its folder is
    // denied: reported once the empty open settles, so the user can grant it.
    NSURL *deniedSheetURL = nil;
    BOOL expands = expandsFile && urls.count == 1;
    // A recent FOLDER's bookmark is the grant for a one-off pick the browser
    // reached again through Recents: the browser holds that root only while
    // its screen is up, and the session's own hold went with the playlist,
    // so an open inside it takes a hold of its own from the recent, as from
    // the persisted base. Resolved at most once per recent: provider IPC.
    NSMutableDictionary<NSString *, NSURL *> *recentRoots = [NSMutableDictionary dictionary];
    NSURL *(^resolveRecentRootCovering)(NSString *) = ^NSURL *(NSString *coveredPath) {
        for (NSDictionary *item in RecentsStore.shared.recentItems) {
            NSString *recentPath = item[@"path"];
            NSData *bookmark = item[@"bookmark"];
            if (![item[@"folder"] boolValue] || ![recentPath isKindOfClass:NSString.class]
                    || ![bookmark isKindOfClass:NSData.class]
                    || !VibeSearchRootCoversPath(recentPath, coveredPath)) {
                continue;
            }
            NSURL *root = recentRoots[recentPath];
            if (!root) {
                root = [self resolveBookmark:bookmark error:NULL];
                recentRoots[recentPath] = root ?: (NSURL *)NSNull.null;
            }
            if ([root isKindOfClass:NSURL.class]
                    && VibeSearchRootCoversPath(VibeComparablePath(root.path), coveredPath)) {
                return root;
            }
        }
        return nil;
    };

    for (NSURL *url in urls) {
        // NO is not failure: the app's own container is not security-scoped.
        BOOL started = [url startAccessingSecurityScopedResource];
        // What the start above holds — the URL, or the recent root covering
        // a derived URL nothing else covers; the stop and the owned scope
        // are its.
        NSURL *held = url;
        if (!started) {
            NSString *path = VibeComparablePath(url.path);
            if (VibeSearchFolderCoveringRootIndex(coveringRootPaths, path) == NSNotFound) {
                NSURL *recentRoot = resolveRecentRootCovering(path);
                if (recentRoot && [recentRoot startAccessingSecurityScopedResource]) {
                    held = recentRoot;
                    started = YES;
                }
            }
        }
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        // The key is absent for a URL the provider has not resolved yet. An
        // explicit nil test: the analyzer flags an NSNumber * used as a BOOL.
        BOOL isDir = isDirectory != nil ? isDirectory.boolValue : url.hasDirectoryPath;

        // A file grant reaches only the file, but a folder in hand may cover
        // it; then the file expands to its directory, selected. Otherwise it
        // is a one-track playlist. An M3U is its own entries, never a row of
        // its folder.
        BOOL m3u = !isDir && [PlaylistFile isM3UExtension:url.pathExtension.lowercaseString];
        if (!isDir && expands && !m3u) {
            NSURL *parent = url.URLByDeletingLastPathComponent;
            NSString *parentPath = VibeComparablePath(parent.path);
            NSURL *bookmarkRoot = nil;
            BOOL bookmarkScopeStarted = NO;
            BOOL listable = VibeSearchFolderCoveringRootIndex(coveringRootPaths, parentPath) != NSNotFound;
            if (!listable) {
                // A cold "Open in Vibe" arrives before any restore ran.
                NSURL *candidate = resolvePersistedBase();
                if (!(candidate && VibeSearchRootCoversPath(
                        VibeComparablePath(candidate.path), parentPath))) {
                    candidate = resolveRecentRootCovering(parentPath);
                }
                if (candidate) {
                    bookmarkScopeStarted = [candidate startAccessingSecurityScopedResource];
                    bookmarkRoot = candidate;
                    listable = YES;
                }
            }
            if (listable) {
                [self listFromDropboxIfMirrored:parent];
                if ([self appendFresh:[FolderWalk rowsInDirectory:parent sortedBy:sort]
                                   to:tracks
                                 seen:seenKeys] > 0) {
                    if (started) {
                        [held stopAccessingSecurityScopedResource];   // the root covers it
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
        if (isDir) {
            [self listFromDropboxIfMirrored:url];
        }
        else if (m3u && [DropboxMirror.shared dropboxPathForURL:url]) {
            // Each folder the playlist names, as the mirror holds only what
            // something has listed.
            NSMutableOrderedSet<NSURL *> *entryFolders = [NSMutableOrderedSet orderedSet];
            for (AudioTrack *row in [PlaylistFile rowsForPlaylistAtURL:url]) {
                [entryFolders addObject:row.url.URLByDeletingLastPathComponent];
            }
            for (NSURL *folder in entryFolders) {
                [self listFromDropboxIfMirrored:folder];
            }
        }
        NSArray<AudioTrack *> *produced = isDir ? [FolderWalk rowsInDirectory:url sortedBy:sort]
                                                : [FolderWalk rowsForFile:url];
        if ([self appendFresh:produced to:tracks seen:seenKeys] == 0) {
            if (started) {
                [held stopAccessingSecurityScopedResource];
            }
            if (!isDir && !restored && !deniedSheetURL && produced.count == 0
                    && [PlaylistFile isCueExtension:url.pathExtension.lowercaseString]
                    && [FolderWalk isReadDenied:url.URLByDeletingLastPathComponent]) {
                deniedSheetURL = url;
            }
            continue;
        }
        if (started) {
            [ownedScopes addObject:held];
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

    open.folderURL = folderURL;
    open.selectedURL = selectedURL;
    open.deniedSheetURL = deniedSheetURL;
}

// Work queue. A hold covering no contributor is released; the rest are
// adopted into open.ownedScopes.
// Contributors, not tracks: the listing is flat, so covering a contributor
// is covering its tracks, and there are far fewer of them.
- (void)adoptHolds:(NSArray<NSURL *> *)holds coveringContributorsOfOpen:(FolderSessionOpen *)open {
    NSArray<NSURL *> *contributors = open.contributors;
    NSMutableArray<NSURL *> *ownedScopes = open.ownedScopes;
    NSMutableArray<NSString *> *contributorPaths = [NSMutableArray arrayWithCapacity:contributors.count];
    for (NSURL *contributor in contributors) {
        [contributorPaths addObject:VibeComparablePath(contributor.path) ?: @""];
    }
    for (NSURL *hold in holds) {
        NSString *holdPath = VibeComparablePath(hold.path);
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
}

// Work queue, under every scope the open owns. Mints the base bookmark and the
// addition bookmarks; finishOpenIntent: persists them.
- (void)mintBookmarksOfOpen:(FolderSessionOpen *)open {
    BOOL appending = open.appending;
    BOOL keepsSessionBookmark = open.keepsSessionBookmark;
    NSURL *(^resolvePersistedBase)(void) = open.resolvePersistedBase;
    NSURL *folderURL = open.folderURL;
    NSArray<NSURL *> *addedFolders = open.addedFolders;
    NSArray<NSURL *> *contributors = open.contributors;
    NSData *baseBookmark = nil;
    NSMutableArray<NSData *> *additionBookmarks = open.additionBookmarks;
    NSURL *base = appending ? nil : (folderURL ?: contributors.firstObject);
    // An open that brought any folder in persists, whatever its base. So
    // does a link opened alone: it restores from its placeholder, offline
    // too (VibeFolderSessionPersistsBase).
    BOOL openedFolder = folderURL || addedFolders.count > 0;
    BOOL baseIsLink = base && [LinkStore.shared containsURL:base];
    BOOL persistedBaseIsFolder = NO;
    if (base && !keepsSessionBookmark && !openedFolder && !baseIsLink) {
        NSNumber *isDirectory = nil;
        [resolvePersistedBase() getResourceValue:&isDirectory
                                          forKey:NSURLIsDirectoryKey
                                           error:NULL];
        persistedBaseIsFolder = isDirectory.boolValue;
    }
    // Each mint is provider IPC, so the recents reuse these.
    NSMutableDictionary<NSURL *, NSData *> *minted = open.minted;
    if (base && VibeFolderSessionPersistsBase(keepsSessionBookmark, openedFolder, persistedBaseIsFolder,
                                              baseIsLink)) {
        baseBookmark = [self bookmarkForURL:base];
        minted[base] = baseBookmark;
    }
    if (appending || baseBookmark) {
        for (NSURL *contributor in contributors) {
            NSData *bookmark = contributor == base ? nil : [self bookmarkForURL:contributor];
            if (bookmark) {
                [additionBookmarks addObject:bookmark];
                minted[contributor] = bookmark;
            }
        }
    }
    open.baseBookmark = baseBookmark;
}

// Work queue; the record itself lands on main. Reuses the bookmarks
// mintBookmarksOfOpen: made.
- (void)recordRecentsOfOpen:(FolderSessionOpen *)open {
    NSURL *folderURL = open.folderURL;
    NSArray<NSURL *> *addedFolders = open.addedFolders;
    NSArray<NSURL *> *contributors = open.contributors;
    NSURL *selectedURL = open.selectedURL;
    NSArray<NSString *> *coveringRootPaths = open.coveringRootPaths;
    NSDictionary<NSURL *, NSData *> *minted = open.minted;
    // The picked URLs that produced tracks; a file that expanded is
    // still the file, and only a lone file expands.
    NSArray<NSURL *> *opened = selectedURL ? @[selectedURL] : contributors;
    // Play with Subfolders, or a long multi-select: recorded each, a
    // library of two hundred albums replaced the whole list in one
    // tap. It is one entry — the folder they share, when a root in
    // hand covers it, else the first of them.
    NSURL *shared = nil;
    if (opened.count > kMaximumRecentItemsPerOpen) {
        NSArray<NSString *> *common = nil;
        for (NSURL *url in opened) {
            BOOL isFolder = url == folderURL || [addedFolders containsObject:url];
            NSArray<NSString *> *components =
                    (isFolder ? url : url.URLByDeletingLastPathComponent).URLByStandardizingPath.pathComponents;
            NSUInteger length = 0;
            while (common && length < common.count && length < components.count
                    && [common[length] isEqualToString:components[length]]) {
                length++;
            }
            common = common ? [common subarrayWithRange:NSMakeRange(0, length)] : components;
        }
        NSString *sharedPath = [NSString pathWithComponents:common ?: @[]];
        if (VibeSearchFolderCoveringRootIndex(coveringRootPaths, sharedPath) != NSNotFound) {
            shared = [NSURL fileURLWithPath:sharedPath isDirectory:YES];
        }
        opened = @[shared ?: opened.firstObject];
    }
    NSMutableArray<NSMutableDictionary *> *recents = [NSMutableArray arrayWithCapacity:opened.count];
    // A link's host, read here off main: a link is named by it.
    NSMutableArray *linkHosts = [NSMutableArray arrayWithCapacity:opened.count];
    for (NSURL *url in opened) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"path"] = VibeComparablePath(url.path);
        item[@"bookmark"] = minted[url] ?: [self bookmarkForURL:url];
        item[@"folder"] = @(url == shared || url == folderURL || [addedFolders containsObject:url]);
        [recents addObject:item];
        [linkHosts addObject:[LinkStore.shared hostOfLinkFileURL:url] ?: NSNull.null];
    }
    run_on_main_thread({
        // On main: the name asks the Dropbox mirror and UIDevice.
        // Recorded, not derived at draw time: the path can outlive
        // the app container it names.
        [recents enumerateObjectsUsingBlock:^(NSMutableDictionary *item, NSUInteger index, BOOL *stop) {
            NSString *parent = [item[@"path"] stringByDeletingLastPathComponent];
            id host = linkHosts[index];
            item[@"location"] = host != NSNull.null
                    ? host : [LocationStore displayNameForFolderURL:[NSURL fileURLWithPath:parent isDirectory:YES]];
        }];
        [RecentsStore.shared recordRecentItems:recents];
    });
}

// Main thread; the one place session state and bookmarks move. Every request
// ends here, an empty one included; a stale one only releases its scopes and
// answers NO.
- (BOOL)finishOpenIntent:(uint64_t)openIntentGeneration
               appending:(BOOL)appending
                  tracks:(NSArray<AudioTrack *> *)tracks
               folderURL:(NSURL *)folderURL
            addedFolders:(NSArray<NSURL *> *)addedFolders
             selectedURL:(NSURL *)selectedURL
                restored:(BOOL)restored
             ownedScopes:(NSArray<NSURL *> *)ownedScopes
             ownedGrants:(NSArray<LocationGrant *> *)ownedGrants
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
        return NO;
    }
    if (tracks.count == 0) {
        // TRAP: an empty open still SETTLES its generation: the playlist left
        // standing answers for it. Without the carry, every later Add is
        // captured at a generation nothing landed and Add is dead for the
        // session. Zero stays zero, so an Add is still promoted, and an append
        // carries nothing.
        if (appending) {
            // Delivered empty, never dropped: whoever asked is waiting to
            // hear how it landed, and nothing else will tell them.
            LogInfo(@"FolderSession: nothing to append");
            [self.delegate folderSession:self didAppendTracks:@[]];
        }
        else {
            _landedOpenIntentGeneration = VibeFolderSessionCarriedOpenIntentGeneration(
                    _landedOpenIntentGeneration, openIntentGeneration);
            if (restored) {
                [self.delegate folderSessionRestoreDidFail:self];
            }
            else {
                [self.delegate folderSessionDidOpenEmptyFolder:self];
            }
            // Replayed, not left hanging; the first promotes in its turn.
            [self releaseAddWaitersAfterSettle];
        }
        return YES;
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
            if (![self rootCoveringPath:VibeComparablePath(folder.path)
                                     in:self.searchRoots]) {
                [_addedFolderURLs addObject:folder];
            }
        }
        [self persistAdditionBookmarks:additionBookmarks];
        _hasAdditions = YES;
        [self.delegate folderSession:self didAppendTracks:tracks];
        return YES;
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
    // A restore of persisted additions; a multi-folder open is not an Add.
    _hasAdditions = restored && additionBookmarks.count > 0;
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
    return YES;
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
