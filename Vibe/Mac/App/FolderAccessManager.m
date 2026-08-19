//
//  FolderAccessManager.m
//  Vibe
//

#import "FolderAccessManagerInternal.h"
#import "FolderAccessManager+GrantPanel.h"
#import "FolderAccessRules.h"
#import "VibeStrings.h"

#import <AppKit/AppKit.h>

#import <pwd.h>

NSNotificationName const FolderAccessManagerDidChangeNotification = @"FolderAccessManagerDidChangeNotification";

static NSString *const kGrantedFoldersDefaultsKey = @"VibeGrantedFolders";
static NSString *const kEntryPathKey = @"path";
static NSString *const kEntryBookmarkKey = @"bookmark";
// Runtime-only: the resolved URL whose security scope is currently started.
// Stripped before the entry is persisted.
static NSString *const kEntryAccessedURLKey = @"accessedURL";
// Runtime-only: a live Powerbox/open/drop grant in this process.
static NSString *const kEntryPowerboxActiveKey = @"powerboxActive";

// The ceiling on every wait for a restored grant, shared by the launch drain
// and the per-open waiters, so the two cannot drift apart.
static const NSTimeInterval kRestoreDeadline = 2.0;
const NSInteger VibeFolderAccessRestoreConcurrencyLimit = 4;

@interface VibeRestorationWaiter : NSObject
@property (copy) NSArray<NSURL *> *urls;
@property (copy) dispatch_block_t completion;
@end

@implementation VibeRestorationWaiter
@end

// TRAP: promotion cancels and re-enqueues a queued operation, but cancellation
// can race its start. The claim keeps the two lanes from resolving it twice.
@interface FolderAccessRestoration : NSObject
// Exact row identity. The immutable snapshot below is the background input;
// this object is only compared by pointer on main.
@property (strong) NSMutableDictionary *liveEntry;
@property (copy) NSDictionary *stored;
@property (strong) NSOperation *operation;
@property (copy) dispatch_block_t work;
@property BOOL eligible;
@property BOOL prioritized;
- (BOOL)claim;
@end

@implementation FolderAccessRestoration {
    BOOL _claimed;
}

- (BOOL)claim {
    @synchronized (self) {
        if (_claimed) {
            return NO;
        }
        _claimed = YES;
        return YES;
    }
}

@end

@interface VibeGrantedFolder ()
- (instancetype)initWithPath:(NSString *)path state:(VibeGrantedFolderState)state;
@end

@implementation VibeGrantedFolder

- (instancetype)initWithPath:(NSString *)path state:(VibeGrantedFolderState)state {
    self = [super init];
    if (self) {
        _path = [path copy];
        _state = state;
    }
    return self;
}

@end

@interface FolderAccessManager ()
// Paths whose scope is live in this process. Stored rows remain separately
// visible while their bookmark is unresolved or failed.
@property (atomic, copy) NSArray<NSString *> *activePathSnapshot;
@end

@implementation FolderAccessManager {
    // Mutated on the main thread only; background work operates on snapshots
    // and merges back on main.
    NSMutableArray<NSMutableDictionary *> *_entries;
    NSMutableArray<VibeRestorationWaiter *> *_restorationWaiters;
    NSOperationQueue *_restorationQueue;
    NSOperationQueue *_urgentRestorationQueue;
    NSMutableArray<FolderAccessRestoration *> *_pendingRestorations;
    // Until the launch restore runs, no stored bookmark has been tried, so a
    // row that is neither live nor resolving is pending rather than failed.
    BOOL _restoreStarted;
    BOOL _changeNotificationPending;
}

