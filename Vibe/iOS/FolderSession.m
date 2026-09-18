//
//  FolderSession.m
//  Vibe (iOS)
//

#import "FolderSession.h"
#import "AppSettings.h"
#import "AppStats.h"
#import "DocumentTypes.h"
#import "FavoritesStore.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"
#import "SearchFolderStoreInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>

// NSUserDefaults keys. Kept here rather than in AppSettings: they are iOS
// app-layer state, and the shared settings file stays untouched.
static NSString *const kFolderBookmarkKey = @"VibeiOSFolderBookmark";
static NSString *const kAdditionBookmarksKey = @"VibeiOSAdditionBookmarks";
// The value is a standardized path now, not a filename; the key keeps its
// shipped spelling so an installed build's parked track survives the update —
// a bare filename left by one restores through the match's filename tier.
static NSString *const kLastTrackPathKey = @"VibeiOSLastTrackFileName";

@interface FolderSession () <UIDocumentPickerDelegate>
@end

@implementation FolderSession {
    // Every URL whose security scope this session started, in acquisition
    // order: the base open's, then each addition's. Held for the whole session
    // — the player, TagLib and the waveform loader read under them at
    // arbitrary later times — and released only after a successor set is in
    // hand. Main-confined; workers get snapshots. A URL may appear twice (a
    // worker's own hold adopted beside the session's), each start balanced by
    // its own stop.
    NSMutableArray<NSURL *> *_scopedURLs;
    // Persistent-root grants retained for this playlist, same lifetime.
    NSMutableArray<SearchFolderGrant *> *_searchGrants;
    // The BASE folder: the Playlist tab's title, the star, the bookmark.
    // Appends never move it; nil for a single-file base.
    NSURL *_folderURL;
    // Folders added after the base (or a multi-URL open's further folders).
    // Search roots only — never the title, never the star.
    NSMutableArray<NSURL *> *_addedFolderURLs;
    // YES when this session's replace wrote the base bookmark, so the addition
    // list belongs to this session and may be extended. NO after a search-hit
    // open, an inbox copy or a one-file open over a folder bookmark, all of
    // which leave the persisted base alone.
    BOOL _additionsPersisted;
    // Bookmark resolution and directory listings are file-provider IPC.
    // Replaces run concurrently so a new user intent is not parked behind an
    // older provider call; openIntentGeneration decides which result may
    // deliver.
    dispatch_queue_t _workQueue;
    // Appends run serially, behind each other but not behind a replace, so two
    // Adds land in tap order.
    dispatch_queue_t _appendQueue;
    _Atomic(uint64_t) _openIntentGeneration;
    // The generation of the last SETTLED replace — one that delivered a
    // playlist, or one that found nothing and so left the last delivered one
    // standing. An append lands only against the playlist it was requested on;
    // zero means nothing has ever landed, so an Add is promoted to an Open.
    // Main-confined.
    uint64_t _landedOpenIntentGeneration;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0);
        _workQueue = dispatch_queue_create("FolderSession", attributes);
        // Targeting the work queue inherits its QoS and keeps appends off the
        // replace lane's concurrency.
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

// The session folder — base or addition — whose subtree contains path, or nil.
// Deliberately NOT _scopedURLs: that list holds only URLs whose
// startAccessingSecurityScopedResource returned YES, and a container folder is
// not security-scoped, so _folderURL can be set while _scopedURLs is empty. A
// file picked inside the open container folder must still expand.
- (NSURL *)heldRootCoveringPath:(NSString *)path {
    for (NSURL *root in self.searchRoots) {
        if (VibeSearchRootCoversPath(root.URLByStandardizingPath.path, path)) {
            return root;
        }
    }
    return nil;
}

#pragma mark - Picker

- (void)presentPickerFromViewController:(UIViewController *)presenter
                              appending:(BOOL)appending {
    NSArray<UTType *> *types = [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    // An Add takes several items — the whole point of a second road to it on a
    // tab with no Select mode — while a replace stays one location, which is
    // the directory-as-playlist model. The delegate reads the mode back off
    // this, so there is no second copy of it to keep in step.
    picker.allowsMultipleSelection = appending;
    picker.delegate = self;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self beginOpenURLs:urls appending:controller.allowsMultipleSelection fromSearchRoots:NO];
}

