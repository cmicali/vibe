//
//  FavoritesStore.m
//  Vibe (iOS)
//

#import "FavoritesStore.h"

#import "FileSearchRules.h"

NSNotificationName const VibeFavoritesDidChangeNotification =
        @"VibeFavoritesDidChangeNotification";

// An iOS app-layer key beside FolderSession's, SearchFolderStore's and
// PlayerDisplaySettings', not an AppSettings property: the shared settings file
// stays untouched, and there is no macOS counterpart to keep it in step with.
static NSString *const kFavoriteFoldersKey = @"VibeiOSFavoriteFolders";
static NSString *const kFavoriteNameKey = @"name";
static NSString *const kFavoriteLocationKey = @"location";
static NSString *const kFavoritePathKey = @"path";
static NSString *const kFavoriteBookmarkKey = @"bookmark";
static const NSInteger kMaximumConcurrentScopeResolutions = 3;

@interface FavoriteFolder ()
// Kept beside the drawn strings rather than resolved from the path: a
// bookmark is what survives a move, and the path is only the identity.
@property (nonatomic) NSData *bookmark;
// The search scope's half: set once prepareSearchScope has resolved this row,
// with its scope held for the session and released when the row goes.
@property (nonatomic) NSURL *resolvedURL;
@property (nonatomic) BOOL scopeStarted;
- (instancetype)initWithName:(NSString *)name
                    location:(NSString *)location
                        path:(NSString *)path
                    bookmark:(NSData *)bookmark;
- (NSDictionary *)persistentRepresentation;
+ (nullable FavoriteFolder *)folderFromPersistentRepresentation:(id)value;
@end

@interface FavoritesStore ()
- (instancetype)initPrivate;
@end

@implementation FavoriteFolder

- (instancetype)initWithName:(NSString *)name
                    location:(NSString *)location
                        path:(NSString *)path
                    bookmark:(NSData *)bookmark {
    self = [super init];
    if (self) {
        _name = [name copy];
        _location = [location copy];
        _path = [path copy];
        _bookmark = bookmark;
    }
    return self;
}

- (NSDictionary *)persistentRepresentation {
    return @{
        kFavoriteNameKey: _name,
        kFavoriteLocationKey: _location,
        kFavoritePathKey: _path,
        kFavoriteBookmarkKey: _bookmark
    };
}

+ (FavoriteFolder *)folderFromPersistentRepresentation:(id)value {
    if (![value isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary *record = value;
    NSString *name = record[kFavoriteNameKey];
    NSString *location = record[kFavoriteLocationKey];
    NSString *path = record[kFavoritePathKey];
    NSData *bookmark = record[kFavoriteBookmarkKey];
    // A record missing its path or bookmark is a row that cannot be identified
    // or opened, so it is dropped rather than drawn.
    if (![name isKindOfClass:NSString.class] || ![location isKindOfClass:NSString.class]
            || ![path isKindOfClass:NSString.class] || path.length == 0
            || ![bookmark isKindOfClass:NSData.class]) {
        return nil;
    }
    return [[FavoriteFolder alloc] initWithName:name location:location
                                           path:path bookmark:bookmark];
}

@end

@implementation FavoritesStore {
    // Main-confined. Loaded once at first use: unlike SearchFolderStore there
    // is nothing to resolve, so the list is complete the moment it is read.
    NSMutableArray<FavoriteFolder *> *_favorites;
    // Resolution is provider IPC and never runs on main. Serial, because a tap
    // is one open and the user cannot be waiting on two.
    dispatch_queue_t _resolveQueue;
    // Search-scope resolution is independent of a tap's, and bounded, so one
    // stalled provider cannot hold every other starred folder out of the walk.
    NSOperationQueue *_scopeQueue;
    BOOL _searchScopePrepared;
}

+ (FavoritesStore *)shared {
    static FavoritesStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[FavoritesStore alloc] initPrivate];
    });
    return shared;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _favorites = [NSMutableArray array];
        for (id value in [NSUserDefaults.standardUserDefaults arrayForKey:kFavoriteFoldersKey]) {
            FavoriteFolder *folder = [FavoriteFolder folderFromPersistentRepresentation:value];
            if (folder) {
                [_favorites addObject:folder];
            }
        }
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        _resolveQueue = dispatch_queue_create("FavoritesStore.resolve", attributes);

        _scopeQueue = [[NSOperationQueue alloc] init];
        _scopeQueue.name = @"FavoritesStore.scope";
        _scopeQueue.qualityOfService = NSQualityOfServiceUtility;
        _scopeQueue.maxConcurrentOperationCount = kMaximumConcurrentScopeResolutions;
    }
    return self;
}