+ (instancetype)sharedInstance {
    static FolderAccessManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[FolderAccessManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [NSMutableArray array];
        _restorationWaiters = [NSMutableArray array];
        _restorationQueue = [NSOperationQueue new];
        _restorationQueue.name = @"com.commonwealthrecordings.Vibe.folder-access-restore";
        _restorationQueue.qualityOfService = NSQualityOfServiceUtility;
        // Leave one slot for a grant an open is actively waiting on.
        _restorationQueue.maxConcurrentOperationCount = VibeFolderAccessRestoreConcurrencyLimit - 1;
        _urgentRestorationQueue = [NSOperationQueue new];
        _urgentRestorationQueue.name = @"com.commonwealthrecordings.Vibe.folder-access-restore.open";
        _urgentRestorationQueue.qualityOfService = NSQualityOfServiceUserInitiated;
        _urgentRestorationQueue.maxConcurrentOperationCount = 1;
        _pendingRestorations = [NSMutableArray array];
        NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:kGrantedFoldersDefaultsKey];
        for (NSDictionary *entry in stored) {
            NSString *path = entry[kEntryPathKey];
            NSData *bookmark = entry[kEntryBookmarkKey];
            if ([path isKindOfClass:NSString.class] && [bookmark isKindOfClass:NSData.class]) {
                [_entries addObject:[@{kEntryPathKey: path, kEntryBookmarkKey: bookmark} mutableCopy]];
            }
        }
        _activePathSnapshot = @[];
    }
    return self;
}

// The two ways macOS spells one directory: /tmp, /var and /etc are symlinks
// into /private, and every real path also exists under the data volume's
// firmlink. A grant and a track can arrive spelled either way, so both sides of
// the coverage test go through this. Deliberately string work alone —
// stringByStandardizingPath and its kin touch the file system to decide, and
// this runs on directories the app may have no business touching yet.
static NSString *VibeAliasFreePath(NSString *path) {
    static NSString *const kDataVolumePrefix = @"/System/Volumes/Data/";
    // /private itself is real; only these firmlink roots are aliases. Hoisted:
    // this runs once per granted path per coverage test.
    static NSArray<NSString *> *privateRoots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        privateRoots = @[@"/private/tmp", @"/private/var", @"/private/etc"];
    });
    if ([path hasPrefix:kDataVolumePrefix]) {
        path = [path substringFromIndex:kDataVolumePrefix.length - 1];
    }
    for (NSString *privateRoot in privateRoots) {
        if ([path isEqualToString:privateRoot] ||
                [path hasPrefix:[privateRoot stringByAppendingString:@"/"]]) {
            path = [path substringFromIndex:@"/private".length];
            break;
        }
    }
    return path;
}

static BOOL VibeURLIsCoveredByPath(NSURL *url, NSString *grantedPath) {
    NSString *path = VibeAliasFreePath(url.URLByStandardizingPath.path);
    return VibeUncanonicalPathIsUnderFolder(path,
                                            VibeAliasFreePath(grantedPath));
}

- (BOOL)canReadInsideDirectory:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    return [self.class readablePath:path isCoveredByAnyOf:self.activePathSnapshot ?: @[]];
}

- (NSArray<VibeGrantedFolder *> *)grantedFolders {
    NSMutableArray<VibeGrantedFolder *> *folders = [NSMutableArray arrayWithCapacity:_entries.count];
    for (NSDictionary *entry in _entries) {
        [folders addObject:[[VibeGrantedFolder alloc] initWithPath:entry[kEntryPathKey]
                                                             state:[self stateForEntry:entry]]];
    }
    return folders;
}

// Restoration is the only thing that settles a stored bookmark, so an entry it
// finished with and left inactive is one that failed. Deliberately costs no
// I/O: the pane must be able to say a folder is gone without stat-ing a path
// whose mount may be unreachable, on the main thread, per row.
- (VibeGrantedFolderState)stateForEntry:(NSDictionary *)entry {
    if (entry[kEntryAccessedURLKey] || [entry[kEntryPowerboxActiveKey] boolValue]) {
        return VibeGrantedFolderStateActive;
    }
    if (!_restoreStarted || [self hasEligibleRestorationForEntry:entry]) {
        return VibeGrantedFolderStateRestoring;
    }
    return VibeGrantedFolderStateUnavailable;
}

