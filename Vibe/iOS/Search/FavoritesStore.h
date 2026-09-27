//
//  FavoritesStore.h
//  Vibe (iOS)
//
//  The folders the user starred: places to go back to. Not SearchFolderStore's
//  twin; three differences are the design:
//
//  1. NOTHING IS RESOLVED AT LAUNCH. Rows draw from strings recorded at star
//     time, so favorites cost no provider I/O at launch and a signed-out
//     provider still renders. A tap, or the search screen, resolves.
//  2. NESTING IS ALLOWED: a parent and a child are two places to open, so
//     identity is exact standardized-path equality. VibeSearchRootCoversPath
//     would be the bug here.
//  3. A ROW IS NEVER ADDED WITHOUT ITS BOOKMARK. Minting needs the scope open,
//     which only FolderSession can promise, so the caller brings the bookmark.
//
//  Main thread only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main on an add, a remove, or a search-scope resolve landing.
extern NSNotificationName const VibeFavoritesDidChangeNotification;

// Recorded at star time, so a row needs no file system to render.
@interface FavoriteFolder : NSObject

@property (nonatomic, readonly) NSString *name;
// The containing folder's name, telling two "Disc 1"s apart; may be empty.
@property (nonatomic, readonly) NSString *location;
// Standardized; the identity.
@property (nonatomic, readonly) NSString *path;

@end

@interface FavoritesStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (class, nonatomic, readonly) FavoritesStore *shared;

// In star order.
@property (nonatomic, readonly) NSArray<FavoriteFolder *> *favorites;

- (BOOL)containsFolderURL:(NSURL *)url;

// The bookmark comes from one of FolderSession's two minters. Starring an
// already-starred folder is a no-op.
- (void)addFolderURL:(NSURL *)url bookmark:(NSData *)bookmark;

// Unknown URLs are a no-op.
- (void)removeFolderURL:(NSURL *)url;

- (void)removeFavoriteAtIndex:(NSUInteger)index;

// Off main; completion on main, nil when it no longer resolves. The caller's
// open starts its own scope. Takes the favorite, not an index, so a row removed
// mid-resolve cannot redirect the open to its neighbor.
- (void)resolveFavorite:(FavoriteFolder *)favorite
             completion:(void (^)(NSURL *_Nullable folderURL))completion;

#pragma mark - The search scope

// Empty until prepareSearchScope; grows as each resolve lands.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

// Resolves every favorite and holds its scope for the session. Idempotent.
// Called when the SEARCH SCREEN APPEARS, never at launch, so roots arrive
// after it is up and Search re-reads them on the notification.
- (void)prepareSearchScope;

// Longest match against where each bookmark resolved, never the star-time
// path, or nil. FolderSession takes a hold of its OWN on the answer,
// so removing a favorite can drop this store's scope safely.
- (nullable NSURL *)resolvedRootCoveringURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
