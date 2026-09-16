//
//  FavoritesStore.h
//  Vibe (iOS)
//
//  The folders the user starred, and the bookmarks that reopen them: a
//  persisted list of places to go back to.
//
//  It exists because the app remembers exactly one folder — FolderSession's,
//  overwritten by the next open — so without this the only road back to
//  yesterday's album is another walk through the Files browser.
//
//  It is NOT the iOS twin of SearchFolderStore, and the three differences are
//  the whole design:
//
//  1. NOTHING IS RESOLVED AT LAUNCH. A search folder is scope the app must be
//     able to reach at any moment, so that store resolves every bookmark at
//     launch and holds every scope for the session. The list here draws
//     entirely from the name and location strings recorded when the folder was
//     starred, so any number of favorites cost no provider I/O at launch, the
//     list is complete the moment it is read, and a favorite on a signed-out
//     provider still renders its row. Resolution happens when something needs
//     the folder itself: a tap, or the search screen asking for the scope.
//  2. NESTING IS ALLOWED. SearchFolderStore refuses a subfolder of a listed
//     folder because a grant already reaches it and a row buying nothing is a
//     lie. Here a parent and a child are two different places to open, so
//     identity is exact standardized-path equality and nothing else — reaching
//     for VibeSearchRootCoversPath in this file would be the bug.
//  3. A ROW IS NEVER ADDED WITHOUT ITS BOOKMARK. Minting one needs the folder's
//     security scope open, which only FolderSession can promise, so the caller
//     brings the bookmark and this store only records it. The alternative is a
//     row that draws and cannot be opened.
//
//  Main thread only. Bookmark resolution runs off it, and its result lands
//  back here.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main whenever favorites changes — an add or a remove. The
// Favorites tab reloads on it, and the Playlist tab's star re-reads its state:
// unstarring on one screen has to empty the star on the other.
extern NSNotificationName const VibeFavoritesDidChangeNotification;

// One starred folder, as the list draws it. Immutable, and everything on it was
// recorded at star time so a row needs no file system to render.
@interface FavoriteFolder : NSObject

// The folder's name as the Files app spells it.
@property (nonatomic, readonly) NSString *name;
// The containing folder's name, the row's second line. It is what tells two
// favorites both called "Disc 1" apart. Empty when there is no useful parent.
@property (nonatomic, readonly) NSString *location;
// Standardized path. The identity: what the star tests and what dedupe uses.
@property (nonatomic, readonly) NSString *path;

@end

@interface FavoritesStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// One list for the app, for the same reason SearchFolderStore is a singleton:
// two of them would be two copies of one persisted list, disagreeing.
@property (class, nonatomic, readonly) FavoritesStore *shared;

// In the order they were starred — exactly the rows the Favorites tab shows.
// Read straight from NSUserDefaults at first use; there is nothing to restore.
@property (nonatomic, readonly) NSArray<FavoriteFolder *> *favorites;

// Whether url is already starred. The Playlist tab's star draws from this.
- (BOOL)containsFolderURL:(NSURL *)url;

// Records a folder and the bookmark that reopens it. The bookmark must already
// be minted — see FolderSession.bookmarkOpenFolderWithCompletion:, which is the
// only thing that can, since it owns the scope. Starring an already-starred
// folder is a no-op, which is also what makes a double tap harmless.
- (void)addFolderURL:(NSURL *)url bookmark:(NSData *)bookmark;

// The star's un-favorite. Unknown URLs are a no-op.
- (void)removeFolderURL:(NSURL *)url;

// The swipe.
- (void)removeFavoriteAtIndex:(NSUInteger)index;

// Resolves the bookmark off main and hands back the folder to open, or nil when
// it no longer resolves — a deleted folder, or a provider not signed in. The
// caller opens the URL through the ordinary adoption path, which starts its own
// scope on it; this store holds none afterwards.
//
// Takes the favorite rather than an index so a row removed while a slow
// provider resolves cannot redirect the open to its neighbor.
- (void)resolveFavorite:(FavoriteFolder *)favorite
             completion:(void (^)(NSURL *_Nullable folderURL))completion;

#pragma mark - The search scope

// Every favorite the app can currently read, for PlaybackController.searchRoots
// to compose. Empty until prepareSearchScope has resolved them, and it grows as
// each one lands; nesting among the roots is FileSearchIndex's to prune, so a
// folder that is both starred and added in Settings is walked once.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

// Resolves every favorite's bookmark and holds its scope for the session, so
// the search walk can reach a starred folder without the user having added it
// in Settings as well. Idempotent, and each row lands independently.
//
// It runs when the SEARCH SCREEN APPEARS rather than at launch, because that is
// the moment the walk itself starts and the moment the scope is first worth
// paying for — the other tabs never resolve a thing. Roots therefore arrive
// after that screen is up, which is why the change notification exists and why
// Search re-reads its roots on it rather than only on appearance.
- (void)prepareSearchScope;

// The resolved starred folder whose subtree contains url, longest match first,
// or nil. FolderSession asks it when a search hit is covered by neither a
// SearchFolderStore grant nor the open folder, and then takes a hold of its OWN
// on the answer — which is why removing a favorite can safely drop this store's
// scope, and why there is no refcounted grant here as there is over there.
- (nullable NSURL *)resolvedRootCoveringURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