- (BOOL)hasEligibleRestorationForEntry:(NSDictionary *)entry {
    for (FolderAccessRestoration *restoration in _pendingRestorations) {
        if (restoration.eligible && restoration.liveEntry == entry) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Restore

- (void)restoreGrantedAccessWithCompletion:(void (^)(void))completion {
    NSArray<NSMutableDictionary *> *liveEntries = [_entries copy];
    _restoreStarted = YES;
    if (liveEntries.count == 0) {
        if (completion) {
            completion();
        }
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    for (NSMutableDictionary *liveEntry in liveEntries) {
        NSDictionary *stored = @{kEntryPathKey: liveEntry[kEntryPathKey],
                                 kEntryBookmarkKey: liveEntry[kEntryBookmarkKey]};
        dispatch_group_enter(group);
        FolderAccessRestoration *restoration = [FolderAccessRestoration new];
        restoration.liveEntry = liveEntry;
        restoration.stored = stored;
        restoration.eligible = YES;
        __weak FolderAccessRestoration *weakRestoration = restoration;
        restoration.work = ^{
            NSDictionary *restored = [self resolveStoredEntry:stored];
            dispatch_async(dispatch_get_main_queue(), ^{
                FolderAccessRestoration *finished = weakRestoration;
                if (restored && finished) {
                    [self mergeRestoredURL:restored[kEntryAccessedURLKey]
                                  bookmark:restored[kEntryBookmarkKey]
                            forRestoration:finished];
                }
                if (finished) {
                    finished.eligible = NO;
                    [self->_pendingRestorations removeObjectIdenticalTo:finished];
                    finished.operation = nil;
                    finished.work = nil;
                    finished.liveEntry = nil;
                }
                [self postCoalescedChangeNotification];
                [self drainRestorationWaiters];
                dispatch_group_leave(group);
            });
        };
        restoration.operation = [self operationForRestoration:restoration];
        [_pendingRestorations addObject:restoration];
        [_restorationQueue addOperation:restoration.operation];
    }
    if (!completion) {
        return;
    }
    // Fire when every scope has started, or at the deadline — a caller gated
    // on a dead mount's grant gains nothing by waiting, since a walk under
    // that mount would block the same way. done is main-thread state.
    __block BOOL done = NO;
    dispatch_block_t finish = ^{
        if (!done) {
            done = YES;
            completion();
        }
    };
    dispatch_group_notify(group, dispatch_get_main_queue(), finish);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRestoreDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), finish);
}

- (NSBlockOperation *)operationForRestoration:(FolderAccessRestoration *)restoration {
    __weak FolderAccessRestoration *weakRestoration = restoration;
    return [NSBlockOperation blockOperationWithBlock:^{
        FolderAccessRestoration *strongRestoration = weakRestoration;
        if ([strongRestoration claim]) {
            strongRestoration.work();
        }
    }];
}

// A removed or reactivated row no longer competes for an open's reserved lane.
// Its resolution still has to run once: that is what balances the launch group,
// and a resolution already in flight may have started a scope that merge must
// release. A pending urgent admission is therefore moved back to utility work;
// the restoration's claim arbitrates the cancel/start race between operations.
- (void)invalidateRestorationsForEntry:(NSMutableDictionary *)entry {
    for (FolderAccessRestoration *restoration in [_pendingRestorations copy]) {
        if (!restoration.eligible || restoration.liveEntry != entry) {
            continue;
        }
        restoration.eligible = NO;
        if (!restoration.prioritized) {
            continue;
        }
        NSOperation *urgentOperation = restoration.operation;
        if (!urgentOperation || urgentOperation.executing || urgentOperation.finished) {
            continue;
        }
        [urgentOperation cancel];
        restoration.prioritized = NO;
        restoration.operation = [self operationForRestoration:restoration];
        [_restorationQueue addOperation:restoration.operation];
    }
}

// Background thread. Resolves and starts the scope; the main-thread caller
// merges the result and only then marks this remembered path settled.
- (NSDictionary *)resolveStoredEntry:(NSDictionary *)stored {
    NSData *bookmark = stored[kEntryBookmarkKey];
    BOOL stale = NO;
    NSError *error;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                           options:NSURLBookmarkResolutionWithSecurityScope
                                     relativeToURL:nil
                               bookmarkDataIsStale:&stale
                                             error:&error];
    if (!url) {
        // The folder may be gone or its volume unmounted. Keep the entry: it
        // stays in the pane as VibeGrantedFolderStateUnavailable, where it can
        // be removed, and resolves again by itself if the volume comes back.
        LogWarn(@"Granted folder failed to resolve (%@): %@", stored[kEntryPathKey], error);
        return nil;
    }
    if (![url startAccessingSecurityScopedResource]) {
        LogWarn(@"Granted folder refused security scope: %@", url.path);
        return nil;
    }
    // A stale bookmark still resolves; refresh it so the next launch
    // doesn't pay the staleness again. Creation needs the scope the
    // line above just started.
    NSData *freshBookmark = bookmark;
    if (stale) {
        NSData *recreated = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                          includingResourceValuesForKeys:nil
                                           relativeToURL:nil
                                                   error:&error];
        if (recreated) {
            freshBookmark = recreated;
        }
        else {
            LogWarn(@"Stale bookmark for %@ could not be refreshed: %@", url.path, error);
        }
    }
    return @{kEntryAccessedURLKey: url, kEntryBookmarkKey: freshBookmark};
}

