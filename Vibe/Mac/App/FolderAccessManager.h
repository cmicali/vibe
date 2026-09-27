//
//  FolderAccessManager.h
//  Vibe
//
//  Every folder the user opens, drops or adds in Settings > Files is stored as
//  an app-scoped security bookmark and re-opened at launch. ~/Music needs none:
//  the music read-write entitlement covers it standing.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on main when a grant is added or removed and as restoration settles.
extern NSNotificationName const FolderAccessManagerDidChangeNotification;

typedef NS_ENUM(NSInteger, VibeGrantedFolderState) {
    // The security scope is started, or a grant taken in this process covers
    // it: the app can read inside the folder now.
    VibeGrantedFolderStateActive,
    // Remembered, not yet settled. Its bookmark is still resolving, or the
    // launch restore has not reached it.
    VibeGrantedFolderStateRestoring,
    // The bookmark did not resolve or the scope was refused. Kept: an
    // unplugged drive is indistinguishable from a deleted folder here.
    VibeGrantedFolderStateUnavailable,
};

// A snapshot: the state at the moment it was asked for.
@interface VibeGrantedFolder : NSObject
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) VibeGrantedFolderState state;
@end

@interface FolderAccessManager : NSObject

+ (instancetype)sharedInstance;

// The granted folders, in the order they were added. Main thread.
@property (nonatomic, readonly) NSArray<VibeGrantedFolder *> *grantedFolders;

// Under an active scope or ~/Music; a stored bookmark does not count until
// restoration starts its scope. Any thread, so background work can decline to
// touch a folder: an unsanctioned read of a protected folder raises a system
// consent panel. A NO can be stale by one grant; the change notification is
// the signal to reconsider.
- (BOOL)canReadInsideDirectory:(nullable NSString *)path;

// Call once at launch. completion runs on main once every scope has started,
// or at a short deadline: a launch open cannot usefully wait out an
// automounter timeout.
- (void)restoreGrantedAccessWithCompletion:(void (^_Nullable)(void))completion;

// Runs completion on main once every url is covered by an active grant or has
// no covering restoration left, or at the restore's deadline. The most
// specific covering grant is promoted first. An open no restoration covers
// completes synchronously. The deadline is not optional: an open held behind
// a dead mount would leave the window in its launch grace for good.
- (void)awaitRestoredAccessForURLs:(NSArray<NSURL *> *)urls
                        completion:(dispatch_block_t)completion;

// Bookmarks the directories among urls not already covered. The caller must
// hold access now (drag, panel, Launch Services), or the URL is skipped. Main
// thread; the I/O runs in the background.
- (void)noteOpenedURLs:(NSArray<NSURL *> *)urls;

// One change notification for the batch. Main thread.
- (void)removeFoldersAtIndexes:(NSIndexSet *)indexes;

// Asking for a grant is FolderAccessManager+GrantPanel.h.

// At or under one of grantedPaths, or under ~/Music. Compares alias-free
// spellings (/tmp and /private/tmp, firmlink paths). The auto-add's duplicate
// check: case-SENSITIVE, because both sides are canonical there.
+ (BOOL)path:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths;

// The read test (canReadInsideDirectory:), for a path in whatever spelling its
// opener supplied: folds case.
+ (BOOL)readablePath:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths;

// Not NSHomeDirectory, which answers the container inside the sandbox.
+ (NSString *)realHomeDirectory;

@end

NS_ASSUME_NONNULL_END
