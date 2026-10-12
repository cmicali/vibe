//
//  FolderSession+Persistence.m
//  Vibe (iOS)
//
//  The launch restore, the remembered track, and the bookmarks: minting,
//  resolving and the persisted addition list.
//

#import "FolderSessionInternal.h"
#import "AppSettings.h"
#import "FilePaths.h"

// LocationStore's bound, for its reason: one stalled provider must not
// head-of-line every other bookmark.
static const NSInteger kMaximumConcurrentBookmarkRestorations = 3;

@implementation FolderSession (Persistence)

- (BOOL)restorePersistedFolder {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
    if (!bookmark) {
        return NO;
    }
    NSArray *additions =
            [NSUserDefaults.standardUserDefaults arrayForKey:kAdditionBookmarksKey] ?: @[];
    // Base first, then additions, in persisted order: the dedupe and the
    // first-contributor base rule rest on it.
    NSMutableArray<NSData *> *bookmarks = [NSMutableArray arrayWithObject:bookmark];
    for (id data in additions) {
        if ([data isKindOfClass:NSData.class]) {
            [bookmarks addObject:data];
        }
        else {
            LogWarn(@"FolderSession: an addition bookmark is not data");
        }
    }
    uint64_t openIntentGeneration = [self beginOpenIntent];
    VibeFolderOpenSort sort = AppSettings.sharedInstance.folderOpenSort;
    dispatch_async(_workQueue, ^{
        if (![self isCurrentOpenIntent:openIntentGeneration]) {
            return;
        }
        // No refresh of a stale bookmark here: minting needs the scope OPEN,
        // and the landing re-persists anyway.
        NSArray<NSURL *> *urls = [self resolveBookmarksConcurrently:bookmarks
                                              openIntentGeneration:openIntentGeneration];
        // Only a restore where NOTHING resolved fails. A dead base's
        // surviving additions restore, the first becoming the base.
        if (urls.count == 0 || ![self isCurrentOpenIntent:openIntentGeneration]) {
            if (urls.count == 0) {
                LogWarn(@"FolderSession: no persisted bookmark resolves");
            }
            run_on_main_thread({
                if ([self isCurrentOpenIntent:openIntentGeneration]) {
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFolderBookmarkKey];
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:kAdditionBookmarksKey];
                    [self.delegate folderSessionRestoreDidFail:self];
                }
            });
            return;
        }
        [self openURLsOnWorkQueue:urls appending:NO restored:YES keepsSessionBookmark:NO expandsFile:YES
                         sortedBy:sort coveringRootPaths:@[] holds:@[] grants:@[]
             openIntentGeneration:openIntentGeneration];
    });
    return YES;
}

// Answers the URLs that resolved, IN THE ORDER PASSED; a failure, the base
// included, is simply missing, and the landing's rewrite of both keys is the
// pruning. Parallel because a concurrent queue does not parallelize inside
// one block, and resolving in a row cost the sum. It still waits for the
// slowest bookmark, since the walk needs the whole union. The listing and
// minting that follow stay serial on purpose: one order-dependent loop owns
// the dedupe, the base rule and each scope's start-stop pairing.
- (NSArray<NSURL *> *)resolveBookmarksConcurrently:(NSArray<NSData *> *)bookmarks
                              openIntentGeneration:(uint64_t)openIntentGeneration {
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:bookmarks.count];
    for (NSUInteger i = 0; i < bookmarks.count; i++) {
        [slots addObject:NSNull.null];
    }
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.name = @"FolderSession.restore";
    queue.qualityOfService = NSQualityOfServiceUserInitiated;
    queue.maxConcurrentOperationCount = kMaximumConcurrentBookmarkRestorations;
    [bookmarks enumerateObjectsUsingBlock:^(NSData *data, NSUInteger index, BOOL *stop) {
        [queue addOperationWithBlock:^{
            if (![self isCurrentOpenIntent:openIntentGeneration]) {
                return;
            }
            NSError *error = nil;
            NSURL *url = [self resolveBookmark:data error:&error];
            if (!url) {
                LogWarn(@"FolderSession: a bookmark no longer resolves (%@)", error);
                return;
            }
            // Its own slot: completion order must not become playlist order.
            @synchronized (slots) {
                slots[index] = url;
            }
        }];
    }];
    [queue waitUntilAllOperationsAreFinished];
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:slots.count];
    for (id slot in slots) {
        if (slot != NSNull.null) {
            [urls addObject:slot];
        }
    }
    return urls;
}