- (void)awaitRestoredAccessForURLs:(NSArray<NSURL *> *)urls
                        completion:(dispatch_block_t)completion {
    if (![self shouldWaitForRestorationOfURLs:urls]) {
        completion();
        return;
    }
    [self prioritizeRestorationsForURLs:urls];
    VibeRestorationWaiter *waiter = [VibeRestorationWaiter new];
    waiter.urls = urls;
    waiter.completion = completion;
    [_restorationWaiters addObject:waiter];
    // The deadline the header promises. Same value as the restore's own, and
    // for the same reason: a caller gated on a dead mount's grant gains
    // nothing by waiting, since a walk under that mount blocks the same way.
    __weak FolderAccessManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRestoreDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf releaseWaiter:waiter];
    });
}

- (void)prioritizeRestorationsForURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray<FolderAccessRestoration *> *selected = [NSMutableArray array];
    for (NSURL *url in urls) {
        if ([self hasActiveAccessForURL:url]) {
            continue;
        }
        FolderAccessRestoration *mostSpecific = nil;
        NSUInteger mostSpecificDepth = 0;
        for (FolderAccessRestoration *restoration in _pendingRestorations) {
            NSString *path = restoration.stored[kEntryPathKey];
            if (!restoration.eligible || !VibeURLIsCoveredByPath(url, path)) {
                continue;
            }
            NSUInteger depth = VibeAliasFreePath(path).pathComponents.count;
            if (!mostSpecific || depth > mostSpecificDepth) {
                mostSpecific = restoration;
                mostSpecificDepth = depth;
            }
        }
        if (mostSpecific && ![selected containsObject:mostSpecific]) {
            [selected addObject:mostSpecific];
        }
    }

    for (FolderAccessRestoration *restoration in selected) {
        NSOperation *operation = restoration.operation;
        if (!operation || restoration.prioritized || operation.executing || operation.finished) {
            continue;
        }
        restoration.prioritized = YES;
        [operation cancel];
        restoration.operation = [self operationForRestoration:restoration];
        [_urgentRestorationQueue addOperation:restoration.operation];
    }
}

- (void)drainRestorationWaiters {
    for (VibeRestorationWaiter *waiter in [_restorationWaiters copy]) {
        if (![self shouldWaitForRestorationOfURLs:waiter.urls]) {
            [self releaseWaiter:waiter];
        }
        else {
            // If the most-specific candidate failed, promote the next covering
            // grant instead of leaving it behind unrelated launch restores.
            [self prioritizeRestorationsForURLs:waiter.urls];
        }
    }
}

- (BOOL)shouldWaitForRestorationOfURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        if (![self hasActiveAccessForURL:url]
                && [self hasEligibleRestorationCoveringURL:url]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasEligibleRestorationCoveringURL:(NSURL *)url {
    for (FolderAccessRestoration *restoration in _pendingRestorations) {
        if (restoration.eligible
                && VibeURLIsCoveredByPath(url, restoration.stored[kEntryPathKey])) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasActiveAccessForURL:(NSURL *)url {
    return [self.class readablePath:url.URLByStandardizingPath.path
                   isCoveredByAnyOf:self.activePathSnapshot ?: @[]];
}

// One shot, whichever fires first — the grant settling or its deadline.
- (void)releaseWaiter:(VibeRestorationWaiter *)waiter {
    if (![_restorationWaiters containsObject:waiter]) {
        return;
    }
    [_restorationWaiters removeObject:waiter];
    dispatch_block_t completion = waiter.completion;
    waiter.completion = nil;
    completion();
}

// Matches a background resolution back onto the live entry, which may have
// been removed while the resolve ran — then the scope is released untracked.
- (void)mergeRestoredURL:(NSURL *)url
                bookmark:(NSData *)bookmark
          forRestoration:(FolderAccessRestoration *)restoration {
    NSMutableDictionary *entry = restoration.liveEntry;
    NSDictionary *stored = restoration.stored;
    if (restoration.eligible
            && [_entries indexOfObjectIdenticalTo:entry] != NSNotFound
            && [entry[kEntryBookmarkKey] isEqual:stored[kEntryBookmarkKey]]) {
        BOOL pathChanged = ![entry[kEntryPathKey] isEqualToString:url.path];
        entry[kEntryAccessedURLKey] = url;
        [entry removeObjectForKey:kEntryPowerboxActiveKey];
        entry[kEntryBookmarkKey] = bookmark;
        entry[kEntryPathKey] = url.path;
        LogInfo(@"Restored access to granted folder: %@", url.path);
        if (pathChanged || ![bookmark isEqual:stored[kEntryBookmarkKey]]) {
            [self persist];
        }
        [self publishActivePaths];
        // The caller posts for every settled entry, failures included, so
        // this path does not post its own.
        return;
    }
    // The row was removed or explicitly reopened while resolution was in
    // flight, so this scope has no owner.
    [url stopAccessingSecurityScopedResource];
}

#pragma mark - Adding

- (void)noteOpenedURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }
    // Only a live grant covers this open. A failed stored parent must not make
    // us skip a newly granted child, and an explicitly reopened exact folder
    // must be allowed to reactivate its stored row.
    NSArray<NSString *> *existing = self.activePathSnapshot ?: @[];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSDictionary *> *additions = [NSMutableArray array];
        NSMutableArray<NSString *> *covered = [existing mutableCopy];
        for (NSURL *url in urls) {
            NSString *path = url.URLByStandardizingPath.path;
            BOOL isDirectory = NO;
            if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
                continue;
            }
            // Standardizing keeps whatever case the caller spelled, and the
            // volume is typically case-insensitive — left as-is, a
            // differently-cased spelling of a granted folder (or of ~/Music)
            // dodges the case-sensitive coverage check below and mints a
            // duplicate bookmark.
            id canonical = nil;
            [[NSURL fileURLWithPath:path] getResourceValue:&canonical forKey:NSURLCanonicalPathKey error:nil];
            if ([canonical isKindOfClass:NSString.class]) {
                path = canonical;
            }
            if ([self.class path:path isCoveredByAnyOf:covered]) {
                continue;
            }
            NSError *error;
            NSData *bookmark = [[NSURL fileURLWithPath:path]
                    bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
             includingResourceValuesForKeys:nil
                              relativeToURL:nil
                                      error:&error];
            if (!bookmark) {
                // Expected for a path the sandbox never granted, such as argv.
                LogInfo(@"No bookmark for %@: %@", path, error.localizedDescription);
                continue;
            }
            [additions addObject:@{kEntryPathKey: path, kEntryBookmarkKey: bookmark}];
            [covered addObject:path];
        }
        if (additions.count == 0) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self mergeAdditions:additions];
        });
    });
}