#pragma mark - External opens

- (void)openURLs:(NSArray<NSURL *> *)urls openInPlace:(BOOL)openInPlace {
    if (!openInPlace) {
        // Not open-in-place: the system handed a copy in our own inbox
        // container, readable without a scope. It deliberately skips the
        // worker — Documents/Inbox sits UNDER the container Documents folder,
        // so whenever that folder is the open base the coverage rule would
        // expand the copy into the whole Inbox.
        NSURL *url = urls.firstObject;
        if (!url) {
            return;
        }
        [self finishOpenIntent:[self beginOpenIntent] appending:NO tracks:@[url]
                     folderURL:nil addedFolders:@[] selectedURL:nil restored:NO
                   ownedScopes:@[] ownedGrants:@[] baseBookmark:nil additionBookmarks:@[]];
        return;
    }
    [self beginOpenURLs:urls appending:NO fromSearchRoots:NO];
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    [self beginOpenURLs:urls appending:YES fromSearchRoots:NO];
}

- (void)openFileFromSearchRoots:(NSURL *)url {
    [self beginOpenURLs:@[url] appending:NO fromSearchRoots:YES];
}

#pragma mark - Persistence

- (BOOL)restorePersistedFolder {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
    if (!bookmark) {
        return NO;
    }
    NSArray *additions =
            [NSUserDefaults.standardUserDefaults arrayForKey:kAdditionBookmarksKey] ?: @[];
    uint64_t openIntentGeneration = [self beginOpenIntent];
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    dispatch_async(_workQueue, ^{
        if (![self isCurrentOpenIntent:openIntentGeneration]) {
            return;
        }
        NSError *error = nil;
        NSURL *base = [self resolveBookmark:bookmark error:&error];
        if (!base) {
            LogWarn(@"FolderSession: bookmark no longer resolves (%@)", error);
            run_on_main_thread({
                if ([self isCurrentOpenIntent:openIntentGeneration]) {
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:kAdditionBookmarksKey];
                    [self.delegate folderSessionRestoreDidFail:self];
                }
            });
            return;
        }
        // No pre-adopt refresh of a stale bookmark: minting bookmark data
        // needs the security scope OPEN, and the landing re-persists after the
        // scope starts anyway — the refresh before it always failed.
        NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithObject:base];
        for (id data in additions) {
            NSURL *url = [data isKindOfClass:NSData.class]
                    ? [self resolveBookmark:data error:NULL] : nil;
            if (url) {
                [urls addObject:url];
            }
            else {
                // Nothing prunes the list: the landing rewrites both keys from
                // what actually resolved and listed, so a dead or emptied
                // addition drops itself here.
                LogWarn(@"FolderSession: an addition bookmark no longer resolves");
            }
        }
        [self openURLsOnWorkQueue:urls appending:NO restored:YES fromSearchRoots:NO
                         sortedBy:sort coveringRootPaths:@[] holds:@[] grants:@[]
             openIntentGeneration:openIntentGeneration];
    });
    return YES;
}

- (NSString *)persistedTrackPath {
    return [NSUserDefaults.standardUserDefaults stringForKey:kLastTrackPathKey];
}

