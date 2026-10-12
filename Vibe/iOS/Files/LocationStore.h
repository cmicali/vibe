//
//  LocationStore.h
//  Vibe (iOS)
//
//  The Files tab's Locations: the folders the user granted the app, kept as
//  persisted bookmarks. Each scope starts at launch and is held for the
//  session. The Files tab lists them, and Search walks them. It also names
//  every folder the app shows. The iOS twin of the mac's FolderAccessManager.
//
//  Main thread only. Resolution is bounded and concurrent and minting has its
//  own queue, so one slow provider cannot hold every row.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main whenever folderURLs changes; restored roots can arrive after
// a screen has appeared.
extern NSNotificationName const VibeSearchFoldersDidChangeNotification;

@interface LocationStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// A singleton: a second instance would hold a second set of scopes.
@property (class, nonatomic, readonly) LocationStore *shared;

// Settings' rows, in order; grows as launch restorations settle.
@property (nonatomic, readonly) NSArray<NSURL *> *folderURLs;

// The app's own Documents directory, readable with no grant.
@property (class, nonatomic, readonly) NSURL *containerDocumentsURL;

// folderURLs plus Documents, which needs no grant. Documents is here, among the
// permanent roots, because addFolderURL: tests coverage against those alone.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

// Once at launch, beside restore-or-adopt; opens and plays nothing.
- (void)restorePersistedFolders;

// NO: a persistent root already covers it. A folder that COVERS existing rows
// replaces them.
- (BOOL)addFolderURL:(NSURL *)url;

- (void)removeFolderAtIndex:(NSUInteger)index;

// Main only, and never the disk. The one name a folder is shown under,
// wherever it is named: the two roots with no name of their own on disk read
// "On My iPhone" and "Dropbox", a location its name resolved with its
// bookmark, and any other folder its own path component.
+ (NSString *)displayNameForFolderURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
