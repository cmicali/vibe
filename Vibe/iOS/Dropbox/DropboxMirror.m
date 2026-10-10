//
//  DropboxMirror.m
//  Vibe (iOS)
//

#import "DropboxMirror.h"

#include <sys/stat.h>

#import "DropboxRules.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"
#import "RemotePlaceholderStoreInternal.h"

static NSString *const kKeychainService = @"com.commonwealthrecordings.Vibe.dropbox";
static NSString *const kAppKeyInfoKey = @"VibeDropboxAppKey";
// list_folder's own maximum page.
static const NSInteger kListPageLimit = 2000;
NSNotificationName const VibeDropboxDownloadsDidChangeNotification = @"VibeDropboxDownloadsDidChangeNotification";
NSString *const VibeDropboxDownloadsBytesKey = @"bytes";

NSString *const VibeDropboxDownloadBudgetKey = @"VibeiOSDropboxDownloadBudget";
// A search answers in one page; nobody scrolls past this on a phone.
static const NSInteger kSearchResultLimit = 50;
// A part file this old belongs to a download that died with the process.
static const NSTimeInterval kStalePartSeconds = 24 * 60 * 60;
// On every mirror directory: {"path": its Dropbox path, "files": {index key:
// Dropbox id}}. On the directory, not the files, because a placeholder's
// attributes are as unreadable as its bytes.
static NSString *const kIndexAttribute = @"com.commonwealthrecordings.vibe.dropbox";

@implementation DropboxMirror {
    // The disk queue's: the sheets being fetched, by local path, each with
    // the refreshes waiting on it. The claim on a sheet's download.
    NSMutableDictionary<NSString *, NSMutableArray<dispatch_block_t> *> *_sidecarWaiters;
}

// The store's, typed as the Dropbox client it was made with.
@dynamic client;

+ (DropboxMirror *)shared {
    static DropboxMirror *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *appKey = [NSBundle.mainBundle objectForInfoDictionaryKey:kAppKeyInfoKey];
        NSAssert(appKey.length > 0, @"%@ missing from Info.plist", kAppKeyInfoKey);
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        // Fail fast offline: a waiting request holds a materialization lane.
        configuration.waitsForConnectivity = NO;
        DropboxClient *client = [[DropboxClient alloc] initWithAppKey:appKey ?: @""
                                                      keychainService:kKeychainService
                                                        configuration:configuration];
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                              inDomain:NSUserDomainMask
                                                     appropriateForURL:nil
                                                                create:YES
                                                                 error:NULL];
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:VibeDropboxDownloadBudgetKey];
        shared = [[DropboxMirror alloc] initWithClient:client
                                               rootURL:[support URLByAppendingPathComponent:@"Dropbox"
                                                                                isDirectory:YES]
                                        downloadBudget:kVibeDropboxDownloadBudgets[VibeDropboxDownloadBudgetIndex(saved)]];
    });
    return shared;
}