- (NSString *)persistedTrackKey {
    return [NSUserDefaults.standardUserDefaults stringForKey:kLastTrackPathKey];
}

- (void)setPersistedTrackKey:(NSString *)key {
    if (key) {
        [NSUserDefaults.standardUserDefaults setObject:key forKey:kLastTrackPathKey];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastTrackPathKey];
    }
}

- (NSURL *)resolveBookmark:(NSData *)bookmark error:(NSError **)error {
    BOOL stale = NO;
    return [NSURL URLByResolvingBookmarkData:bookmark
                                     options:0
                               relativeToURL:nil
                         bookmarkDataIsStale:&stale
                                       error:error];
}

- (NSData *)bookmarkForURL:(NSURL *)url {
    // iOS has no WithSecurityScope option: a default bookmark of a granted
    // URL carries the scope. Requires the scope open, which every caller holds.
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:0
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (!bookmark) {
        LogWarn(@"FolderSession: could not bookmark %@ (%@)", url, error);
    }
    return bookmark;
}

// Only this session's own base may be extended: after a search hit, an inbox
// copy or a one-file open over a folder bookmark, it is an earlier playlist's.
- (void)persistAdditionBookmarks:(NSArray<NSData *> *)additionBookmarks {
    if (additionBookmarks.count == 0) {
        return;
    }
    if (!_additionsPersisted) {
        LogInfo(@"FolderSession: addition is session-only — the persisted base is not this session's");
        return;
    }
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kAdditionBookmarksKey] ?: @[];
    [NSUserDefaults.standardUserDefaults setObject:[list arrayByAddingObjectsFromArray:additionBookmarks]
                                            forKey:kAdditionBookmarksKey];
}

// The hold makes this safe off main: a newer open landing releases the
// previous scopes, and a mint under a closed scope fails.
- (void)bookmarkOpenFolderWithCompletion:(void (^)(NSURL *folderURL,
                                                   NSData *bookmark))completion {
    NSURL *folderURL = _folderURL;
    if (!folderURL) {
        completion(nil, nil);
        return;
    }
    // The scoped list, not the search roots: see rootCoveringPath:in:.
    NSURL *scopedURL = [self rootCoveringPath:VibeComparablePath(folderURL.path)
                                           in:_scopedURLs];
    BOOL scopeHoldStarted = [scopedURL startAccessingSecurityScopedResource];
    dispatch_async(_workQueue, ^{
        NSData *bookmark = [self bookmarkForURL:folderURL];
        if (scopeHoldStarted) {
            [scopedURL stopAccessingSecurityScopedResource];
        }
        run_on_main_thread({
            completion(bookmark ? folderURL : nil, bookmark);
        });
    });
}

// The URL arrives with the browser's grant, so its scope is started directly.
- (void)bookmarkFolderURL:(NSURL *)folderURL
               completion:(void (^)(NSData *bookmark))completion {
    if (!folderURL) {
        completion(nil);
        return;
    }
    // NO is not failure: the app's own container is not security-scoped.
    BOOL scopeHoldStarted = [folderURL startAccessingSecurityScopedResource];
    dispatch_async(_workQueue, ^{
        NSData *bookmark = [self bookmarkForURL:folderURL];
        if (scopeHoldStarted) {
            [folderURL stopAccessingSecurityScopedResource];
        }
        run_on_main_thread({
            completion(bookmark);
        });
    });
}

@end
