//
//  FavoritesStore.m
//  Vibe (iOS)
//

#import "FavoritesStore.h"

#import "FileSearchRules.h"

NSNotificationName const VibeFavoritesDidChangeNotification =
        @"VibeFavoritesDidChangeNotification";

// iOS app-layer state, so not AppSettings.
static NSString *const kFavoriteFoldersKey = @"VibeiOSFavoriteFolders";
static NSString *const kFavoriteNameKey = @"name";
static NSString *const kFavoriteLocationKey = @"location";
static NSString *const kFavoritePathKey = @"path";
static NSString *const kFavoriteBookmarkKey = @"bookmark";
static const NSInteger kMaximumConcurrentScopeResolutions = 3;

@interface FavoriteFolder ()
// A bookmark survives a move; the path is only the identity.
@property (nonatomic) NSData *bookmark;
// Set once prepareSearchScope resolves the row; its scope is held until the
// row goes.
@property (nonatomic) NSURL *resolvedURL;
// Standardized off main: coverage is tested per URL of every open, and a moved
// folder's hits live under here, not under path.
@property (nonatomic) NSString *resolvedPath;
@property (nonatomic) BOOL scopeStarted;
// resolvedURL lands late, so it cannot be the already-asked test: every
// re-apply would enqueue another resolve, two starts against one stop.
@property (nonatomic) BOOL scopeResolveInFlight;
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
    // Main-confined; complete the moment it is read.
    NSMutableArray<FavoriteFolder *> *_favorites;
    // Serial: a tap is one open.
    dispatch_queue_t _resolveQueue;
    // Bounded and apart from a tap's, so one stalled provider cannot hold
    // every starred folder out of the walk.
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
    // Empty rather than "/": the row drops its second line.
    NSString *location = parent.path.length > 1
            ? ([files displayNameAtPath:parent.path] ?: parent.lastPathComponent)
            : @"";
    FavoriteFolder *favorite = [[FavoriteFolder alloc] initWithName:name location:location
                                                               path:path bookmark:bookmark];
    [_favorites addObject:favorite];
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

// Resolve queue only. Minting needs the scope OPEN, so a stale bookmark is
// refreshed after resolving; the scope stops at once, since the adopt that
// follows starts its own.
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

// Silent: nothing drawn changes.
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
    FavoriteFolder *best = nil;
    for (FavoriteFolder *favorite in _favorites) {
        // Longest match: nesting is legitimate here.
        if (VibeSearchRootCoversPath(favorite.resolvedPath, path)
                && favorite.resolvedPath.length > best.resolvedPath.length) {
            best = favorite;
        }
    }
    return best.resolvedURL;
}

- (void)prepareSearchScope {
    _searchScopePrepared = YES;
    for (FavoriteFolder *favorite in _favorites) {
        [self resolveScopeForFavorite:favorite];
    }
}

// A favorite that no longer resolves never becomes a root, but the row stays.
- (void)resolveScopeForFavorite:(FavoriteFolder *)favorite {
    if (favorite.resolvedURL || favorite.scopeResolveInFlight) {
        return;
    }
    favorite.scopeResolveInFlight = YES;
    NSData *bookmark = favorite.bookmark;
    [_scopeQueue addOperationWithBlock:^{
        BOOL stale = NO;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                               options:0
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&stale
                                                 error:NULL];
        // NO is not failure: the app's own container is not security-scoped.
        BOOL scoped = url ? [url startAccessingSecurityScopedResource] : NO;
        NSString *resolvedPath = url.URLByStandardizingPath.path;
        run_on_main_thread({
            favorite.scopeResolveInFlight = NO;
            if (!url) {
                return;
            }
            if ([self->_favorites indexOfObjectIdenticalTo:favorite] == NSNotFound) {
                if (scoped) {
                    [url stopAccessingSecurityScopedResource];
                }
                return;
            }
            favorite.resolvedURL = url;
            favorite.resolvedPath = resolvedPath;
            favorite.scopeStarted = scoped;
            [NSNotificationCenter.defaultCenter
                    postNotificationName:VibeFavoritesDidChangeNotification object:self];
        });
    }];
}

// No refcounted grant, unlike SearchFolderStore: FolderSession always takes a
// hold of its OWN, so dropping this scope cannot strand a playlist.
- (void)releaseScopeForFavorite:(FavoriteFolder *)favorite {
    // A resolve in flight checks membership and releases its own hold.
    if (favorite.scopeStarted) {
        [favorite.resolvedURL stopAccessingSecurityScopedResource];
        favorite.scopeStarted = NO;
    }
    favorite.resolvedURL = nil;
    favorite.resolvedPath = nil;
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