- (instancetype)initWithClient:(DropboxClient *)client
                       rootURL:(NSURL *)rootURL
                downloadBudget:(long long)downloadBudget {
    self = [super initWithClient:client rootURL:rootURL indexAttribute:kIndexAttribute downloadBudget:downloadBudget];
    if (self) {
        _sidecarWaiters = [NSMutableDictionary dictionary];
        // Not pruned here: before first unlock the Keychain reads as no
        // account, and that must not cost the user their downloads.
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(pruneOtherAccounts:)
                                                   name:VibeDropboxAccountDidChangeNotification
                                                 object:client];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - The index

// A folder its parent's listing made carries only its path; one listed
// itself carries its files.
- (BOOL)hasListedDirectory:(NSURL *)url {
    return [self indexOfDirectory:url][@"files"] != nil;
}

#pragma mark - Account

// Dropbox account ids carry a colon, which a file name keeps; nothing else
// in them needs escaping.
- (NSURL *)accountURL {
    NSString *accountID = self.client.accountID;
    if (accountID.length == 0) {
        return nil;
    }
    NSString *name = [accountID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [self.rootURL URLByAppendingPathComponent:name isDirectory:YES];
}

// A signed-out or replaced account's files go: they are a cache of an
// account the app no longer reaches, and its downloads are disk the user
// cannot see or free otherwise.
- (void)pruneOtherAccounts:(NSNotification *)notification {
    NSString *keep = self.accountURL.lastPathComponent;
    NSURL *root = self.rootURL;
    dispatch_async(self.diskQueue, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        for (NSString *name in [files contentsOfDirectoryAtPath:root.path error:NULL]) {
            if (![name isEqualToString:keep]) {
                [files removeItemAtURL:[root URLByAppendingPathComponent:name] error:NULL];
            }
        }
        [self forgetCachedIndexes];
    });
}

// The path below the account, derived from local names and composed again
// (see VibeDropboxIndexKey); nil outside the account's mirror.
- (NSString *)derivedDropboxPathForURL:(NSURL *)url {
    NSURL *account = self.accountURL;
    if (!account || !url.isFileURL) {
        return nil;
    }
    NSString *base = VibeComparablePath(account.path);
    NSString *path = VibeComparablePath(url.path);
    if (!VibeSearchRootCoversPath(base, path)) {
        return nil;
    }
    return [path substringFromIndex:base.length].precomposedStringWithCanonicalMapping;
}

- (NSString *)dropboxPathForURL:(NSURL *)url {
    NSString *derived = [self derivedDropboxPathForURL:url];
    if (derived.length == 0) {
        return derived;
    }
    // A listed directory knows its exact Dropbox path.
    NSString *indexed = [self indexOfDirectory:url][@"path"];
    return [indexed isKindOfClass:NSString.class] ? indexed : derived;
}

// What files/download is asked for: the Dropbox id the folder's listing
// recorded, which no spelling or later rename can miss; nil outside the
// account's mirror.
- (id)remoteTargetForURL:(NSURL *)url error:(NSError **)error {
    NSString *derived = [self derivedDropboxPathForURL:url];
    if (derived.length == 0) {
        if (error) *error = VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"not in the Dropbox mirror");
        return nil;
    }
    NSDictionary *files = [self indexOfDirectory:url.URLByDeletingLastPathComponent][@"files"];
    NSString *identifier = [files isKindOfClass:NSDictionary.class]
            ? files[VibeDropboxIndexKey(url.lastPathComponent)] : nil;
    return [identifier isKindOfClass:NSString.class] ? identifier : derived;
}

#pragma mark - Disk (the disk queue)

// Each component matched case-insensitively against what is there; missing
// directories are made (a file in the way is replaced).
- (NSURL *)directoryForDropboxPath:(NSString *)path account:(NSURL *)account {
    NSFileManager *files = NSFileManager.defaultManager;
    [self prepareRoot];
    [self ensureDirectoryAtURL:account];
    NSURL *directory = account;
    // TRAP: listed, not probed: on a case-insensitive volume an lstat of
    // another spelling succeeds, and the URL would carry that spelling.
    for (NSString *component in VibeDropboxPathComponents(path)) {
        NSArray<NSString *> *existing = [files contentsOfDirectoryAtPath:directory.path error:NULL] ?: @[];
        directory = [directory URLByAppendingPathComponent:
                VibeDropboxLocalName(component, VibeDropboxNameIndex(existing)) isDirectory:YES];
        [self ensureDirectoryAtURL:directory];
    }
    return directory;
}

- (void)ensureDirectoryAtURL:(NSURL *)url {
    struct stat st;
    if (lstat(url.fileSystemRepresentation, &st) == 0) {
        if (S_ISDIR(st.st_mode)) {
            return;
        }
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO
                                            attributes:nil error:NULL];
}