- (void)mergeAdditions:(NSArray<NSDictionary *> *)additions {
    BOOL changed = NO;
    for (NSDictionary *addition in additions) {
        NSString *path = addition[kEntryPathKey];
        // Re-check live ACTIVE coverage: another batch may have landed while
        // this one's bookmarks were being created.
        if ([self.class path:path isCoveredByAnyOf:self.activePathSnapshot ?: @[]]) {
            continue;
        }
        NSMutableDictionary *reusable = [self inactiveEntryForDirectory:path];
        if (reusable) {
            [self invalidateRestorationsForEntry:reusable];
            reusable[kEntryPathKey] = path;
            reusable[kEntryBookmarkKey] = addition[kEntryBookmarkKey];
            reusable[kEntryPowerboxActiveKey] = @YES;
            LogInfo(@"Granted folder reactivated: %@", path);
        }
        else {
            NSMutableDictionary *entry = [addition mutableCopy];
            entry[kEntryPowerboxActiveKey] = @YES;
            [_entries addObject:entry];
            LogInfo(@"Granted folder added: %@", path);
        }
        changed = YES;
    }
    if (changed) {
        [self persist];
        [self publishActivePaths];
        [self drainRestorationWaiters];
        [NSNotificationCenter.defaultCenter postNotificationName:FolderAccessManagerDidChangeNotification
                                                          object:self];
    }
}

// The stored row this newly granted directory should reactivate rather than
// duplicate: same directory, no live scope of its own.
//
// The inactive half of that test is load-bearing, not a restatement of the
// caller's active-coverage check: that check compares canonical spellings, and a
// restored row's path is whatever its bookmark resolved to, so a divergent
// spelling slips past it and lands here. Overwriting an entry that still holds a
// started scope strands it — nothing else remembers the URL to stop accessing,
// and the sandbox extension leaks for the process's life.
- (NSMutableDictionary *)inactiveEntryForDirectory:(NSString *)path {
    NSString *wanted = VibeAliasFreePath(path);
    for (NSMutableDictionary *entry in _entries) {
        if (entry[kEntryAccessedURLKey] || [entry[kEntryPowerboxActiveKey] boolValue]) {
            continue;
        }
        if ([wanted isEqualToString:VibeAliasFreePath(entry[kEntryPathKey])]) {
            return entry;
        }
    }
    return nil;
}

// TRAP: inside the sandbox both NSHomeDirectory and NSHomeDirectoryForUser
// answer with the container, which silently turns the ~/Music rule below into a
// test against a path no music sits under. getpwuid is the documented way to
// the on-disk home.
+ (NSString *)realHomeDirectory {
    static NSString *home;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct passwd *entry = getpwuid(getuid());
        home = (entry && entry->pw_dir)
                ? [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->pw_dir
                                                                            length:strlen(entry->pw_dir)]
                : NSHomeDirectory();
    });
    return home;
}

// A folder inside an already-granted folder, or under ~/Music (the standing
// entitlement grant), needs no bookmark of its own.
+ (BOOL)path:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths {
    return [self path:path isCoveredByAnyOf:grantedPaths caseInsensitive:NO];
}

+ (BOOL)readablePath:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths {
    return [self path:path isCoveredByAnyOf:grantedPaths caseInsensitive:YES];
}

