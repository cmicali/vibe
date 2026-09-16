//
//  SearchFolderStore.m
//  Vibe (iOS)
//

#import "SearchFolderStore.h"

#import "FileSearchRules.h"
#import "SearchFolderStoreInternal.h"

NSNotificationName const VibeSearchFoldersDidChangeNotification =
        @"VibeSearchFoldersDidChangeNotification";

// An iOS app-layer key beside FolderSession's and PlayerDisplaySettings', not an
// AppSettings property: the shared settings file stays untouched, and there is no
// macOS counterpart to keep it in step with — the mac has FolderAccessManager.
static NSString *const kSearchFolderBookmarksKey = @"VibeiOSSearchFolderBookmarks";
static NSString *const kSearchFolderRestoreSuppressionsKey =
        @"VibeiOSSearchFolderRestoreSuppressions";
static NSString *const kSuppressedBookmarkKey = @"bookmark";
static NSString *const kSuppressedRootPathsKey = @"rootPaths";
static const NSInteger kMaximumConcurrentBookmarkRestorations = 3;

@interface SearchFolderEntry : NSObject
@property (nonatomic) NSURL *url;
@property (nonatomic, nullable) NSData *bookmark;
@property (nonatomic) BOOL scopeStarted;
@property (nonatomic) NSUInteger ordinal;
// A parent whose bookmark is not durable yet owns the narrower entries it
// replaced, so their bookmarks remain the relaunch state until minting settles.
@property (nonatomic) NSArray<SearchFolderEntry *> *replacedEntries;
@property (nonatomic) NSUInteger sessionGrantCount;
@property (nonatomic) BOOL retired;
@end

@implementation SearchFolderEntry
- (instancetype)init {
    self = [super init];
    if (self) {
        _replacedEntries = @[];
    }
    return self;
}
@end

// One persisted bookmark restoration and the root removals that are allowed to
// suppress only this identity after its provider finally resolves the URL.
@interface PendingSearchFolderRestore : NSObject
@property (nonatomic) NSData *bookmark;
@property (nonatomic) NSMutableOrderedSet<NSString *> *suppressedRootPaths;
@end

@implementation PendingSearchFolderRestore
@end

@class SearchFolderStore;

@interface SearchFolderGrant () {
    SearchFolderStore *_store;
    SearchFolderEntry *_entry;
}
- (instancetype)initWithStore:(SearchFolderStore *)store entry:(SearchFolderEntry *)entry;
@end

@interface SearchFolderStore ()
- (instancetype)initPrivate;
- (void)releaseSessionGrantForEntry:(SearchFolderEntry *)entry;
@end

@implementation SearchFolderGrant

- (instancetype)initWithStore:(SearchFolderStore *)store entry:(SearchFolderEntry *)entry {
    self = [super init];
    if (self) {
        _store = store;
        _entry = entry;
        _rootURL = entry.url;
    }
    return self;
}

- (void)dealloc {
    SearchFolderStore *store = _store;
    SearchFolderEntry *entry = _entry;
    if (NSThread.isMainThread) {
        [store releaseSessionGrantForEntry:entry];
    }
    else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [store releaseSessionGrantForEntry:entry];
        });
    }
}

@end

@implementation SearchFolderStore {
    // Main-confined. An entry remains alive after removal while a FolderSession
    // grant still retains it; retirement balances the scope when the last one
    // releases.
    NSMutableArray<SearchFolderEntry *> *_folders;
    NSMutableDictionary<NSNumber *, PendingSearchFolderRestore *> *_pendingRestorations;
    NSUInteger _nextEntryOrdinal;
    BOOL _restoreStarted;

    // Resolution is bounded and independent. Bookmark minting is separate so a
    // provider stalled during launch restore cannot park a folder the user adds.
    NSOperationQueue *_restoreQueue;
    dispatch_queue_t _bookmarkQueue;
}

