//
//  FolderAccessManager.h
//  Vibe
//
//  Persistent sandbox access to user-granted folders. Every folder the user
//  opens, drags in, or adds through Settings > Files is stored as an
//  app-scoped security bookmark and re-opened on the next launch, so a grant
//  survives relaunches instead of lasting one session. ~/Music needs none of
//  this: the com.apple.security.assets.music.read-write entitlement covers it
//  standing.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread whenever the granted-folder list changes — a grant
// added or removed, and each time restoration settles a batch of them.
extern NSNotificationName const FolderAccessManagerDidChangeNotification;

typedef NS_ENUM(NSInteger, VibeGrantedFolderState) {
    // The security scope is started, or a grant taken in this process covers
    // it: the app can read inside the folder now.
    VibeGrantedFolderStateActive,
    // Remembered, not yet settled. Its bookmark is still resolving, or the
    // launch restore has not reached it.
    VibeGrantedFolderStateRestoring,
    // The bookmark did not resolve, or the scope was refused: the folder is
    // gone, renamed, or on an unmounted volume. The row is kept anyway — those
    // cases are indistinguishable from here, and dropping the grant for an
    // unplugged drive would make the user re-pick it.
    VibeGrantedFolderStateUnavailable,
};

// One row of the granted-folder list. A snapshot: the state it carries is the
// one at the moment it was asked for.
@interface VibeGrantedFolder : NSObject
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) VibeGrantedFolderState state;
@end

@interface FolderAccessManager : NSObject

+ (instancetype)sharedInstance;

// The granted folders, in the order they were added. Main thread.
@property (nonatomic, readonly) NSArray<VibeGrantedFolder *> *grantedFolders;

// Whether the app may read inside this directory: it is under an active scope
// or under ~/Music. A stored bookmark does not count until restoration starts
// its scope. **Any thread** — it reads an immutable snapshot, unlike
// grantedFolders — so background work can decide *not* to touch a folder rather
// than being denied at the syscall. A denial is silent, but the protected
// folders (Desktop, Documents, Downloads, removable and network volumes) answer
// an unsanctioned read with a system consent panel, and no background scan
// should raise one. A NO answer can be stale by one grant;
// FolderAccessManagerDidChangeNotification is the signal to reconsider.
- (BOOL)canReadInsideDirectory:(nullable NSString *)path;

// Resolves every stored bookmark and starts its security scope on a bounded
// background scheduler. A queued grant that an open needs is promoted ahead of
// unrelated queued work. Call once at launch. completion runs on the main
// thread once every scope has started — or at a short deadline, because a
// launch open gated on it cannot usefully wait out an automounter timeout.
- (void)restoreGrantedAccessWithCompletion:(void (^_Nullable)(void))completion;

// Runs completion on the main thread once every url is covered by an active
// grant, or has no covering restoration left — or at the same deadline
// restoreGrantedAccessWithCompletion: uses, whichever comes first. Of nested
// covering grants, the most specific queued one is promoted first; an active
// child satisfies the wait even while a stale parent is still resolving. An
// open unrelated to any restoring grant runs synchronously, right now.
//
// The deadline is not optional: a bookmark on an unreachable mount can take an
// automounter timeout to resolve, or never resolve at all, and an open held
// behind it forever would leave the window in its launch grace — blank header,
// nothing playing, no way out. Waiting is an optimization; proceeding without
// the grant merely risks an unreadable folder, which every open path already
// handles.
- (void)awaitRestoredAccessForURLs:(NSArray<NSURL *> *)urls
                        completion:(dispatch_block_t)completion;

// The auto-add sink for every open path: bookmarks the directories among the
// URLs, skipping files, folders already covered by an existing grant, and
// anything under ~/Music. The caller must currently hold access (a drag,
// open panel, or Launch Services grant), or bookmark creation fails and the
// URL is skipped. Main thread; the file I/O runs in the background.
- (void)noteOpenedURLs:(NSArray<NSURL *> *)urls;

// Drops the grants at the pane's row indexes: stops each security scope and
// forgets the bookmarks, posting one change notification for the batch.
// Main thread.
- (void)removeFoldersAtIndexes:(NSIndexSet *)indexes;

// The grant a playlist file needs for the folder its entries live in — opening
// the .m3u grants the .m3u alone — is the one thing here that ASKS rather than
// stores, so it lives in FolderAccessManager+GrantPanel.h. NSURLUtil reaches
// it through the handler AppDelegate installs, rather than importing either.

// Whether path is one of grantedPaths, sits under one, or is under ~/Music,
// which the entitlement covers standing. Compares alias-free spellings, so /tmp
// and /private/tmp — or a data-volume firmlink path and its plain form — are one
// directory: only one of the two ever reaches the grant list, depending on how
// the file was opened. Pure; the auto-add's duplicate-check rule, and
// case-SENSITIVE because both sides are canonical there.
+ (BOOL)path:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths;

// The same rule for a *read* test, where the path is a directory taken off a
// track URL and so carries whatever spelling its opener supplied. Folds case;
// see the implementation. This is what canReadInsideDirectory: applies.
+ (BOOL)readablePath:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths;

// The user's on-disk home, which is NOT what NSHomeDirectory or
// NSHomeDirectoryForUser answer inside the sandbox — both give the container.
+ (NSString *)realHomeDirectory;

@end

NS_ASSUME_NONNULL_END