// Answers the CUE sheets to fetch: they are read while the folder opens, so
// they come down with the listing; tracks wait for their open. *discarded is
// set when downloaded bytes went: a changed file back to a placeholder, or a
// departed file or folder deleted.
- (NSArray<NSDictionary *> *)reconcileDirectory:(NSURL *)directory
                                           path:(NSString *)folderPath
                                    withEntries:(NSArray<NSDictionary *> *)entries
                                      discarded:(BOOL *)discarded {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSString *> *identifiers = [NSMutableDictionary dictionary];
    NSArray<NSString *> *existing = [files contentsOfDirectoryAtPath:directory.path error:NULL] ?: @[];
    NSDictionary<NSString *, NSString *> *existingNames = VibeDropboxNameIndex(existing);
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    NSMutableSet<NSString *> *kept = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *sidecars = [NSMutableArray array];
    NSUInteger placeholders = 0;

    for (NSDictionary *entry in entries) {
        NSString *name = entry[@"name"];
        if (![name isKindOfClass:NSString.class] || name.length == 0) {
            continue;
        }
        VibeDropboxEntryKind kind = VibeDropboxEntryKindOf(entry);
        NSString *identifier = entry[@"id"];
        if (![identifier isKindOfClass:NSString.class]) {
            identifier = entry[@"path_lower"];
        }
        if (kind == VibeDropboxEntryKindFolder) {
            NSString *local = VibeDropboxLocalName(name, existingNames);
            [kept addObject:local];
            NSURL *child = [directory URLByAppendingPathComponent:local isDirectory:YES];
            [self ensureDirectoryAtURL:child];
            NSString *childPath = entry[@"path_lower"];
            if ([childPath isKindOfClass:NSString.class]) {
                NSMutableDictionary *index = [[self indexOfDirectory:child] mutableCopy]
                        ?: [NSMutableDictionary dictionary];
                index[@"path"] = childPath;
                [self writeIndex:index ofDirectory:child];
            }
            continue;
        }
        if (kind != VibeDropboxEntryKindFile || !VibeDropboxNameIsMirrored(name, playable)) {
            continue;
        }
        NSString *local = VibeDropboxLocalName(name, existingNames);
        [kept addObject:local];
        if ([identifier isKindOfClass:NSString.class]) {
            identifiers[VibeDropboxIndexKey(local)] = identifier;
        }
        NSURL *url = [directory URLByAppendingPathComponent:local isDirectory:NO];
        long long size = [entry[@"size"] longLongValue];
        time_t modified = VibeDropboxParseTimestamp(entry[@"server_modified"]);
        struct stat st;
        BOOL present = lstat(url.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode);
        if (present && VibeDropboxLocalMatchesEntry(st.st_size, st.st_mtimespec.tv_sec, size, modified)) {
            continue;
        }
        if ([PlaylistFile isPlaylistExtension:name.pathExtension.lowercaseString]) {
            if ([identifier isKindOfClass:NSString.class]) {
                [sidecars addObject:@{@"path": identifier, @"url": url}];
            }
            continue;
        }
        if ([DropboxMirror writePlaceholderAtURL:url size:size modified:modified]) {
            placeholders++;
            *discarded = *discarded || (present && !VibeFileModeIsRemotePlaceholder(st.st_mode));
        }
        else {
            LogWarn(@"Dropbox: could not write placeholder %@: %s", local, strerror(errno));
        }
    }

    [self writeIndex:@{@"path": folderPath, @"files": identifiers} ofDirectory:directory];

    time_t staleBefore = time(NULL) - (time_t)kStalePartSeconds;
    for (NSString *name in existing) {
        NSURL *url = [directory URLByAppendingPathComponent:name];
        if ([name hasPrefix:@"."]) {
            // TRAP: by ctime, not mtime. The install dates a live part to its
            // version's server_modified just before the rename, and an mtime
            // sweep landing between the two would delete a finished download.
            struct stat st;
            if ([name hasSuffix:VibeRemotePlaceholderPartSuffix] && lstat(url.fileSystemRepresentation, &st) == 0
                    && st.st_ctimespec.tv_sec < staleBefore) {
                [files removeItemAtURL:url error:NULL];
            }
            continue;
        }
        if (![kept containsObject:name]) {
            // TRAP: a departed directory takes its cached index with it, and
            // its descendants'. Kept, a folder that comes back on Dropbox is
            // made empty here, its unchanged index skips the xattr write, and
            // it reads as listed: Play on its row opened nothing. The cache
            // cannot name a subtree, so it goes whole — for a departed file
            // too, which is rare enough not to tell apart — and refills from
            // the xattrs.
            struct stat st;
            if (lstat(url.fileSystemRepresentation, &st) == 0
                    && (S_ISDIR(st.st_mode) || (S_ISREG(st.st_mode) && !VibeFileModeIsRemotePlaceholder(st.st_mode)
                                                && ![PlaylistFile isPlaylistExtension:name.pathExtension.lowercaseString]))) {
                *discarded = YES;   // a folder may hold downloads; not walked to find out
            }
            [files removeItemAtURL:url error:NULL];
            [self forgetCachedIndexes];
        }
    }
    LogInfo(@"Dropbox: reconciled %@: %lu entries, %lu new placeholders, %lu sidecars",
            directory.lastPathComponent, (unsigned long)entries.count,
            (unsigned long)placeholders, (unsigned long)sidecars.count);
    return sidecars;
}