+ (SearchFolderStore *)shared {
    static SearchFolderStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[SearchFolderStore alloc] initPrivate];
    });
    return shared;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _folders = [NSMutableArray array];
        _pendingRestorations = [NSMutableDictionary dictionary];

        _restoreQueue = [[NSOperationQueue alloc] init];
        _restoreQueue.name = @"SearchFolderStore.restore";
        _restoreQueue.qualityOfService = NSQualityOfServiceUtility;
        _restoreQueue.maxConcurrentOperationCount = kMaximumConcurrentBookmarkRestorations;

        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _bookmarkQueue = dispatch_queue_create("SearchFolderStore.bookmark", attributes);
    }
    return self;
}

- (void)dealloc {
    [_restoreQueue cancelAllOperations];
    for (SearchFolderEntry *folder in _folders) {
        [self retireScopeTree:folder];
    }
}

#pragma mark - Reading

- (NSArray<NSURL *> *)folderURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:_folders.count];
    for (SearchFolderEntry *folder in _folders) {
        [urls addObject:folder.url];
    }
    return urls;
}

// The app's own Documents directory: readable with no grant, so it is always a
// root and can never be a row.
+ (NSURL *)containerDocumentsURL {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                inDomains:NSUserDomainMask].firstObject;
}

- (NSArray<NSURL *> *)searchRoots {
    NSMutableArray<NSURL *> *roots = [[self folderURLs] mutableCopy];
    NSURL *documents = [SearchFolderStore containerDocumentsURL];
    if (documents) {
        [roots addObject:documents];
    }
    return roots;
}

- (NSString *)displayNameForFolderAtIndex:(NSUInteger)index {
    if (index >= _folders.count) {
        return @"";
    }
    NSURL *url = _folders[index].url;
    return [NSFileManager.defaultManager displayNameAtPath:url.path] ?: url.lastPathComponent;
}

#pragma mark - Restoring

- (void)restorePersistedFolders {
    if (_restoreStarted) {
        return;
    }
    _restoreStarted = YES;

    NSArray *stored = [NSUserDefaults.standardUserDefaults
            arrayForKey:kSearchFolderBookmarksKey];
    NSArray *suppressionRecords = [NSUserDefaults.standardUserDefaults
            arrayForKey:kSearchFolderRestoreSuppressionsKey];
    for (id value in stored) {
        if (![value isKindOfClass:NSData.class]) {
            continue;
        }
        NSData *bookmark = value;
        NSUInteger ordinal = _nextEntryOrdinal++;
        NSNumber *key = @(ordinal);
        PendingSearchFolderRestore *pending = [[PendingSearchFolderRestore alloc] init];
        pending.bookmark = bookmark;
        pending.suppressedRootPaths = [NSMutableOrderedSet orderedSetWithArray:
                [self suppressedRootPathsForBookmark:bookmark inRecords:suppressionRecords]];
        _pendingRestorations[key] = pending;
        [_restoreQueue addOperationWithBlock:^{
            SearchFolderEntry *folder = [self resolveBookmark:bookmark];
            dispatch_async(dispatch_get_main_queue(), ^{
                // Each bookmark owns one key, so independent completions cannot
                // remove or publish one another's restoration.
                PendingSearchFolderRestore *livePending = self->_pendingRestorations[key];
                if (!livePending) {
                    [self retireScopeTree:folder];
                    return;
                }
                [self->_pendingRestorations removeObjectForKey:key];
                BOOL rowsChanged = NO;
                if (folder) {
                    folder.ordinal = ordinal;
                    NSString *path = folder.url.URLByStandardizingPath.path;
                    if (VibeSearchPendingRestoreShouldBeSuppressed(
                            livePending.suppressedRootPaths.array,
                            [self persistentRootPaths], path)) {
                        [self retireScopeTree:folder];
                    }
                    else {
                        rowsChanged = [self mergeEntry:folder];
                    }
                }
                [self persistBookmarks];
                if (rowsChanged) {
                    [self notifyFoldersChanged];
                }
            });
        }];
    }
    if (_pendingRestorations.count == 0) {
        [NSUserDefaults.standardUserDefaults
                removeObjectForKey:kSearchFolderRestoreSuppressionsKey];
    }
}