- (void)setPersistedTrackPath:(NSString *)path {
    if (path) {
        [NSUserDefaults.standardUserDefaults setObject:path forKey:kLastTrackPathKey];
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
    // iOS has no WithSecurityScope option: a default bookmark of a
    // picker-granted URL round-trips the scope by itself. Requires the URL's
    // scope to be open, which every caller guarantees.
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

// Extends the persisted addition list. Only this session's own base may be
// extended: after a search hit, an inbox copy or a one-file open over a folder
// bookmark the persisted base belongs to an earlier playlist.
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

// The hold is what makes this safe to run off main: finishOpenIntent releases
// the previous scopes the moment a newer open lands, and a mint under a closed
// scope fails.
- (void)bookmarkOpenFolderWithCompletion:(void (^)(NSURL *folderURL,
                                                   NSData *bookmark))completion {
    NSURL *folderURL = _folderURL;
    if (!folderURL) {
        completion(nil, nil);
        return;
    }
    NSURL *scopedURL = [self heldRootCoveringPath:folderURL.URLByStandardizingPath.path];
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

#pragma mark - Opening

// The one funnel for a URL list from any source. Each request owns an intent
// number; provider work can overlap, but only the newest result may replace the
// live session. Main thread, and no I/O: string compares over snapshots, plus
// the scope starts the worker reads under — a request also takes a hold on each
// covering scope so an older worker can finish safely after a newer result has
// replaced it.
//
// fromSearchRoots: YES for a search hit — its parent was already walked under a
// root in hand, so it is listed unconditionally, and the persisted bookmark is
// left alone, since re-pointing it at a subfolder would shrink next launch's
// searchable root.
- (void)beginOpenURLs:(NSArray<NSURL *> *)urls
            appending:(BOOL)appending
      fromSearchRoots:(BOOL)fromSearchRoots {
    if (urls.count == 0) {
        return;
    }
    // An Add onto nothing IS an open: it plays and presents the card. "Restore
    // failed at launch, then Add" deliberately lands here and plays.
    appending = appending && _landedOpenIntentGeneration != 0;
    uint64_t openIntentGeneration = appending
            ? atomic_load_explicit(&_openIntentGeneration, memory_order_acquire)
            : [self beginOpenIntent];
    // The listing order rides the snapshot for the same reason the rest of it
    // does: an open must not straddle a Settings change.
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    // The roots this request may read under, standardized here because the
    // worker's one coverage question takes paths. A session folder implies no
    // scope — a container folder is never security-scoped — while a hold and a
    // grant do, which is why all three land in one list for reading and stay
    // separate lists for lifetime.
    NSMutableArray<NSString *> *coveringRootPaths = [NSMutableArray array];
    for (NSURL *folder in self.searchRoots) {
        [coveringRootPaths addObject:folder.URLByStandardizingPath.path ?: @""];
    }
    NSMutableArray<NSURL *> *holds = [NSMutableArray array];
    NSMutableArray<SearchFolderGrant *> *grants = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *path = url.URLByStandardizingPath.path;
        NSURL *root = [self heldRootCoveringPath:path];
        SearchFolderGrant *grant = [SearchFolderStore.shared grantCoveringURL:url];
        if (!grant) {
            // The row may have been removed after it produced the current
            // playlist. Transfer that playlist's retained grant to this open
            // instead of revoking it when the result wins.
            for (SearchFolderGrant *held in _searchGrants) {
                if (VibeSearchRootCoversPath(held.rootURL.URLByStandardizingPath.path, path)) {
                    grant = held;
                    break;
                }
            }
        }
        // A file inside a STARRED folder is covered by neither of those: the
        // store holds that scope and drops it when the row goes. So the session
        // takes a hold of its own on the favorite's root. That, and not a
        // refcounted grant, is what keeps this playlist readable after the
        // favorite is unstarred.
        if (!root && !grant) {
            root = [FavoritesStore.shared resolvedRootCoveringURL:url];
        }
        // Only a start that returned YES is collected: holds is the list the
        // worker must balance, and a container folder is not security-scoped.
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

// Adds the URLs this delivery has not already named to tracks, and answers how
// many it took, so a caller can tell "contributed nothing" from "contributed".
- (NSUInteger)appendFresh:(NSArray<NSURL *> *)urls
                       to:(NSMutableArray<NSURL *> *)tracks
                     seen:(NSMutableSet<NSString *> *)seenPaths {
    NSUInteger taken = 0;
    for (NSURL *url in urls) {
        NSString *path = url.URLByStandardizingPath.path;
        if (path && ![seenPaths containsObject:path]) {
            [seenPaths addObject:path];
            [tracks addObject:url];
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
    NSMutableArray<NSURL *> *tracks = [NSMutableArray array];
    // One delivery names each file once. A restore's list can legitimately
    // overlap — an Add the shell deduped away still persisted its bookmark, and
    // a folder can be added beside one of its own files — and the union is
    // delivered as a REPLACE, which does not dedupe. Without this the playlist
    // grew a copy of every re-added folder at each relaunch.
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    NSMutableArray<NSURL *> *ownedScopes = [NSMutableArray array];
    NSMutableArray<NSURL *> *addedFolders = [NSMutableArray array];
    // The URLs that actually produced tracks, in pick order: a folder, the
    // parent an expansion listed, or a one-track file. Bookmarks are minted
    // from these and never from urls, so a folder holding no audio persists
    // nothing.
    NSMutableArray<NSURL *> *contributors = [NSMutableArray array];
    NSURL *folderURL = nil;
    NSURL *selectedURL = nil;
    // An added file is one track, never its directory; only a replace of
    // exactly one picked file expands.
    BOOL expands = !appending && urls.count == 1;
    // The persisted base, resolved at most once per pass and lazily: the
    // expansion test and the one-file bookmark rule below both ask about it,
    // a resolve is provider IPC that can take seconds, and a folder open needs
    // neither. The flag records that the answer is known, nil included.
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
        // A NO return is not failure: the app's own container and open-in-place
        // inbox URLs are not security-scoped. Track what we actually started so
        // the paired stop is balanced.
        BOOL started = [url startAccessingSecurityScopedResource];
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        // The key can be absent — a URL the provider has not resolved yet — and
        // then the trailing slash is all there is to go on. Compared to nil
        // explicitly: an NSNumber * in a boolean position is a pointer test, not
        // a value test, which is what the analyzer flags.
        BOOL isDir = isDirectory != nil ? isDirectory.boolValue : url.hasDirectoryPath;

        // A single-file grant reaches only that file — iOS grants no sibling
        // access — but a FOLDER already in hand may cover it: an open folder,
        // a Settings grant, a favorite's root, or the persisted bookmark on a
        // cold open-in-place. Then "tap a file in Dropbox" expands back into
        // the directory-as-playlist model, with the tapped file selected. Only
        // a file no folder in hand covers stays a one-track playlist.
        if (!isDir && expands) {
            NSURL *parent = url.URLByDeletingLastPathComponent;
            NSString *parentPath = parent.URLByStandardizingPath.path;
            NSURL *bookmarkRoot = nil;
            BOOL bookmarkScopeStarted = NO;
            BOOL listable = fromSearchRoots
                    || VibeSearchFolderCoveringRootIndex(coveringRootPaths, parentPath) != NSNotFound;
            if (!listable) {
                // The persisted base is the only folder grant in hand on a cold
                // "Open in Vibe", which arrives before any restore ran.
                NSURL *candidate = resolvePersistedBase();
                if (candidate && VibeSearchRootCoversPath(
                        candidate.URLByStandardizingPath.path, parentPath)) {
                    bookmarkScopeStarted = [candidate startAccessingSecurityScopedResource];
                    bookmarkRoot = candidate;
                    listable = YES;
                }
            }
            if (listable) {
                if ([self appendFresh:[NSURLUtil audioFilesInDirectory:parent sortedBy:sort]
                                   to:tracks
                                 seen:seenPaths] > 0) {
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

        // A URL that added nothing is not a contributor: its bookmark is not
        // persisted, which is what prunes a redundant addition.
        NSArray<NSURL *> *produced = isDir ? [NSURLUtil audioFilesInDirectory:url sortedBy:sort]
                                           : @[url];
        if ([self appendFresh:produced to:tracks seen:seenPaths] == 0) {
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
            // The base is the FIRST contributor, whatever it is: a file first
            // means a single-file base with no folderURL, and every later
            // folder is an addition. TRAP: a folder may not claim the base
            // merely because the contributor ahead of it was a file — a
            // restore delivers base-then-additions, so that would rewrite the
            // base bookmark to the addition, demote the original base to an
            // addition, and reorder the union at the next relaunch.
            if (!appending && contributors.count == 1) {
                folderURL = url;
            }
            else {
                [addedFolders addObject:url];
            }
        }
    }

    if (tracks.count == 0) {
        // Nothing here reaches the playlist, so every scope this pass started
        // is released whatever the generation.
        for (NSURL *hold in holds) {
            [hold stopAccessingSecurityScopedResource];
        }
        for (NSURL *owned in ownedScopes) {
            [owned stopAccessingSecurityScopedResource];
        }
        // Still a landing: an open that found nothing leaves the previous
        // playlist standing, and finishOpenIntent: is the one place allowed to
        // say so and to touch the main-confined state.
        run_on_main_thread({
            [self finishOpenIntent:openIntentGeneration appending:appending tracks:@[]
                         folderURL:nil addedFolders:@[] selectedURL:nil restored:restored
                       ownedScopes:@[] ownedGrants:@[] baseBookmark:nil additionBookmarks:@[]];
        });
        return;
    }

    // A hold taken for a URL that contributed nothing is released now; the rest
    // are adopted, so every scope the playlist reads under outlives this call.
    // Tested against the contributors rather than the tracks: a hold covers a
    // track exactly when it covers the contributor that produced it — the
    // listing is flat, and a single-file contributor IS its track — and there
    // are as many contributors as URLs picked, against thousands of tracks.
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

    // Minting needs the scope OPEN, so it runs here, before anything is
    // released, and under the intent check so late provider work cannot
    // overwrite a newer open's bookmarks.
    NSData *baseBookmark = nil;
    NSMutableArray<NSData *> *additionBookmarks = [NSMutableArray array];
    NSURL *base = appending ? nil : (folderURL ?: contributors.firstObject);
    if ([self isCurrentOpenIntent:openIntentGeneration]) {
        // A one-file open never replaces a folder bookmark: that broader grant
        // is what powers sibling expansion and relaunch restore. An open that
        // brought a folder in at all is not that case, whichever contributor
        // the base turned out to be — a multi-select of a file and a folder
        // owns the next launch, and refusing to persist it would restore a
        // playlist that no longer exists.
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

// Main thread only, and the one place the session's own state moves. Every
// request ends here, an empty result included — a stale one releases only the
// scopes it started and leaves the current session untouched. Bookmark
// persistence is here too, under the same intent check, so late provider work
// cannot overwrite a newer open.
- (void)finishOpenIntent:(uint64_t)openIntentGeneration
               appending:(BOOL)appending
                  tracks:(NSArray<NSURL *> *)tracks
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
        // The open this Add was requested during has not landed, so there is no
        // playlist to add to yet.
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
        // TRAP: an open that delivered nothing still SETTLES its generation.
        // The playlist it left standing is the one the last landing installed,
        // so that playlist answers for this generation too. Without the carry
        // every Add made after an empty-folder open captures a generation no
        // landing ever matched and is dropped — one empty folder killed Add
        // for the rest of the session. Zero stays zero, so an Add onto a
        // session that never landed anything is still promoted to an Open
        // (restore fails at launch, then Add plays), and an append carries
        // nothing: a bad Add must not make itself the base.
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
        return;
    }
    // The one place every entry point lands, so the counters cannot miss an
    // open or double-count one. A launch restore is not an open the user made,
    // and counting it would add a folder to the total on every cold start.
    // An append never carries a base folder, so the same expression serves it.
    if (!restored) {
        [[AppStats sharedInstance] recordOpenedFiles:tracks.count
                                             folders:(folderURL ? 1 : 0) + addedFolders.count];
    }
    if (appending) {
        [_scopedURLs addObjectsFromArray:ownedScopes];
        [_searchGrants addObjectsFromArray:ownedGrants];
        // A folder a root in hand already covers names no new search root.
        // Without this, adding the same favorite twice lists it twice and
        // persists a second bookmark the next launch resolves and lists for
        // nothing. Its scope is still adopted above: that is lifetime, not
        // reach.
        for (NSURL *folder in addedFolders) {
            if (![self heldRootCoveringPath:folder.URLByStandardizingPath.path]) {
                [_addedFolderURLs addObject:folder];
            }
        }
        [self persistAdditionBookmarks:additionBookmarks];
        [self.delegate folderSession:self didAppendTracks:tracks];
        return;
    }
    // TRAP: acquire before release. The successor set is installed FIRST and
    // only then is the previous one stopped, so a failed pick never strands the
    // current playlist unreadable. A URL may sit in both sets — it was started
    // once for each, and each start is balanced by its own stop.
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
}

@end
