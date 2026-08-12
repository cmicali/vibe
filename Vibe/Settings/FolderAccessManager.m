//
//  FolderAccessManager.m
//  Vibe
//

#import "FolderAccessManager.h"

NSNotificationName const FolderAccessManagerDidChangeNotification = @"FolderAccessManagerDidChangeNotification";

static NSString *const kGrantedFoldersDefaultsKey = @"VibeGrantedFolders";
static NSString *const kEntryPathKey = @"path";
static NSString *const kEntryBookmarkKey = @"bookmark";
// Runtime-only: the resolved URL whose security scope is currently started.
// Stripped before the entry is persisted.
static NSString *const kEntryAccessedURLKey = @"accessedURL";

@implementation FolderAccessManager {
    // Mutated on the main thread only; background work operates on snapshots
    // and merges back on main.
    NSMutableArray<NSMutableDictionary *> *_entries;
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
        NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:kGrantedFoldersDefaultsKey];
        for (NSDictionary *entry in stored) {
            NSString *path = entry[kEntryPathKey];
            NSData *bookmark = entry[kEntryBookmarkKey];
            if ([path isKindOfClass:NSString.class] && [bookmark isKindOfClass:NSData.class]) {
                [_entries addObject:[@{kEntryPathKey: path, kEntryBookmarkKey: bookmark} mutableCopy]];
            }
        }
    }
    return self;
}

- (NSArray<NSString *> *)grantedFolderPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:_entries.count];
    for (NSDictionary *entry in _entries) {
        [paths addObject:entry[kEntryPathKey]];
    }
    return paths;
}

#pragma mark - Restore

- (void)restoreGrantedAccess {
    NSArray<NSDictionary *> *snapshot = [[NSArray alloc] initWithArray:_entries copyItems:YES];
    if (snapshot.count == 0) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSDictionary *stored in snapshot) {
            NSData *bookmark = stored[kEntryBookmarkKey];
            BOOL stale = NO;
            NSError *error;
            NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                                   options:NSURLBookmarkResolutionWithSecurityScope
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&stale
                                                     error:&error];
            if (!url) {
                // The folder may be gone or its volume unmounted. Keep the
                // entry: it stays visible in the pane, where it can be removed.
                LogWarn(@"Granted folder failed to resolve (%@): %@", stored[kEntryPathKey], error);
                continue;
            }
            if (![url startAccessingSecurityScopedResource]) {
                LogWarn(@"Granted folder refused security scope: %@", url.path);
                continue;
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
            dispatch_async(dispatch_get_main_queue(), ^{
                [self mergeRestoredURL:url bookmark:freshBookmark forOriginal:stored];
            });
        }
    });
}

// Matches a background resolution back onto the live entry, which may have
// been removed while the resolve ran — then the scope is released untracked.
- (void)mergeRestoredURL:(NSURL *)url bookmark:(NSData *)bookmark forOriginal:(NSDictionary *)original {
    for (NSMutableDictionary *entry in _entries) {
        if ([entry[kEntryBookmarkKey] isEqual:original[kEntryBookmarkKey]]) {
            BOOL pathChanged = ![entry[kEntryPathKey] isEqualToString:url.path];
            entry[kEntryAccessedURLKey] = url;
            entry[kEntryBookmarkKey] = bookmark;
            entry[kEntryPathKey] = url.path;
            LogInfo(@"Restored access to granted folder: %@", url.path);
            if (pathChanged || bookmark != original[kEntryBookmarkKey]) {
                [self persist];
            }
            if (pathChanged) {
                [NSNotificationCenter.defaultCenter postNotificationName:FolderAccessManagerDidChangeNotification
                                                                  object:self];
            }
            return;
        }
    }
    [url stopAccessingSecurityScopedResource];
}

#pragma mark - Adding

- (void)noteOpenedURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }
    NSArray<NSString *> *existing = self.grantedFolderPaths;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray<NSDictionary *> *additions = [NSMutableArray array];
        NSMutableArray<NSString *> *covered = [existing mutableCopy];
        for (NSURL *url in urls) {
            NSString *path = url.URLByStandardizingPath.path;
            BOOL isDirectory = NO;
            if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
                continue;
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
        // Re-check against the live list: another batch may have landed while
        // this one's bookmarks were being created.
        if ([self.class path:addition[kEntryPathKey] isCoveredByAnyOf:self.grantedFolderPaths]) {
            continue;
        }
        [_entries addObject:[addition mutableCopy]];
        LogInfo(@"Granted folder added: %@", addition[kEntryPathKey]);
        changed = YES;
    }
    if (changed) {
        [self persist];
        [NSNotificationCenter.defaultCenter postNotificationName:FolderAccessManagerDidChangeNotification
                                                          object:self];
    }
}

// A folder inside an already-granted folder, or under ~/Music (the standing
// entitlement grant), needs no bookmark of its own. NSHomeDirectoryForUser
// gives the real home; NSHomeDirectory is the sandbox container.
+ (BOOL)path:(NSString *)path isCoveredByAnyOf:(NSArray<NSString *> *)grantedPaths {
    NSString *musicRoot = [NSHomeDirectoryForUser(NSUserName()) stringByAppendingPathComponent:@"Music"];
    for (NSString *granted in [grantedPaths arrayByAddingObject:musicRoot]) {
        if ([path isEqualToString:granted] || [path hasPrefix:[granted stringByAppendingString:@"/"]]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Removing

- (void)removeFolderAtIndex:(NSUInteger)index {
    if (index >= _entries.count) {
        return;
    }
    NSMutableDictionary *entry = _entries[index];
    NSURL *accessed = entry[kEntryAccessedURLKey];
    [accessed stopAccessingSecurityScopedResource];
    LogInfo(@"Granted folder removed: %@", entry[kEntryPathKey]);
    [_entries removeObjectAtIndex:index];
    [self persist];
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

@end