#pragma mark - Reading

- (NSArray<FavoriteFolder *> *)favorites {
    return [_favorites copy];
}

- (BOOL)containsFolderURL:(NSURL *)url {
    return [self indexOfPath:url.URLByStandardizingPath.path] != NSNotFound;
}

- (NSUInteger)indexOfPath:(NSString *)path {
    if (path.length == 0) {
        return NSNotFound;
    }
    return [_favorites indexOfObjectPassingTest:^BOOL(FavoriteFolder *folder,
                                                      NSUInteger index, BOOL *stop) {
        return [folder.path isEqualToString:path];
    }];
}

#pragma mark - Adding and removing

- (void)addFolderURL:(NSURL *)url bookmark:(NSData *)bookmark {
    NSString *path = url.URLByStandardizingPath.path;
    if (path.length == 0 || !bookmark || [self indexOfPath:path] != NSNotFound) {
        return;
    }
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *name = [files displayNameAtPath:url.path] ?: url.lastPathComponent;
    NSURL *parent = url.URLByStandardizingPath.URLByDeletingLastPathComponent;
    // Empty rather than the volume root's name when the folder has no parent
    // worth naming: the row drops its second line instead of drawing "/".
    NSString *location = parent.path.length > 1
            ? ([files displayNameAtPath:parent.path] ?: parent.lastPathComponent)
            : @"";
    FavoriteFolder *favorite = [[FavoriteFolder alloc] initWithName:name location:location
                                                               path:path bookmark:bookmark];
    [_favorites addObject:favorite];
    // A folder starred after the search screen has been visited joins the scope
    // now; before that, prepareSearchScope will reach it with the rest.
    if (_searchScopePrepared) {
        [self resolveScopeForFavorite:favorite];
    }
    [self persistAndNotify];
}

- (void)removeFolderURL:(NSURL *)url {
    NSUInteger index = [self indexOfPath:url.URLByStandardizingPath.path];
    if (index != NSNotFound) {
        [self removeFavoriteAtIndex:index];
    }
}

- (void)removeFavoriteAtIndex:(NSUInteger)index {
    if (index >= _favorites.count) {
        return;
    }
    FavoriteFolder *favorite = _favorites[index];
    [_favorites removeObjectAtIndex:index];
    [self releaseScopeForFavorite:favorite];
    [self persistAndNotify];
}

#pragma mark - Resolving

- (void)resolveFavorite:(FavoriteFolder *)favorite
             completion:(void (^)(NSURL *_Nullable folderURL))completion {
    NSData *bookmark = favorite.bookmark;
    dispatch_async(_resolveQueue, ^{
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:&error];
        if (!url) {
            LogWarn(@"FavoritesStore: bookmark for %@ no longer resolves (%@)",
                    favorite.path, error);
        }
        NSData *refreshed = (url && stale) ? [self mintBookmarkForURL:url] : nil;
        run_on_main_thread({
            if (refreshed) {
                [self refreshBookmark:refreshed forFavorite:favorite];
            }
            completion(url);
        });
    });
}

// Resolve queue only. Minting needs the scope OPEN, so a stale bookmark can be
// refreshed only after resolving — the ordering FolderSession documents too.
// The scope is stopped again immediately: this store holds none, and the adopt
// that follows the tap starts its own on the same URL.
- (NSData *)mintBookmarkForURL:(NSURL *)url {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (scoped) {
        [url stopAccessingSecurityScopedResource];
    }
    if (!bookmark) {
        LogWarn(@"FavoritesStore: could not refresh a stale bookmark for %@ (%@)", url, error);
    }
    return bookmark;
}

