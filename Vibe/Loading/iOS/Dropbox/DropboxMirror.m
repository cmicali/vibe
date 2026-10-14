//
//  DropboxMirror.m
//  Vibe (iOS)
//

#import "DropboxMirror.h"

#include <sys/stat.h>

#import "DropboxRules.h"
#import "FileSearchRules.h"
#import "FilePaths.h"
#import "LinkRules.h"
#import "PlaceholderFiles.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"
#import "RemotePlaceholderStoreInternal.h"

// list_folder's own maximum page.
static const NSInteger kListPageLimit = 2000;
NSNotificationName const VibeDropboxDownloadsDidChangeNotification = @"VibeDropboxDownloadsDidChangeNotification";
NSString *const VibeDropboxDownloadsBytesKey = @"bytes";

NSString *const VibeDropboxDownloadBudgetKey = @"VibeiOSDropboxDownloadBudget";
// Search uses the first page only.
static const NSInteger kSearchResultLimit = 50;
// A part file this old belongs to a download that died with the process.
static const NSTimeInterval kStalePartSeconds = 24 * 60 * 60;
// On every mirror directory: {"path": its Dropbox path, "files": {index key:
// Dropbox id}}. Under linksURL, "link" is the shared link, "path" is below it,
// and each file's entry is its path below the link. On the directory, not the
// files, because a placeholder's attributes are as unreadable as its bytes.
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
        NSString *appKey = [NSBundle.mainBundle objectForInfoDictionaryKey:VibeDropboxAppKeyInfoKey];
        NSAssert(appKey.length > 0, @"%@ missing from Info.plist", VibeDropboxAppKeyInfoKey);
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        // Fail fast offline: a waiting request holds a materialization lane.
        configuration.waitsForConnectivity = NO;
        DropboxClient *client = [[DropboxClient alloc] initWithAppKey:appKey ?: @""
                                                      keychainService:VibeDropboxKeychainService
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

// Beside the account's directory, not in it: a listing of the account's root
// deletes every name Dropbox does not hold there.
- (NSURL *)linksURL {
    NSString *account = self.accountURL.lastPathComponent;
    return account ? [self.rootURL URLByAppendingPathComponent:[account stringByAppendingString:@" links"]
                                                   isDirectory:YES]
                   : nil;
}

// A signed-out or replaced account's files go, its links' too: they are a
// cache of an account the app no longer reaches, and its downloads are disk
// the user cannot see or free otherwise.
- (void)pruneOtherAccounts:(NSNotification *)notification {
    NSString *keep = self.accountURL.lastPathComponent;
    NSString *keepLinks = self.linksURL.lastPathComponent;
    NSURL *root = self.rootURL;
    dispatch_async(self.diskQueue, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        for (NSString *name in [files contentsOfDirectoryAtPath:root.path error:NULL]) {
            if (![name isEqualToString:keep] && ![name isEqualToString:keepLinks]) {
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
// recorded, which no spelling or later rename can miss. Under linksURL it is
// {url, path}: the link, and the file's path below it as the listing spelled
// it. Nil outside the linked account's trees.
- (id)remoteTargetForURL:(NSURL *)url error:(NSError **)error {
    NSString *derived = [self derivedDropboxPathForURL:url];
    NSURL *links = self.linksURL;
    BOOL linked = links && VibeSearchRootCoversPath(VibeComparablePath(links.path), VibeComparablePath(url.path));
    if (derived.length == 0 && !linked) {
        if (error) *error = VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"not in the Dropbox mirror");
        return nil;
    }
    NSDictionary *index = [self indexOfDirectory:url.URLByDeletingLastPathComponent];
    NSDictionary *files = index[@"files"];
    NSString *identifier = [files isKindOfClass:NSDictionary.class]
            ? files[VibeDropboxIndexKey(url.lastPathComponent)] : nil;
    if (!linked) {
        return [identifier isKindOfClass:NSString.class] ? identifier : derived;
    }
    NSString *link = index[@"link"];
    if (![link isKindOfClass:NSString.class] || ![identifier isKindOfClass:NSString.class]) {
        if (error) *error = VibeDropboxMakeError(VibeDropboxErrorAPI, @"not listed from its shared link");
        return nil;
    }
    return @{@"url": link, @"path": identifier};
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

// Answers the playlist files to fetch, each {target, url}: they are read
// while the folder opens, so they come down with the listing; tracks wait for
// their open. *discarded is set when downloaded bytes went: a changed file
// back to a placeholder, or a departed file or folder deleted. With link, the
// folder is that shared link's: its entries name no path, and each one's is
// the folder's and its name as Dropbox spells it.
- (NSArray<NSDictionary *> *)reconcileDirectory:(NSURL *)directory
                                           path:(NSString *)folderPath
                                           link:(nullable NSString *)link
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
        if (link) {
            identifier = [folderPath stringByAppendingFormat:@"/%@", name];
        }
        if (kind == VibeDropboxEntryKindFolder) {
            NSString *local = VibeDropboxLocalName(name, existingNames);
            [kept addObject:local];
            NSURL *child = [directory URLByAppendingPathComponent:local isDirectory:YES];
            [self ensureDirectoryAtURL:child];
            NSString *childPath = link ? identifier : entry[@"path_lower"];
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
                id target = link ? @{@"url": link, @"path": identifier} : identifier;
                [sidecars addObject:@{@"target": target, @"url": url}];
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

    NSMutableDictionary *index = [@{@"path": folderPath, @"files": identifiers} mutableCopy];
    index[@"link"] = link;
    [self writeIndex:index ofDirectory:directory];

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

// With link, path is below that shared link, which lists one level at a
// time.
- (void)listFolder:(NSString *)path
              link:(nullable NSString *)link
            cursor:(NSString *)cursor
           entries:(NSMutableArray<NSDictionary *> *)entries
        completion:(void (^)(NSArray<NSDictionary *> *entries, NSError *error))completion {
    NSString *endpoint = cursor ? @"files/list_folder/continue" : @"files/list_folder";
    NSMutableDictionary *arguments = cursor
            ? [@{@"cursor": cursor} mutableCopy]
            : [@{@"path": path, @"recursive": @NO, @"include_deleted": @NO,
                 @"include_non_downloadable_files": @NO, @"limit": @(kListPageLimit)} mutableCopy];
    if (link && !cursor) {
        arguments[@"shared_link"] = @{@"url": link};
    }
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
            [self listFolder:path link:link cursor:next entries:entries completion:completion];
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
    [self refreshFolder:path link:nil base:account account:account
             completion:^(NSURL *directory, NSArray<NSString *> *folders, NSError *error) {
        completion(directory, error);
    }];
}

// Lists one folder, the account's or, with link, one of that shared link's,
// and makes its directory under base match. folders are the paths of the
// folders it holds, as the next listings name them. account is the account
// base belongs to, which must still be linked when the listing lands.
// Completion on main.
- (void)refreshFolder:(NSString *)path
                 link:(nullable NSString *)link
                 base:(NSURL *)base
              account:(NSURL *)account
           completion:(void (^)(NSURL *_Nullable directory, NSArray<NSString *> *_Nullable folders,
                                NSError *_Nullable error))completion {
    void (^finish)(NSURL *, NSError *) = ^(NSURL *directory, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(directory, nil, error);
        });
    };
    [self listFolder:path link:link cursor:nil entries:[NSMutableArray array]
          completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        if (error) {
            finish(nil, error);
            return;
        }
        NSMutableArray<NSString *> *folders = [NSMutableArray array];
        for (NSDictionary *entry in entries) {
            NSString *name = entry[@"name"];
            NSString *childPath = link && [name isKindOfClass:NSString.class]
                    ? [path stringByAppendingFormat:@"/%@", name] : entry[@"path_lower"];
            if (VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder && [childPath isKindOfClass:NSString.class]) {
                [folders addObject:childPath];
            }
        }
        dispatch_async(self.diskQueue, ^{
            // Signed out while listing: write nothing into a pruned tree.
            if (![self.accountURL isEqual:account]) {
                finish(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"Dropbox account changed"));
                return;
            }
            NSURL *directory = [self directoryForDropboxPath:path account:base];
            BOOL discarded = NO;
            NSArray<NSDictionary *> *sidecars = [self reconcileDirectory:directory path:path link:link
                                                             withEntries:entries discarded:&discarded];
            if (discarded) {
                // Rare — a file changed or left Dropbox after it was
                // downloaded — so the walk the total needs is paid here.
                long long total = 0;
                NSURL *budgetRoot = self.budgetRootURL;
                for (NSDictionary *download in budgetRoot ? [self downloadsUnder:budgetRoot] : @[]) {
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
                [self downloadTarget:sidecar[@"target"] installingAtURL:sidecar[@"url"] progress:nil
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
                completion(directory, folders, nil);
            });
        });
    }];
}

#pragma mark - Shared links

- (void)openSharedFolderLink:(NSURL *)link
                  completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *account = self.accountURL;
    NSURL *links = self.linksURL;
    if (!account || !links) {
        completion(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"no Dropbox account"));
        return;
    }
    void (^finish)(NSURL *, NSError *) = ^(NSURL *folderURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(folderURL, error);
        });
    };
    NSString *address = link.absoluteString;
    [self.client callEndpoint:@"sharing/get_shared_link_metadata" arguments:@{@"url": address}
                   completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            finish(nil, error);
            return;
        }
        NSString *name = [result[@"name"] isKindOfClass:NSString.class] ? result[@"name"] : nil;
        if (VibeDropboxEntryKindOf(result) != VibeDropboxEntryKindFolder) {
            finish(nil, VibeDropboxMakeError(VibeDropboxErrorAPI, @"the shared link is not a folder"));
            return;
        }
        if (name.length == 0 || [name containsString:@"/"] || [name hasPrefix:@"."]) {
            name = @"Dropbox";
        }
        dispatch_async(self.diskQueue, ^{
            // Signed out, or another account, since the call: its links' tree
            // is pruned, or is the wrong one.
            if (![self.accountURL isEqual:account]) {
                finish(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"Dropbox account changed"));
                return;
            }
            // One directory per link, holding the folder under its own name.
            // A name the folder had before goes.
            NSURL *holder = [links URLByAppendingPathComponent:VibeLinkDirectoryName(link) isDirectory:YES];
            [self prepareRoot];
            [self ensureDirectoryAtURL:links];
            [self ensureDirectoryAtURL:holder];
            NSFileManager *files = NSFileManager.defaultManager;
            for (NSString *entry in [files contentsOfDirectoryAtPath:holder.path error:NULL]) {
                if (![entry isEqualToString:name]) {
                    [files removeItemAtURL:[holder URLByAppendingPathComponent:entry] error:NULL];
                    [self forgetCachedIndexes];
                }
            }
            NSURL *base = [holder URLByAppendingPathComponent:name isDirectory:YES];
            [self refreshLinkFolders:[NSMutableArray arrayWithObject:@""] link:address base:base account:account
                          completion:^(NSError *listError) {
                LogInfo(@"Dropbox: %@ a shared folder through the account", listError ? @"could not list" : @"listed");
                finish(listError ? nil : base, listError);
            }];
        });
    }];
}

