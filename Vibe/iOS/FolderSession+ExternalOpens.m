//
//  FolderSession+ExternalOpens.m
//  Vibe (iOS)
//
//  The entry points callers reach: open, add, clear and cancel. Each funnels
//  into the prologue in FolderSession.m.
//

#import "FolderSessionInternal.h"
#import "AudioTrack.h"
#import "FolderSessionRules.h"

@implementation FolderSession (ExternalOpens)

- (void)openURLs:(NSArray<NSURL *> *)urls openInPlace:(BOOL)openInPlace {
    if (!openInPlace) {
        // Skip directory expansion for inbox copies. Read CUE and FLAC rows off main.
        NSURL *url = urls.firstObject;
        if (!url) {
            return;
        }
        uint64_t openIntentGeneration = [self beginOpenIntent];
        dispatch_async(_workQueue, ^{
            NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[FolderWalk entriesForFile:url]];
            run_on_main_thread({
                [self finishOpenIntent:openIntentGeneration appending:NO tracks:rows
                             folderURL:nil addedFolders:@[] selectedURL:nil restored:NO
                           ownedScopes:@[] ownedGrants:@[] baseBookmark:nil additionBookmarks:@[]];
            });
        });
        return;
    }
    [self beginOpenURLs:urls appending:NO expandsFile:YES grantedFolder:nil];
}

- (uint64_t)addRequestToken {
    return atomic_load_explicit(&_openIntentGeneration, memory_order_acquire);
}

- (void)addURLs:(NSArray<NSURL *> *)urls {
    [self addURLs:urls token:[self addRequestToken]];
}

- (void)addURLs:(NSArray<NSURL *> *)urls token:(uint64_t)token {
    // The token is taken when the USER asks, so a favorite whose resolve
    // outlived a replace is dropped rather than appended to the new playlist.
    //
    // TRAP: a PROMOTION is not a supersession. Promoting the first of several
    // Adds onto an empty playlist bumps the generation; without this exemption
    // its siblings are dropped here before they can park as waiters (seconds
    // on a cold provider). A token one below the live promoted generation is
    // still the user's; a real replace or a clear bumps past it.
    if (!VibeFolderSessionAddTokenIsCurrent(token, [self addRequestToken],
                                            _promotedOpenIntentGeneration)) {
        LogInfo(@"FolderSession: dropping an Add superseded while its URL resolved");
        return;
    }
    [self beginOpenURLs:urls appending:YES expandsFile:NO grantedFolder:nil];
}

- (void)openURL:(NSURL *)url inFolder:(BOOL)inFolder {
    [self beginOpenURLs:@[url] appending:NO expandsFile:inFolder grantedFolder:nil];
}

- (void)openSheetURL:(NSURL *)sheetURL inGrantedFolder:(NSURL *)folderURL appending:(BOOL)appending {
    [self beginOpenURLs:@[sheetURL] appending:appending expandsFile:!appending grantedFolder:folderURL];
}

- (void)clearSession {
    // FIRST: an open in flight is superseded and releases its own scopes on
    // its own path. No successor set, so acquire-before-release does not apply.
    [self beginOpenIntent];
    for (NSURL *url in _scopedURLs) {
        [url stopAccessingSecurityScopedResource];
    }
    _scopedURLs = [NSMutableArray array];
    _searchGrants = [NSMutableArray array];
    _folderURL = nil;
    _addedFolderURLs = [NSMutableArray array];
    _hasAdditions = NO;
    _additionsPersisted = NO;
    _landedOpenIntentGeneration = 0;
    _promotedOpenInFlight = NO;
    _promotedOpenIntentGeneration = 0;
    _addWaiters = nil;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kAdditionBookmarksKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastTrackPathKey];
}

- (void)cancelOpen {
    uint64_t openIntentGeneration = [self beginOpenIntent];
    // An empty open's settle, as finishOpenIntent: makes it: without the carry,
    // every later Add is captured at a generation nothing landed.
    _landedOpenIntentGeneration = VibeFolderSessionCarriedOpenIntentGeneration(
            _landedOpenIntentGeneration, openIntentGeneration);
    [self releaseAddWaitersAfterSettle];
}

@end
