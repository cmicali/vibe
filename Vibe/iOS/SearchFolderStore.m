//
//  SearchFolderStore.m
//  Vibe (iOS)
//

#import "SearchFolderStore.h"

#import "FileSearchRules.h"

NSNotificationName const VibeSearchFoldersDidChangeNotification =
        @"VibeSearchFoldersDidChangeNotification";

// An iOS app-layer key beside FolderSession's and PlayerDisplaySettings', not an
// AppSettings property: the shared settings file stays untouched, and there is no
// macOS counterpart to keep it in step with — the mac has FolderAccessManager.
static NSString *const kSearchFolderBookmarksKey = @"VibeiOSSearchFolderBookmarks";

// One folder: what the user picked, the bookmark that restores it, and whether
// this object started the scope, so the stop can be balanced.
@interface VibeSearchFolder : NSObject
@property (nonatomic) NSURL *url;
@property (nonatomic) NSData *bookmark;
@property (nonatomic) BOOL scopeStarted;
@end

@implementation VibeSearchFolder
@end

@implementation SearchFolderStore {
    // Main-confined.
    NSMutableArray<VibeSearchFolder *> *_folders;
    // Bookmark resolution and minting are file-provider IPC — seconds on a cloud
    // folder — so both run here, serially, and only the delivery returns to main.
    dispatch_queue_t _workQueue;
}

+ (SearchFolderStore *)shared {
    static SearchFolderStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[SearchFolderStore alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _folders = [NSMutableArray array];
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _workQueue = dispatch_queue_create("SearchFolderStore", attributes);
    }
    return self;
}

- (void)dealloc {
    for (VibeSearchFolder *folder in _folders) {
        if (folder.scopeStarted) {
            [folder.url stopAccessingSecurityScopedResource];
        }
    }
}

#pragma mark - Reading

- (NSArray<NSURL *> *)folderURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:_folders.count];
    for (VibeSearchFolder *folder in _folders) {
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
    NSArray<NSData *> *bookmarks =
            [NSUserDefaults.standardUserDefaults arrayForKey:kSearchFolderBookmarksKey];
    if (bookmarks.count == 0) {
        return;
    }
    dispatch_async(_workQueue, ^{
        NSMutableArray<VibeSearchFolder *> *resolved =
                [NSMutableArray arrayWithCapacity:bookmarks.count];
        for (NSData *bookmark in bookmarks) {
            if (![bookmark isKindOfClass:NSData.class]) {
                continue;   // a hand-edited or migrated defaults value
            }
            VibeSearchFolder *folder = [self resolveBookmark:bookmark];
            if (folder) {
                [resolved addObject:folder];
            }
        }
        run_on_main_thread({
            // Appended, not assigned: an add made while the resolve was in
            // flight is already in the list and holds its own scope. A resolved
            // folder some root now covers is dropped rather than listed — a row
            // that contributes nothing is a lie.
            for (VibeSearchFolder *folder in resolved) {
                if (![self isCoveredByAPersistentRoot:folder.url]) {
                    [self->_folders addObject:folder];
                }
                else if (folder.scopeStarted) {
                    [folder.url stopAccessingSecurityScopedResource];
                }
            }
            [self persistAndNotify];
        });
    });
}

// Work queue only. Starts the scope, and re-mints a stale bookmark — which needs
// the scope OPEN, so it cannot be done before.
- (VibeSearchFolder *)resolveBookmark:(NSData *)bookmark {
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
    VibeSearchFolder *folder = [[VibeSearchFolder alloc] init];
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
    // The new folder may swallow narrower entries. Dropped rather than kept, so
    // the list stays the set of trees actually walked — FileSearchIndex would
    // prune them anyway, and a row that contributes nothing is a lie.
    NSString *path = url.URLByStandardizingPath.path;
    NSMutableIndexSet *subsumed = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _folders.count; i++) {
        if (VibeSearchRootCoversPath(path, _folders[i].url.URLByStandardizingPath.path)) {
            [subsumed addIndex:i];
        }
    }
    [subsumed enumerateIndexesWithOptions:NSEnumerationReverse
                              usingBlock:^(NSUInteger i, BOOL *stop) {
        [self releaseFolderAtIndex:i];
    }];

    VibeSearchFolder *folder = [[VibeSearchFolder alloc] init];
    folder.url = url;
    folder.scopeStarted = [url startAccessingSecurityScopedResource];
    [_folders addObject:folder];
    [self persistAndNotify];

    // The bookmark is minted off main — it is provider IPC — and the list is
    // re-persisted when it lands. Until then the folder is searchable but would
    // not survive a relaunch, which is the right way round: the scope is already
    // open, so the walk can start now.
    dispatch_async(_workQueue, ^{
        NSData *bookmark = [self bookmarkForURL:url];
        if (!bookmark) {
            return;
        }
        run_on_main_thread({
            // The row may be gone by now, so it is found by identity rather
            // than by the index it had.
            if ([self->_folders containsObject:folder]) {
                folder.bookmark = bookmark;
                [self persistBookmarks];
            }
        });
    });
    return YES;
}

- (void)removeFolderAtIndex:(NSUInteger)index {
    if (index >= _folders.count) {
        return;
    }
    [self releaseFolderAtIndex:index];
    [self persistAndNotify];
}

- (void)releaseFolderAtIndex:(NSUInteger)index {
    VibeSearchFolder *folder = _folders[index];
    if (folder.scopeStarted) {
        [folder.url stopAccessingSecurityScopedResource];
    }
    [_folders removeObjectAtIndex:index];
}

// Whether the app can already search url without being given anything: a row
// already on the list, or the container's Documents directory.
//
// Tested against searchRoots and NOT against the open folder, deliberately. The
// session's root is gone at the next open, so refusing a folder because it
// happens to be open right now would drop a grant the user will want the moment
// they open something else.
- (BOOL)isCoveredByAPersistentRoot:(NSURL *)url {
    NSString *path = url.URLByStandardizingPath.path;
    for (NSURL *root in [self searchRoots]) {
        if (VibeSearchRootCoversPath(root.URLByStandardizingPath.path, path)) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Persistence

- (void)persistAndNotify {
    [self persistBookmarks];
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeSearchFoldersDidChangeNotification object:self];
}

// A folder whose bookmark has not landed yet is simply absent from the stored
// list; the next mint re-persists the lot.
- (void)persistBookmarks {
    NSMutableArray<NSData *> *bookmarks = [NSMutableArray arrayWithCapacity:_folders.count];
    for (VibeSearchFolder *folder in _folders) {
        if (folder.bookmark) {
            [bookmarks addObject:folder.bookmark];
        }
    }
    if (bookmarks.count > 0) {
        [NSUserDefaults.standardUserDefaults setObject:bookmarks forKey:kSearchFolderBookmarksKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kSearchFolderBookmarksKey];
    }
}

@end