// Case sensitivity splits the two callers. The auto-add's duplicate check
// compares canonical spellings and must stay exact, or a case-SENSITIVE volume
// loses a bookmark it needs. A read test gets whatever spelling the track URL
// carried — Launch Services, argv, a pasteboard, a playlist file's entries — so
// folding case is the safe direction: under-matching withholds a folder the app
// may legitimately read, while the only over-match is a case-variant path on a
// case-sensitive volume whose grant the user gave for a sibling spelling.
+ (BOOL)path:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths
        caseInsensitive:(BOOL)caseInsensitive {
    NSString *candidate = VibeAliasFreePath(path);
    for (NSString *granted in grantedPaths) {
        NSString *root = VibeAliasFreePath(granted);
        if (caseInsensitive ? VibeUncanonicalPathIsUnderFolder(candidate, root)
                            : VibePathIsUnderFolder(candidate, root)) {
            return YES;
        }
    }
    // The standing entitlement grant, tested last rather than appended to the
    // caller's array: this runs per folder the artwork resolver considers, and
    // arrayByAddingObject: allocates an array every time to add one constant.
    return caseInsensitive ? VibeUncanonicalPathIsUnderFolder(candidate, self.musicRoot)
                           : VibePathIsUnderFolder(candidate, self.musicRoot);
}

// ~/Music, alias-free and computed once.
+ (NSString *)musicRoot {
    static NSString *musicRoot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        musicRoot = VibeAliasFreePath([self.realHomeDirectory stringByAppendingPathComponent:@"Music"]);
    });
    return musicRoot;
}

#pragma mark - Removing

- (void)removeFoldersAtIndexes:(NSIndexSet *)indexes {
    NSIndexSet *valid = [indexes indexesInRange:NSMakeRange(0, _entries.count)
                                        options:0
                                    passingTest:^BOOL(NSUInteger index, BOOL *stop) { return YES; }];
    if (valid.count == 0) {
        return;
    }
    [_entries enumerateObjectsAtIndexes:valid options:0 usingBlock:^(NSMutableDictionary *entry, NSUInteger index, BOOL *stop) {
        [self invalidateRestorationsForEntry:entry];
        NSURL *accessed = entry[kEntryAccessedURLKey];
        [accessed stopAccessingSecurityScopedResource];
        LogInfo(@"Granted folder removed: %@", entry[kEntryPathKey]);
    }];
    [_entries removeObjectsAtIndexes:valid];
    [self persist];
    [self publishActivePaths];
    [self drainRestorationWaiters];
    [NSNotificationCenter.defaultCenter postNotificationName:FolderAccessManagerDidChangeNotification
                                                      object:self];
}

#pragma mark - Persistence

- (void)persist {
    NSMutableArray<NSDictionary *> *stored = [NSMutableArray arrayWithCapacity:_entries.count];
    for (NSDictionary *entry in _entries) {
        [stored addObject:@{kEntryPathKey: entry[kEntryPathKey], kEntryBookmarkKey: entry[kEntryBookmarkKey]}];
    }
    [NSUserDefaults.standardUserDefaults setObject:stored forKey:kGrantedFoldersDefaultsKey];
}

// Restoration settles one bookmark at a time, each on its own block, and every
// one changes what the Files pane shows — including the failures, which merge
// nothing. Coalesced to one post per turn of the run loop because observers do
// real work with it: the player invalidates folder art, and a dozen
// remembered folders should not make it do that a dozen times at launch. The
// user-driven add and remove post directly, so the pane redraws in the same
// turn as the click.
- (void)postCoalescedChangeNotification {
    if (_changeNotificationPending) {
        return;
    }
    _changeNotificationPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_changeNotificationPending = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:FolderAccessManagerDidChangeNotification
                                                          object:self];
    });
}

- (void)publishActivePaths {
    NSMutableArray<NSString *> *active = [NSMutableArray array];
    for (NSDictionary *entry in _entries) {
        if (entry[kEntryAccessedURLKey] || [entry[kEntryPowerboxActiveKey] boolValue]) {
            [active addObject:entry[kEntryPathKey]];
        }
    }
    self.activePathSnapshot = active;
}

@end
