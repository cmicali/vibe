//
//  FolderAccessManager.h
//  Vibe
//
//  Persistent sandbox access to user-granted folders. Every folder the user
//  opens, drags in, or adds through Settings > Permissions is stored as an
//  app-scoped security bookmark and re-opened on the next launch, so a grant
//  survives relaunches instead of lasting one session. ~/Music needs none of
//  this: the com.apple.security.assets.music entitlement covers it standing.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread whenever the granted-folder list changes.
extern NSNotificationName const FolderAccessManagerDidChangeNotification;

@interface FolderAccessManager : NSObject

+ (instancetype)sharedInstance;

// The granted folders' paths, in the order they were added. Main thread.
@property (nonatomic, readonly) NSArray<NSString *> *grantedFolderPaths;

// Resolves every stored bookmark and starts its security scope, each on its
// own background block so one unreachable mount cannot stall the grants
// behind it. Call once at launch. completion runs on the main thread once
// every scope has started — or at a short deadline, because a launch open
// gated on it cannot usefully wait out an automounter timeout.
- (void)restoreGrantedAccessWithCompletion:(void (^_Nullable)(void))completion;

// The auto-add sink for every open path: bookmarks the directories among the
// URLs, skipping files, folders already covered by an existing grant, and
// anything under ~/Music. The caller must currently hold access (a drag,
// open panel, or Launch Services grant), or bookmark creation fails and the
// URL is skipped. Main thread; the file I/O runs in the background.
- (void)noteOpenedURLs:(NSArray<NSURL *> *)urls;

// Drops the grant at the pane's row index: stops the security scope and
// forgets the bookmark. Main thread.
- (void)removeFolderAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