#pragma mark - Listing

- (void)listFolder:(NSString *)path
            cursor:(NSString *)cursor
           entries:(NSMutableArray<NSDictionary *> *)entries
        completion:(void (^)(NSArray<NSDictionary *> *entries, NSError *error))completion {
    NSString *endpoint = cursor ? @"files/list_folder/continue" : @"files/list_folder";
    NSDictionary *arguments = cursor
            ? @{@"cursor": cursor}
            : @{@"path": path, @"recursive": @NO, @"include_deleted": @NO,
                @"include_non_downloadable_files": @NO, @"limit": @(kListPageLimit)};
    [self.client callEndpoint:endpoint arguments:arguments
               completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSArray *page = result[@"entries"];
        if ([page isKindOfClass:NSArray.class]) {
            for (id entry in page) {
                if ([entry isKindOfClass:NSDictionary.class]) {
                    [entries addObject:entry];
                }
            }
        }
        NSString *next = result[@"cursor"];
        if ([result[@"has_more"] boolValue] && [next isKindOfClass:NSString.class]) {
            [self listFolder:path cursor:next entries:entries completion:completion];
            return;
        }
        completion(entries, nil);
    }];
}

- (void)refreshDropboxFolder:(NSString *)path
                  completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *account = self.accountURL;
    if (!account) {
        completion(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"no Dropbox account"));
        return;
    }
    void (^finish)(NSURL *, NSError *) = ^(NSURL *directory, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(directory, error);
        });
    };
    [self listFolder:path cursor:nil entries:[NSMutableArray array]
          completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        if (error) {
            finish(nil, error);
            return;
        }
        dispatch_async(self.diskQueue, ^{
            // Signed out while listing: write nothing into a pruned tree.
            if (![self.accountURL isEqual:account]) {
                finish(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"Dropbox account changed"));
                return;
            }
            NSURL *directory = [self directoryForDropboxPath:path account:account];
            BOOL discarded = NO;
            NSArray<NSDictionary *> *sidecars = [self reconcileDirectory:directory path:path withEntries:entries
                                                               discarded:&discarded];
            if (discarded) {
                // Rare — a file changed or left Dropbox after it was
                // downloaded — so the walk the total needs is paid here.
                long long total = 0;
                for (NSDictionary *download in [self downloadsUnder:account]) {
                    total += [download[@"size"] longLongValue];
                }
                [self downloadsDidChangeWithTotal:total];
            }
            // Side by side and off the disk queue, which other refreshes need.
            // TRAP: one download per sheet. Two refreshes of one folder both
            // find it missing, and two downloads share its part file: the
            // second's response unlinks the first's, and the first to finish
            // renames the other's half-written bytes into place, where the
            // folder's open reads them. A refresh that finds the sheet
            // claimed waits on that download instead.
            dispatch_group_t fetched = dispatch_group_create();
            for (NSDictionary *sidecar in sidecars) {
                dispatch_group_enter(fetched);
                dispatch_block_t leave = ^{
                    dispatch_group_leave(fetched);
                };
                NSString *key = [sidecar[@"url"] path];
                NSMutableArray<dispatch_block_t> *waiters = self->_sidecarWaiters[key];
                if (waiters) {
                    [waiters addObject:leave];
                    continue;
                }
                self->_sidecarWaiters[key] = [NSMutableArray arrayWithObject:leave];
                [self downloadTarget:sidecar[@"path"] installingAtURL:sidecar[@"url"] progress:nil
                          completion:^(NSError *fetchError) {
                    if (fetchError) {
                        LogWarn(@"Dropbox: could not fetch %@: %@",
                                [sidecar[@"url"] lastPathComponent], fetchError.localizedDescription);
                    }
                    dispatch_async(self.diskQueue, ^{
                        NSArray<dispatch_block_t> *settled = self->_sidecarWaiters[key];
                        [self->_sidecarWaiters removeObjectForKey:key];
                        for (dispatch_block_t each in settled) {
                            each();
                        }
                    });
                }];
            }
            dispatch_group_notify(fetched, dispatch_get_main_queue(), ^{
                completion(directory, nil);
            });
        });
    }];
}

