//
//  FolderSessionInternal.h
//  Vibe (iOS)
//
//  The private surface FolderSession.m and its +ExternalOpens and +Persistence
//  categories share: the session's state, its stored keys, and the methods
//  each side calls on the other. No other file imports it.
//

#import "FolderSession.h"
#import "FolderWalk.h"
#import <stdatomic.h>

@class LocationGrant;

// iOS app-layer state, so not AppSettings.
static NSString *const kFolderBookmarkKey = @"VibeiOSFolderBookmark";
static NSString *const kAdditionBookmarksKey = @"VibeiOSAdditionBookmarks";
// Holds a standardized path despite its name: the shipped key is kept so a
// bare filename an older build wrote restores through the filename tier.
static NSString *const kLastTrackPathKey = @"VibeiOSLastTrackFileName";

@interface FolderSession () {
    // Every scope this session started, held for the session (the player,
    // TagLib and the waveform loader read under them at any time) and released
    // only once a successor set is in hand. Main-confined. A URL may appear
    // twice, each start balanced by its own stop.
    NSMutableArray<NSURL *> *_scopedURLs;
    // Persistent-root grants retained for this playlist, same lifetime.
    NSMutableArray<LocationGrant *> *_searchGrants;
    // The BASE: title, star, bookmark. Appends never move it; nil for a
    // single-file base.
    NSURL *_folderURL;
    // Search roots only — never the title or the star.
    NSMutableArray<NSURL *> *_addedFolderURLs;
    // YES when this session's replace wrote the base bookmark, so the
    // persisted addition list is this session's to extend.
    BOOL _additionsPersisted;
    // Replaces run concurrently so a new intent never waits behind an older
    // provider call; the generation decides which result delivers.
    dispatch_queue_t _workQueue;
    // Serial, so two Adds land in order, but never behind a replace.
    dispatch_queue_t _appendQueue;
    _Atomic(uint64_t) _openIntentGeneration;
    // The last SETTLED replace's generation; an append lands only against it.
    // Zero: nothing has landed, so an Add is promoted to an Open. Main-confined.
    uint64_t _landedOpenIntentGeneration;
    // YES from a promotion until that open settles; later Adds park in
    // _addWaiters. Set only by a promotion, so after a failed launch restore
    // the next Add still plays. Main-confined.
    BOOL _promotedOpenInFlight;
    // The generation a promotion created, or zero; see addURLs:token:.
    uint64_t _promotedOpenIntentGeneration;
    // Waiters, delivered once when the promoted open settles, however it
    // settles. Main-confined.
    NSMutableArray<void (^)(void)> *_addWaiters;
    // hasAdditions' storage, declared so clearSession can reset it.
    BOOL _hasAdditions;
}

- (uint64_t)beginOpenIntent;
- (BOOL)isCurrentOpenIntent:(uint64_t)openIntentGeneration;
- (NSURL *)rootCoveringPath:(NSString *)path in:(NSArray<NSURL *> *)roots;

// The one prologue for every URL list. Main thread, no I/O.
- (void)beginOpenURLs:(NSArray<NSURL *> *)urls
            appending:(BOOL)appending
          expandsFile:(BOOL)expandsFile
        grantedFolder:(NSURL *)grantedFolder;

// Work queue.
- (void)openURLsOnWorkQueue:(NSArray<NSURL *> *)urls
                  appending:(BOOL)appending
                   restored:(BOOL)restored
       keepsSessionBookmark:(BOOL)keepsSessionBookmark
                expandsFile:(BOOL)expandsFile
                   sortedBy:(VibeFolderOpenSort)sort
          coveringRootPaths:(NSArray<NSString *> *)coveringRootPaths
                      holds:(NSArray<NSURL *> *)holds
                     grants:(NSArray<LocationGrant *> *)grants
       openIntentGeneration:(uint64_t)openIntentGeneration;

// Main thread. Every request ends here.
- (BOOL)finishOpenIntent:(uint64_t)openIntentGeneration
               appending:(BOOL)appending
                  tracks:(NSArray<AudioTrack *> *)tracks
               folderURL:(NSURL *)folderURL
            addedFolders:(NSArray<NSURL *> *)addedFolders
             selectedURL:(NSURL *)selectedURL
                restored:(BOOL)restored
             ownedScopes:(NSArray<NSURL *> *)ownedScopes
             ownedGrants:(NSArray<LocationGrant *> *)ownedGrants
            baseBookmark:(NSData *)baseBookmark
       additionBookmarks:(NSArray<NSData *> *)additionBookmarks;

- (void)releaseAddWaitersAfterSettle;

@end

// The private half of FolderSession+Persistence.m.
@interface FolderSession (PersistenceInternal)

- (NSURL *)resolveBookmark:(NSData *)bookmark error:(NSError **)error;
// Requires the scope open.
- (NSData *)bookmarkForURL:(NSURL *)url;
- (void)persistAdditionBookmarks:(NSArray<NSData *> *)additionBookmarks;

@end
