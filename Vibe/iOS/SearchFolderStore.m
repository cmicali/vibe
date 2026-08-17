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
// A pending parent owns the narrower rows it replaced. fallbackBookmarks
// bridges only the interval before an in-flight restore attaches those rows.
@property (nonatomic) NSArray<VibeSearchFolder *> *replacedFolders;
@property (nonatomic) NSArray<NSData *> *fallbackBookmarks;
@end

@implementation VibeSearchFolder
- (instancetype)init {
    self = [super init];
    if (self) {
        _replacedFolders = @[];
        _fallbackBookmarks = @[];
    }
    return self;
}
@end

@implementation SearchFolderStore {
    // Main-confined.
    NSMutableArray<VibeSearchFolder *> *_folders;
    // Bookmark resolution and minting are file-provider IPC — seconds on a cloud
    // folder — so both run here, serially, and only the delivery returns to main.
    dispatch_queue_t _workQueue;
    BOOL _restoreInFlight;
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
        [self releaseScopeTree:folder];
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
    _restoreInFlight = YES;
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
            self->_restoreInFlight = NO;
            // Appended, not assigned: an add made while the resolve was in
            // flight is already in the list and holds its own scope. A resolved
            // folder some root now covers is dropped rather than listed — a row
            // that contributes nothing is a lie.
            for (VibeSearchFolder *folder in resolved) {
                VibeSearchFolder *pendingParent =
                        [self pendingReplacementRootCoveringURL:folder.url];
                if (pendingParent) {
                    pendingParent.replacedFolders =
                            [(pendingParent.replacedFolders ?: @[]) arrayByAddingObject:folder];
                }
                else if (![self isCoveredByAPersistentRoot:folder.url]) {
                    [self->_folders addObject:folder];
                }
                else if (folder.scopeStarted) {
                    [folder.url stopAccessingSecurityScopedResource];
                }
            }
            for (VibeSearchFolder *folder in self->_folders) {
                [self clearFallbackBookmarksInTree:folder];
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
    NSArray<VibeSearchFolder *> *replaced = [_folders objectsAtIndexes:subsumed];
    [_folders removeObjectsAtIndexes:subsumed];

    VibeSearchFolder *folder = [[VibeSearchFolder alloc] init];
    folder.url = url;
    folder.scopeStarted = [url startAccessingSecurityScopedResource];
    folder.replacedFolders = replaced;
    if (_restoreInFlight) {
        folder.fallbackBookmarks = [NSUserDefaults.standardUserDefaults
                arrayForKey:kSearchFolderBookmarksKey] ?: @[];
    }
    [_folders addObject:folder];
    [self persistAndNotify];

    // The bookmark is minted off main. Until it lands the parent is searchable,
    // while the replaced children's bookmarks remain the relaunch state.
    dispatch_async(_workQueue, ^{
        NSData *bookmark = [self bookmarkForURL:url];
        if (!bookmark) {
            // Keep the parent live for this session; its children remain the
            // durable relaunch state.
            return;
        }
        run_on_main_thread({
            // The row may be gone by now, so it is found by identity rather
            // than by the index it had.
            if ([self->_folders containsObject:folder]) {
                folder.bookmark = bookmark;
                for (VibeSearchFolder *replacedFolder in folder.replacedFolders) {
                    [self releaseScopeTree:replacedFolder];
                }
                folder.replacedFolders = @[];
                folder.fallbackBookmarks = @[];
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
    [self releaseScopeTree:folder];
    [_folders removeObjectAtIndex:index];
}

- (void)releaseScopeTree:(VibeSearchFolder *)folder {
    if (folder.scopeStarted) {
        [folder.url stopAccessingSecurityScopedResource];
        folder.scopeStarted = NO;
    }
    for (VibeSearchFolder *replacedFolder in folder.replacedFolders) {
        [self releaseScopeTree:replacedFolder];
    }
}

- (void)clearFallbackBookmarksInTree:(VibeSearchFolder *)folder {
    folder.fallbackBookmarks = @[];
    for (VibeSearchFolder *replacedFolder in folder.replacedFolders) {
        [self clearFallbackBookmarksInTree:replacedFolder];
    }
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

- (VibeSearchFolder *)pendingReplacementRootCoveringURL:(NSURL *)url {
    NSString *path = url.URLByStandardizingPath.path;
    for (VibeSearchFolder *folder in _folders) {
        if (!folder.bookmark && VibeSearchRootCoversPath(
                folder.url.URLByStandardizingPath.path, path)) {
            return folder;
        }
    }
    return nil;
}

#pragma mark - Persistence

- (void)persistAndNotify {
    [self persistBookmarks];
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeSearchFoldersDidChangeNotification object:self];
}

- (void)persistBookmarks {
    NSMutableArray<NSData *> *bookmarks = [NSMutableArray array];
    NSMutableSet<NSData *> *seen = [NSMutableSet set];
    for (VibeSearchFolder *folder in _folders) {
        [self appendDurableBookmarksForFolder:folder toArray:bookmarks seen:seen];
    }
    if (bookmarks.count > 0) {
        [NSUserDefaults.standardUserDefaults setObject:bookmarks forKey:kSearchFolderBookmarksKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kSearchFolderBookmarksKey];
    }
}

// A pending parent persists the children it replaced. The live list stays
// minimal while relaunch recovery remains transactional until the new grant is
// durable.
- (void)appendDurableBookmarksForFolder:(VibeSearchFolder *)folder
                                toArray:(NSMutableArray<NSData *> *)bookmarks
                                   seen:(NSMutableSet<NSData *> *)seen {
    if (folder.bookmark) {
        if (![seen containsObject:folder.bookmark]) {
            [seen addObject:folder.bookmark];
            [bookmarks addObject:folder.bookmark];
        }
        return;
    }
    for (VibeSearchFolder *replacedFolder in folder.replacedFolders) {
        [self appendDurableBookmarksForFolder:replacedFolder toArray:bookmarks seen:seen];
    }
    for (NSData *bookmark in folder.fallbackBookmarks) {
        if ([bookmark isKindOfClass:NSData.class] && ![seen containsObject:bookmark]) {
            [seen addObject:bookmark];
            [bookmarks addObject:bookmark];
        }
    }
}

@end