#pragma mark - Search

- (void)searchQuery:(NSString *)query
         completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    NSDictionary *arguments = @{
        @"query": query,
        @"options": @{
            @"max_results": @(kSearchResultLimit),
            @"file_status": @"active",
            @"file_categories": @[@{@".tag": @"audio"}, @{@".tag": @"folder"}],
        },
    };
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    [self.client callEndpoint:@"files/search_v2" arguments:arguments
               completion:^(NSDictionary *result, NSError *error) {
        NSArray<NSDictionary *> *entries = error ? nil : VibeDropboxSearchEntries(result, playable);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(entries, error);
        });
    }];
}

// Listed by path_display, not path_lower: a folder not mirrored yet is made
// in the spelling it is listed by, and path_lower would name it in lowercase.
// Dropbox matches either.
- (void)localURLForEntry:(NSDictionary *)entry
              completion:(void (^)(NSURL *, NSError *))completion {
    NSString *path = [entry[@"path_display"] isKindOfClass:NSString.class]
            ? entry[@"path_display"] : entry[@"path_lower"];
    if (![path isKindOfClass:NSString.class]) {
        completion(nil, VibeDropboxMakeError(VibeDropboxErrorAPI, @"entry without a path"));
        return;
    }
    if (VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder) {
        [self refreshDropboxFolder:path completion:completion];
        return;
    }
    NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : path.lastPathComponent;
    [self refreshDropboxFolder:VibeDropboxParentPath(path) completion:^(NSURL *folderURL, NSError *error) {
        if (!folderURL) {
            completion(nil, error);
            return;
        }
        NSArray<NSString *> *existing = [NSFileManager.defaultManager
                contentsOfDirectoryAtPath:folderURL.path error:NULL] ?: @[];
        NSString *local = VibeDropboxLocalName(name, VibeDropboxNameIndex(existing));
        completion([folderURL URLByAppendingPathComponent:local isDirectory:NO], nil);
    }];
}

#pragma mark - The store's hooks

// Downloaded bytes take the version's mtime, so the next listing sees them
// as current.
- (time_t)modificationTimeOfMetadata:(NSDictionary *)metadata forURL:(NSURL *)url {
    return VibeDropboxParseTimestamp(metadata[@"server_modified"]);
}

- (NSURL *)budgetRootURL {
    return self.accountURL;
}

// Any thread; posted on main. Every reader of a row's downloaded state hears
// it — Search's marks, a mirrored folder on screen, the size in Settings —
// whichever way the bytes came or went.
- (void)downloadsDidChangeWithTotal:(long long)total {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VibeDropboxDownloadsDidChangeNotification
                                                          object:self
                                                        userInfo:@{VibeDropboxDownloadsBytesKey: @(total)}];
    });
}

- (NSString *)logName {
    return @"Dropbox";
}

@end
