//
//  SearchFolderStore.h
//  Vibe (iOS)
//
//  The folders the user has handed the app to search, and the grants that make
//  them readable: a persisted list of security-scoped bookmarks, each one's
//  scope started at launch and held for the session.
//
//  It exists because search can only reach what the app holds. There is no
//  public API that searches the Files app (see FileSearchIndex.h), so the way to
//  widen the scope is to widen the grants — and this is the settings screen's
//  half of that. It is the iOS twin of the mac's FolderAccessManager: the same
//  job, the folders the app keeps access to, listed in a settings pane.
//
//  A folder here is search scope and nothing else. It is not a second way to
//  open something — tapping a search hit already opens its folder as the
//  playlist, so a folder in this list becomes playable through search without
//  this list competing with the Files tab.
//
//  Main thread only. Bookmark resolution is bounded and concurrent, bookmark
//  minting has its own queue, and every delivery lands back here. One slow
//  provider therefore cannot hold every restored row or a newly added folder.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main whenever folderURLs changes — an add, a remove, or one launch
// restoration landing. The search screen re-reads its roots on this: restored
// roots can arrive AFTER that screen has appeared.
extern NSNotificationName const VibeSearchFoldersDidChangeNotification;

@interface SearchFolderStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// One list for the app. A singleton like FolderAccessManager, and for the same
// reason: it holds process-wide grants, and a second one would hold a second set
// of scopes for the same folders.
@property (class, nonatomic, readonly) SearchFolderStore *shared;

// The folders the user added, in that order — exactly the rows Settings shows.
// Starts empty and grows as independent launch restorations settle.
@property (nonatomic, readonly) NSArray<NSURL *> *folderURLs;

// Every root that is searchable no matter what is open: folderURLs plus the
// app's own Documents directory, which is what the Files app shows as "On My
// iPhone -> Vibe" and needs no grant at all. The transient half of the scope is
// FolderSession.searchRoot, and PlaybackController.searchRoots composes them.
//
// Documents is deliberately here rather than beside the session's root: it is a
// permanent fact about the app, and coverage — what addFolderURL: refuses as
// redundant — has to be tested against the permanent roots and only those.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

// Independently resolves persisted bookmarks and starts their scopes. Rows
// appear as each bookmark settles; the scene delegate calls this once at
// launch, beside its restore-or-adopt. It is not exclusive with either, since
// it opens nothing and plays nothing.
- (void)restorePersistedFolders;

// Adds a folder the document picker just granted. NO means nothing was added
// because a persistent root already covers it — a grant reaches the whole
// subtree, so a subfolder of one buys nothing, and neither does anything inside
// the app's own Documents. A folder that COVERS existing rows replaces them.
- (BOOL)addFolderURL:(NSURL *)url;

- (void)removeFolderAtIndex:(NSUInteger)index;

// The folder's name as the Files app spells it, for the settings row.
- (NSString *)displayNameForFolderAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