- (NSArray<NSString *> *)suppressedRootPathsForBookmark:(NSData *)bookmark
                                               inRecords:(NSArray *)records {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (id value in records) {
        if (![value isKindOfClass:NSDictionary.class]
                || ![value[kSuppressedBookmarkKey] isEqual:bookmark]) {
            continue;
        }
        id storedPaths = value[kSuppressedRootPathsKey];
        if (![storedPaths isKindOfClass:NSArray.class]) {
            continue;
        }
        for (id path in storedPaths) {
            if ([path isKindOfClass:NSString.class] && [path length] > 0) {
                [paths addObject:path];
            }
        }
    }
    return paths.array;
}

// Restore queue only. Starts the scope, and re-mints a stale bookmark — which
// needs the scope open, so it cannot be done before.
- (SearchFolderEntry *)resolveBookmark:(NSData *)bookmark {
    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:0
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:&error];
    if (!url) {
        LogWarn(@"SearchFolderStore: dropping a folder whose bookmark no longer resolves (%@)",
                error);
        return nil;
    }
    SearchFolderEntry *folder = [[SearchFolderEntry alloc] init];
    folder.url = url;
    // A NO return is not failure — the app's own container is not
    // security-scoped. Record what was actually started, for the balanced stop.
    folder.scopeStarted = [url startAccessingSecurityScopedResource];
    folder.bookmark = stale ? ([self bookmarkForURL:url] ?: bookmark) : bookmark;
    return folder;
}

// iOS has no WithSecurityScope option: a default bookmark of a picker-granted
// URL round-trips the scope by itself, provided that scope is open.
- (NSData *)bookmarkForURL:(NSURL *)url {
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (!bookmark) {
        LogWarn(@"SearchFolderStore: could not bookmark %@ (%@)", url, error);
    }
    return bookmark;
}

#pragma mark - Adding and removing

- (BOOL)addFolderURL:(NSURL *)url {
    if ([self isCoveredByAPersistentRoot:url]) {
        return NO;
    }

    SearchFolderEntry *folder = [[SearchFolderEntry alloc] init];
    folder.url = url;
    folder.scopeStarted = [url startAccessingSecurityScopedResource];
    folder.ordinal = _nextEntryOrdinal++;
    [self mergeEntry:folder];
    [self persistAndNotify];

    // The bookmark is minted independently of launch restoration. Until it
    // lands the parent is searchable, while the replaced entries remain the
    // durable relaunch state.
    dispatch_async(_bookmarkQueue, ^{
        NSData *bookmark = [self bookmarkForURL:url];
        if (!bookmark) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self entryIsLive:folder]) {
                return;
            }
            folder.bookmark = bookmark;
            [self suppressPendingRestorationsCoveredByURL:folder.url];
            for (SearchFolderEntry *replacedEntry in folder.replacedEntries) {
                [self retireScopeTree:replacedEntry];
            }
            folder.replacedEntries = @[];
            [self persistBookmarks];
        });
    });
    return YES;
}

- (void)removeFolderAtIndex:(NSUInteger)index {
    if (index >= _folders.count) {
        return;
    }
    SearchFolderEntry *folder = _folders[index];
    [self suppressPendingRestorationsCoveredByURL:folder.url];
    [_folders removeObjectAtIndex:index];
    [self retireScopeTree:folder];
    [self persistAndNotify];
}

