//
//  FolderAccessManager.m
//  Vibe
//

#import "FolderAccessManager.h"
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

@interface VibeRestorationWaiter : NSObject
@property (copy) NSArray<NSURL *> *urls;
@property (copy) dispatch_block_t completion;
@end

@implementation VibeRestorationWaiter
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
    NSMutableSet<NSString *> *_restoringPaths;
    NSMutableArray<VibeRestorationWaiter *> *_restorationWaiters;
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
        _restoringPaths = [NSMutableSet set];
        _restorationWaiters = [NSMutableArray array];
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
    if (!_restoreStarted || [_restoringPaths containsObject:entry[kEntryPathKey]]) {
        return VibeGrantedFolderStateRestoring;
    }
    return VibeGrantedFolderStateUnavailable;
}

#pragma mark - Restore

- (void)restoreGrantedAccessWithCompletion:(void (^)(void))completion {
    NSArray<NSDictionary *> *snapshot = [[NSArray alloc] initWithArray:_entries copyItems:YES];
    _restoreStarted = YES;
    if (snapshot.count == 0) {
        if (completion) {
            completion();
        }
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary *stored in snapshot) {
        [_restoringPaths addObject:stored[kEntryPathKey]];
    }
    for (NSDictionary *stored in snapshot) {
        // One block per bookmark: a resolve can block for an automounter
        // timeout on an unreachable mount, and serialized behind it every
        // later folder's grant would wait too.
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSDictionary *restored = [self resolveStoredEntry:stored];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (restored) {
                    [self mergeRestoredURL:restored[kEntryAccessedURLKey]
                                  bookmark:restored[kEntryBookmarkKey]
                               forOriginal:stored];
                }
                [self->_restoringPaths removeObject:stored[kEntryPathKey]];
                [self postCoalescedChangeNotification];
                [self drainRestorationWaiters];
                dispatch_group_leave(group);
            });
        });
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
    if (![self anyURL:urls coveredByPaths:_restoringPaths]) {
        completion();
        return;
    }
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

- (void)drainRestorationWaiters {
    for (VibeRestorationWaiter *waiter in [_restorationWaiters copy]) {
        if (![self anyURL:waiter.urls coveredByPaths:_restoringPaths]) {
            [self releaseWaiter:waiter];
        }
    }
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

- (BOOL)anyURL:(NSArray<NSURL *> *)urls coveredByPaths:(NSSet<NSString *> *)paths {
    for (NSURL *url in urls) {
        // Alias-free on both sides, like every other coverage test here, or a
        // grant remembered as /private/tmp/set fails to cover an open spelled
        // /tmp/set, which then runs before the scope has started.
        NSString *path = VibeAliasFreePath(url.URLByStandardizingPath.path);
        for (NSString *granted in paths) {
            // The uncanonical form: these URLs come straight off Launch
            // Services, argv or a pasteboard, unlike noteOpenedURLs:'s.
            if (VibeUncanonicalPathIsUnderFolder(path, VibeAliasFreePath(granted))) {
                return YES;
            }
        }
    }
    return NO;
}

// Matches a background resolution back onto the live entry, which may have
// been removed while the resolve ran — then the scope is released untracked.
- (void)mergeRestoredURL:(NSURL *)url bookmark:(NSData *)bookmark forOriginal:(NSDictionary *)original {
    for (NSMutableDictionary *entry in _entries) {
        if ([entry[kEntryBookmarkKey] isEqual:original[kEntryBookmarkKey]]) {
            BOOL pathChanged = ![entry[kEntryPathKey] isEqualToString:url.path];
            entry[kEntryAccessedURLKey] = url;
            [entry removeObjectForKey:kEntryPowerboxActiveKey];
            entry[kEntryBookmarkKey] = bookmark;
            entry[kEntryPathKey] = url.path;
            LogInfo(@"Restored access to granted folder: %@", url.path);
            if (pathChanged || ![bookmark isEqual:original[kEntryBookmarkKey]]) {
                [self persist];
            }
            [self publishActivePaths];
            // The caller posts for every settled entry, failures included, so
            // this path does not post its own.
            return;
        }
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
        NSURL *accessed = entry[kEntryAccessedURLKey];
        [accessed stopAccessingSecurityScopedResource];
        // A row removed while its bookmark is still resolving must stop holding
        // opens: left in _restoringPaths, every later open under it waits out
        // the full deadline for a grant that no longer exists.
        [_restoringPaths removeObject:entry[kEntryPathKey]];
        LogInfo(@"Granted folder removed: %@", entry[kEntryPathKey]);
    }];
    [_entries removeObjectsAtIndexes:valid];
    [self persist];
    [self publishActivePaths];
    [self drainRestorationWaiters];
    [NSNotificationCenter.defaultCenter postNotificationName:FolderAccessManagerDidChangeNotification
                                                      object:self];
}

#pragma mark - The playlist-file grant

// Runs the folder picker on the main thread and blocks the calling expansion
// worker until it closes. Safe to block on main from there: every caller
// enters the expansion queue with an async submission, never the reverse.
//
// Folder walks are concurrent, but powerbox prompts must not stack inside one
// another's modal loops, so this uncommon path serializes on a private gate.
// Private deliberately: holding a lock across a modal run loop is a long hold,
// and a monitor on the manager would be reachable — and so deadlockable —
// from anywhere.
- (BOOL)requestAccessForPlaylistFolder:(NSURL *)playlistURL {
    NSAssert(!NSThread.isMainThread, @"the playlist grant blocks on the main thread");
    static dispatch_semaphore_t grantGate;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        grantGate = dispatch_semaphore_create(1);
    });
    __block BOOL granted = NO;
    dispatch_semaphore_wait(grantGate, DISPATCH_TIME_FOREVER);
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        panel.directoryURL = playlistURL.URLByDeletingLastPathComponent;
        panel.message = [NSString stringWithFormat:STR_PLAYLIST_GRANT_MESSAGE, playlistURL.lastPathComponent];
        panel.prompt = STR_PLAYLIST_GRANT_BUTTON;
        // Reading panel.URL is what attaches the powerbox's sandbox extension
        // to the process, not just running the panel.
        granted = [panel runModal] == NSModalResponseOK && panel.URL != nil;
        if (granted) {
            LogInfo(@"Playlist folder access granted: %@", panel.URL.path);
            // The powerbox extension lasts only this process. Bookmark the
            // folder like the open and drop funnels do, or every relaunch
            // re-prompts for it — the auto-add funnel never sees it, since
            // openURLs: gets the playlist file, not the granted directory.
            [self noteOpenedURLs:@[panel.URL]];
        }
        else {
            LogInfo(@"Playlist folder access declined for %@", playlistURL.lastPathComponent);
        }
    });
    dispatch_semaphore_signal(grantGate);
    return granted;
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
// real work with it: the player invalidates folder artwork, and a dozen
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