// Silent: the row's drawn strings do not change, so nothing has to reload. A
// favorite removed while its refresh was in flight keeps the removal.
- (void)refreshBookmark:(NSData *)bookmark forFavorite:(FavoriteFolder *)favorite {
    if ([_favorites indexOfObjectIdenticalTo:favorite] == NSNotFound) {
        return;
    }
    favorite.bookmark = bookmark;
    [self persistFavorites];
}

#pragma mark - The search scope

- (NSArray<NSURL *> *)searchRoots {
    NSMutableArray<NSURL *> *roots = [NSMutableArray array];
    for (FavoriteFolder *favorite in _favorites) {
        if (favorite.resolvedURL) {
            [roots addObject:favorite.resolvedURL];
        }
    }
    return roots;
}

- (NSURL *)resolvedRootCoveringURL:(NSURL *)url {
    NSString *path = url.URLByStandardizingPath.path;
    NSURL *best = nil;
    for (FavoriteFolder *favorite in _favorites) {
        if (!favorite.resolvedURL) {
            continue;
        }
        // Longest match, so a starred subfolder wins over a starred parent —
        // both are legitimate rows here, unlike in SearchFolderStore.
        if (VibeSearchRootCoversPath(favorite.path, path)
                && (!best || favorite.path.length > best.URLByStandardizingPath.path.length)) {
            best = favorite.resolvedURL;
        }
    }
    return best;
}

- (void)prepareSearchScope {
    _searchScopePrepared = YES;
    for (FavoriteFolder *favorite in _favorites) {
        [self resolveScopeForFavorite:favorite];
    }
}

// One operation per row, each publishing on its own. A favorite whose bookmark
// is gone simply never becomes a root: the row stays, because it is still a
// place the user asked to keep, and tapping it says so with the alert.
- (void)resolveScopeForFavorite:(FavoriteFolder *)favorite {
    if (favorite.resolvedURL) {
        return;
    }
    NSData *bookmark = favorite.bookmark;
    [_scopeQueue addOperationWithBlock:^{
        BOOL stale = NO;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:NULL];
        // A NO return is not failure — the app's own container is not
        // security-scoped. Record what was started, for the balanced stop.
        BOOL scoped = url ? [url startAccessingSecurityScopedResource] : NO;
        run_on_main_thread({
            if (!url) {
                return;
            }
            // The row can have gone while the provider was thinking.
            if ([self->_favorites indexOfObjectIdenticalTo:favorite] == NSNotFound) {
                if (scoped) {
                    [url stopAccessingSecurityScopedResource];
                }
                return;
            }
            favorite.resolvedURL = url;
            favorite.scopeStarted = scoped;
            [NSNotificationCenter.defaultCenter
                    postNotificationName:VibeFavoritesDidChangeNotification object:self];
        });
    }];
}

// Unlike SearchFolderStore's, this scope needs no refcounted grant handed to
// the playlist, because FolderSession never reads on the strength of it: a
// favorite tapped on its own tab goes through adoptURL:, and a search hit
// inside one goes through openFileFromSearchRoots:, which asks
// resolvedRootCoveringURL: and then takes a hold of its OWN. Both own their
// readability, so dropping this one cannot leave a playlist unreadable.
- (void)releaseScopeForFavorite:(FavoriteFolder *)favorite {
    if (favorite.scopeStarted) {
        [favorite.resolvedURL stopAccessingSecurityScopedResource];
        favorite.scopeStarted = NO;
    }
    favorite.resolvedURL = nil;
}

#pragma mark - Persistence

- (void)persistAndNotify {
    [self persistFavorites];
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeFavoritesDidChangeNotification object:self];
}

- (void)persistFavorites {
    if (_favorites.count == 0) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kFavoriteFoldersKey];
        return;
    }
    NSMutableArray<NSDictionary *> *records =
            [NSMutableArray arrayWithCapacity:_favorites.count];
    for (FavoriteFolder *folder in _favorites) {
        [records addObject:[folder persistentRepresentation]];
    }
    [NSUserDefaults.standardUserDefaults setObject:records forKey:kFavoriteFoldersKey];
}

@end