// The one bidirectional coverage merge for both live additions and async
// restores. An existing ancestor absorbs the candidate; otherwise the
// candidate replaces every descendant before being inserted by original order.
- (BOOL)mergeEntry:(SearchFolderEntry *)candidate {
    NSString *candidatePath = candidate.url.URLByStandardizingPath.path;
    NSURL *documents = [SearchFolderStore containerDocumentsURL];
    if (documents && VibeSearchRootCoversPath(
            documents.URLByStandardizingPath.path, candidatePath)) {
        [self retireScopeTree:candidate];
        return NO;
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:_folders.count];
    for (SearchFolderEntry *folder in _folders) {
        [paths addObject:folder.url.URLByStandardizingPath.path ?: @""];
    }

    NSUInteger coveringIndex = VibeSearchFolderCoveringRootIndex(paths, candidatePath);
    if (coveringIndex != NSNotFound) {
        SearchFolderEntry *covering = _folders[coveringIndex];
        if (!covering.bookmark) {
            covering.replacedEntries = [covering.replacedEntries
                    arrayByAddingObject:candidate];
        }
        else {
            [self suppressPendingRestorationsCoveredByURL:covering.url];
            [self retireScopeTree:candidate];
        }
        return NO;
    }

    NSIndexSet *covered = VibeSearchFolderIndexesCoveredByRoot(paths, candidatePath);
    NSArray<SearchFolderEntry *> *replaced = [_folders objectsAtIndexes:covered];
    [_folders removeObjectsAtIndexes:covered];
    if (!candidate.bookmark) {
        candidate.replacedEntries = [candidate.replacedEntries
                arrayByAddingObjectsFromArray:replaced];
    }
    else {
        for (SearchFolderEntry *folder in replaced) {
            [self retireScopeTree:folder];
        }
    }
    if (candidate.bookmark) {
        [self suppressPendingRestorationsCoveredByURL:candidate.url];
    }

    NSUInteger insertionIndex = [_folders indexOfObjectPassingTest:^BOOL(
            SearchFolderEntry *folder, NSUInteger index, BOOL *stop) {
        return folder.ordinal > candidate.ordinal;
    }];
    if (insertionIndex == NSNotFound) {
        insertionIndex = _folders.count;
    }
    [_folders insertObject:candidate atIndex:insertionIndex];
    return YES;
}

- (void)suppressPendingRestorationsCoveredByURL:(NSURL *)url {
    NSString *rootPath = url.URLByStandardizingPath.path;
    if (rootPath.length == 0) {
        return;
    }
    for (PendingSearchFolderRestore *pending in _pendingRestorations.allValues) {
        [pending.suppressedRootPaths addObject:rootPath];
    }
}

- (BOOL)entryIsLive:(SearchFolderEntry *)candidate {
    for (SearchFolderEntry *folder in _folders) {
        if ([self entry:candidate isInTree:folder]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)entry:(SearchFolderEntry *)candidate isInTree:(SearchFolderEntry *)folder {
    if (candidate == folder) {
        return YES;
    }
    for (SearchFolderEntry *replaced in folder.replacedEntries) {
        if ([self entry:candidate isInTree:replaced]) {
            return YES;
        }
    }
    return NO;
}

// Whether the app can already search url without being given anything: a row
// already on the list, or the container's Documents directory. The transient
// FolderSession root is deliberately absent because it is gone at the next open.
- (BOOL)isCoveredByAPersistentRoot:(NSURL *)url {
    return VibeSearchFolderCoveringRootIndex(
            [self persistentRootPaths], url.URLByStandardizingPath.path) != NSNotFound;
}

- (NSArray<NSString *> *)persistentRootPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:_folders.count + 1];
    NSURL *documents = [SearchFolderStore containerDocumentsURL];
    NSString *documentsPath = documents.URLByStandardizingPath.path;
    if (documentsPath.length > 0) {
        [paths addObject:documentsPath];
    }
    for (SearchFolderEntry *folder in _folders) {
        NSString *path = folder.url.URLByStandardizingPath.path;
        if (path.length > 0) {
            [paths addObject:path];
        }
    }
    return paths;
}

#pragma mark - Session grants

- (SearchFolderGrant *)grantCoveringURL:(NSURL *)url {
    NSString *path = url.URLByStandardizingPath.path;
    SearchFolderEntry *best = nil;
    for (SearchFolderEntry *folder in _folders) {
        NSString *rootPath = folder.url.URLByStandardizingPath.path;
        if (VibeSearchRootCoversPath(rootPath, path)
                && (!best || rootPath.length > best.url.URLByStandardizingPath.path.length)) {
            best = folder;
        }
    }
    if (!best) {
        return nil;
    }
    best.sessionGrantCount++;
    return [[SearchFolderGrant alloc] initWithStore:self entry:best];
}