// Each of the link's folders in turn, from `paths`, with the folders each
// listing finds after it, until none is left. Any failure ends it.
- (void)refreshLinkFolders:(NSMutableArray<NSString *> *)paths
                      link:(NSString *)link
                      base:(NSURL *)base
                   account:(NSURL *)account
                completion:(void (^)(NSError *_Nullable error))completion {
    if (paths.count == 0) {
        completion(nil);
        return;
    }
    NSString *path = paths.firstObject;
    [paths removeObjectAtIndex:0];
    [self refreshFolder:path link:link base:base account:account
             completion:^(NSURL *directory, NSArray<NSString *> *folders, NSError *error) {
        if (error) {
            completion(error);
            return;
        }
        [paths addObjectsFromArray:folders];
        [self refreshLinkFolders:paths link:link base:base account:account completion:completion];
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
        // Listed on the disk queue, which writes the folder's names, never main.
        dispatch_async(self.diskQueue, ^{
            NSArray<NSString *> *existing = [NSFileManager.defaultManager
                    contentsOfDirectoryAtPath:folderURL.path error:NULL] ?: @[];
            NSURL *url = [folderURL URLByAppendingPathComponent:VibeDropboxLocalName(name, VibeDropboxNameIndex(existing))
                                                    isDirectory:NO];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(url, nil);
            });
        });
    }];
}

#pragma mark - The store's hooks

// Downloaded bytes take the version's mtime, so the next listing sees them
// as current.
- (time_t)modificationTimeOfMetadata:(NSDictionary *)metadata forURL:(NSURL *)url {
    return VibeDropboxParseTimestamp(metadata[@"server_modified"]);
}

// The account's tree and its links' tree, which are all the root holds while
// linked: a link or sign-out prunes every other directory.
- (NSURL *)budgetRootURL {
    return self.accountURL ? self.rootURL : nil;
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