- (void)releaseSessionGrantForEntry:(SearchFolderEntry *)entry {
    if (entry.sessionGrantCount == 0) {
        return;
    }
    entry.sessionGrantCount--;
    [self finishRetiringEntryIfPossible:entry];
}

- (void)retireScopeTree:(SearchFolderEntry *)folder {
    if (folder.retired) {
        return;
    }
    folder.retired = YES;
    [self finishRetiringEntryIfPossible:folder];
    for (SearchFolderEntry *replaced in folder.replacedEntries) {
        [self retireScopeTree:replaced];
    }
}

- (void)finishRetiringEntryIfPossible:(SearchFolderEntry *)folder {
    if (!folder.retired || folder.sessionGrantCount != 0 || !folder.scopeStarted) {
        return;
    }
    [folder.url stopAccessingSecurityScopedResource];
    folder.scopeStarted = NO;
}

#pragma mark - Persistence

- (void)persistAndNotify {
    [self persistBookmarks];
    [self notifyFoldersChanged];
}

- (void)notifyFoldersChanged {
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeSearchFoldersDidChangeNotification object:self];
}

- (void)persistBookmarks {
    // Restore completions can land out of order. Merge live and still-pending
    // bookmarks by their original ordinal before writing the relaunch list.
    NSMutableDictionary<NSNumber *, NSData *> *bookmarksByOrdinal =
            [NSMutableDictionary dictionary];
    for (SearchFolderEntry *folder in _folders) {
        [self appendDurableBookmarksForFolder:folder toDictionary:bookmarksByOrdinal];
    }
    NSArray<NSNumber *> *pendingOrdinals = [_pendingRestorations.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *ordinal in pendingOrdinals) {
        if (!bookmarksByOrdinal[ordinal]) {
            bookmarksByOrdinal[ordinal] = _pendingRestorations[ordinal].bookmark;
        }
    }

    NSMutableArray<NSData *> *bookmarks = [NSMutableArray array];
    NSMutableSet<NSData *> *seen = [NSMutableSet set];
    NSArray<NSNumber *> *durableOrdinals = [bookmarksByOrdinal.allKeys
            sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *ordinal in durableOrdinals) {
        NSData *bookmark = bookmarksByOrdinal[ordinal];
        if (![seen containsObject:bookmark]) {
            [seen addObject:bookmark];
            [bookmarks addObject:bookmark];
        }
    }
    if (bookmarks.count > 0) {
        [NSUserDefaults.standardUserDefaults setObject:bookmarks forKey:kSearchFolderBookmarksKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kSearchFolderBookmarksKey];
    }

    NSMutableArray<NSDictionary *> *suppressionRecords = [NSMutableArray array];
    for (NSNumber *ordinal in pendingOrdinals) {
        PendingSearchFolderRestore *pending = _pendingRestorations[ordinal];
        if (pending.suppressedRootPaths.count > 0) {
            [suppressionRecords addObject:@{
                kSuppressedBookmarkKey: pending.bookmark,
                kSuppressedRootPathsKey: pending.suppressedRootPaths.array
            }];
        }
    }
    if (suppressionRecords.count > 0) {
        [NSUserDefaults.standardUserDefaults setObject:suppressionRecords
                                                  forKey:kSearchFolderRestoreSuppressionsKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults
                removeObjectForKey:kSearchFolderRestoreSuppressionsKey];
    }
}

// A pending parent persists the entries it replaced. The live list stays
// minimal while relaunch recovery remains transactional until the new grant is
// durable.
- (void)appendDurableBookmarksForFolder:(SearchFolderEntry *)folder
                           toDictionary:(NSMutableDictionary<NSNumber *, NSData *> *)bookmarksByOrdinal {
    if (folder.bookmark) {
        bookmarksByOrdinal[@(folder.ordinal)] = folder.bookmark;
        return;
    }
    for (SearchFolderEntry *replaced in folder.replacedEntries) {
        [self appendDurableBookmarksForFolder:replaced toDictionary:bookmarksByOrdinal];
    }
}

@end
