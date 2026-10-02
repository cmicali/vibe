//
//  DropboxMirror.m
//  Vibe (iOS)
//

#import "DropboxMirror.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/xattr.h>
#include <unistd.h>

#import "DropboxRules.h"
#import "FileSearchRules.h"
#import "NSURLUtil.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"

static NSString *const kKeychainService = @"com.commonwealthrecordings.Vibe.dropbox";
static NSString *const kAppKeyInfoKey = @"VibeDropboxAppKey";
// list_folder's own maximum page.
static const NSInteger kListPageLimit = 2000;
NSNotificationName const VibeDropboxDownloadsDidChangeNotification = @"VibeDropboxDownloadsDidChangeNotification";
NSString *const VibeDropboxDownloadsBytesKey = @"bytes";

// Downloads kept before the oldest go back to placeholders: an album or two
// hundred, which a phone can spare and a re-download rarely has to replace.
static const long long kDownloadBudgetBytes = 10LL * 1000 * 1000 * 1000;
// A ranged read slower than this is given up, so a stalled request cannot
// hold a parse worker; the parse fails and a later scan retries it.
static const NSTimeInterval kRangedReadTimeout = 30;
// A search answers in one page; nobody scrolls past this on a phone.
static const NSInteger kSearchResultLimit = 50;
// A part file this old belongs to a download that died with the process.
static const NSTimeInterval kStalePartSeconds = 24 * 60 * 60;

// On every mirror directory: {"path": its Dropbox path, "files": {index key:
// Dropbox id}}. On the directory, not the files, because a placeholder's
// attributes are as unreadable as its bytes.
static const char *const kIndexAttribute = "com.commonwealthrecordings.vibe.dropbox";

static NSError *VibePOSIXError(void) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
}

@implementation DropboxMirror {
    long long _downloadBudget;
    // Serial: every change to the mirror's directories, so two refreshes of
    // one folder cannot interleave their reconciles.
    dispatch_queue_t _diskQueue;
    // Parsed directory indexes by path, NSNull for "none"; a ranged read asks
    // for one per block. Every write replaces its entry.
    NSCache<NSString *, id> *_indexes;
    // The disk queue's: the root exists and is kept out of backups.
    BOOL _rootPrepared;
}

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
        shared = [[DropboxMirror alloc] initWithClient:client
                                               rootURL:[support URLByAppendingPathComponent:@"Dropbox"
                                                                                isDirectory:YES]
                                        downloadBudget:kDownloadBudgetBytes];
    });
    return shared;
}

- (instancetype)initWithClient:(DropboxClient *)client
                       rootURL:(NSURL *)rootURL
                downloadBudget:(long long)downloadBudget {
    self = [super init];
    if (self) {
        _client = client;
        _rootURL = [rootURL copy];
        _downloadBudget = downloadBudget;
        _indexes = [[NSCache alloc] init];
        _diskQueue = dispatch_queue_create("com.commonwealthrecordings.Vibe.dropbox-mirror",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
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

// Keyed by the comparable spelling: a write through /var and a read through
// /private/var are one directory.
- (NSDictionary *)indexOfDirectory:(NSURL *)directory {
    return [self indexOfDirectory:directory key:VibeComparablePath(directory.path)];
}

- (BOOL)hasListedDirectory:(NSURL *)url {
    return [self indexOfDirectory:url] != nil;
}

- (NSDictionary *)indexOfDirectory:(NSURL *)directory key:(NSString *)key {
    id cached = [_indexes objectForKey:key];
    if (cached) {
        return cached == NSNull.null ? nil : cached;
    }
    NSDictionary *index = nil;
    const char *path = directory.fileSystemRepresentation;
    ssize_t size = getxattr(path, kIndexAttribute, NULL, 0, 0, XATTR_NOFOLLOW);
    if (size > 0) {
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)size];
        if (getxattr(path, kIndexAttribute, data.mutableBytes, (size_t)size, 0, XATTR_NOFOLLOW) == size) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            index = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        }
    }
    [_indexes setObject:index ?: NSNull.null forKey:key];
    return index;
}

// Unchanged indexes are not rewritten: every visit relists its folder.
- (void)writeIndex:(NSDictionary *)index ofDirectory:(NSURL *)directory {
    NSString *key = VibeComparablePath(directory.path);
    if ([[self indexOfDirectory:directory key:key] isEqualToDictionary:index]) {
        return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:index options:0 error:NULL];
    if (setxattr(directory.fileSystemRepresentation, kIndexAttribute, data.bytes, data.length, 0, XATTR_NOFOLLOW) != 0) {
        LogWarn(@"Dropbox: could not index %@: %s", directory.lastPathComponent, strerror(errno));
        [_indexes removeObjectForKey:key];
        return;
    }
    [_indexes setObject:index forKey:key];
}

#pragma mark - Account

// Dropbox account ids carry a colon, which a file name keeps; nothing else
// in them needs escaping.
- (NSURL *)accountURL {
    NSString *accountID = _client.accountID;
    if (accountID.length == 0) {
        return nil;
    }
    NSString *name = [accountID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [_rootURL URLByAppendingPathComponent:name isDirectory:YES];
}

// A signed-out or replaced account's files go: they are a cache of an
// account the app no longer reaches, and its downloads are disk the user
// cannot see or free otherwise.
- (void)pruneOtherAccounts:(NSNotification *)notification {
    NSString *keep = self.accountURL.lastPathComponent;
    NSURL *root = _rootURL;
    dispatch_async(_diskQueue, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        for (NSString *name in [files contentsOfDirectoryAtPath:root.path error:NULL]) {
            if (![name isEqualToString:keep]) {
                [files removeItemAtURL:[root URLByAppendingPathComponent:name] error:NULL];
            }
        }
        [self->_indexes removeAllObjects];
    });
}

- (BOOL)containsURL:(NSURL *)url {
    return url.isFileURL && VibeSearchRootCoversPath(VibeComparablePath(_rootURL.path),
                                                     VibeComparablePath(url.path));
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
- (NSString *)downloadArgumentForURL:(NSURL *)url {
    NSString *derived = [self derivedDropboxPathForURL:url];
    if (derived.length == 0) {
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
    if (!_rootPrepared) {
        [files createDirectoryAtURL:_rootURL withIntermediateDirectories:YES attributes:nil error:NULL];
        // The mirror is a cache of Dropbox: never in a backup.
        [_rootURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
        _rootPrepared = YES;
    }
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

// A sparse file of the remote size and mtime with no permissions, swapped in
// with one rename so no reader ever sees it half made.
static BOOL VibeWritePlaceholder(NSURL *url, long long size, time_t modified) {
    NSURL *directory = url.URLByDeletingLastPathComponent;
    NSURL *temp = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.vibe-placeholder", url.lastPathComponent]];
    unlink(temp.fileSystemRepresentation);
    int fd = open(temp.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) {
        return NO;
    }
    struct timeval times[2] = {{modified, 0}, {modified, 0}};
    BOOL made = ftruncate(fd, size) == 0 && futimes(fd, times) == 0 && fchmod(fd, 0) == 0;
    close(fd);
    struct stat st;
    if (made && lstat(url.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
    if (!made || rename(temp.fileSystemRepresentation, url.fileSystemRepresentation) != 0) {
        unlink(temp.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

// Downloaded bytes take the version's mtime, so the next listing sees them
// as current, then replace whatever stood at url in one rename.
static BOOL VibeInstallPart(NSURL *part, NSURL *url, NSDictionary *metadata, NSError **error) {
    time_t modified = VibeDropboxParseTimestamp(metadata[@"server_modified"]);
    if (chmod(part.fileSystemRepresentation, 0644) != 0) {
        if (error) *error = VibePOSIXError();
        unlink(part.fileSystemRepresentation);
        return NO;
    }
    if (modified >= 0) {
        struct timeval times[2] = {{modified, 0}, {modified, 0}};
        utimes(part.fileSystemRepresentation, times);
    }
    if (rename(part.fileSystemRepresentation, url.fileSystemRepresentation) != 0) {
        if (error) *error = VibePOSIXError();
        unlink(part.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

// The download into url's part file, then the install; completion on the
// client's queue. Returns the cancel.
- (dispatch_block_t)downloadDropboxPath:(NSString *)path
                                  toURL:(NSURL *)url
                             completion:(void (^)(NSError *_Nullable error))completion {
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:url];
    return [_client downloadPath:path toURL:part completion:^(NSDictionary *metadata, NSError *error) {
        NSError *installError = nil;
        if (!error && !VibeInstallPart(part, url, metadata, &installError)) {
            error = installError;
        }
        completion(error);
    }];
}

// Answers the CUE sheets to fetch: they are read while the folder opens, so
// they come down with the listing; tracks wait for their open.
- (NSArray<NSDictionary *> *)reconcileDirectory:(NSURL *)directory
                                           path:(NSString *)folderPath
                                    withEntries:(NSArray<NSDictionary *> *)entries {
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
        if (lstat(url.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)
                && VibeDropboxLocalMatchesEntry(st.st_size, st.st_mtimespec.tv_sec, size, modified)) {
            continue;
        }
        if ([PlaylistFile isCueExtension:name.pathExtension]) {
            if ([identifier isKindOfClass:NSString.class]) {
                [sidecars addObject:@{@"path": identifier, @"url": url}];
            }
            continue;
        }
        if (VibeWritePlaceholder(url, size, modified)) {
            placeholders++;
        }
        else {
            LogWarn(@"Dropbox: could not write placeholder %@: %s", local, strerror(errno));
        }
    }

    [self writeIndex:@{@"path": folderPath, @"files": identifiers} ofDirectory:directory];

    NSDate *staleBefore = [NSDate dateWithTimeIntervalSinceNow:-kStalePartSeconds];
    for (NSString *name in existing) {
        NSURL *url = [directory URLByAppendingPathComponent:name];
        if ([name hasPrefix:@"."]) {
            NSDate *modified = nil;
            [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:NULL];
            if ([name hasSuffix:VibeRemotePlaceholderPartSuffix]
                    && [modified compare:staleBefore] == NSOrderedAscending) {
                [files removeItemAtURL:url error:NULL];
            }
            continue;
        }
        if (![kept containsObject:name]) {
            [files removeItemAtURL:url error:NULL];
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
    [_client callEndpoint:endpoint arguments:arguments
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
        dispatch_async(self->_diskQueue, ^{
            // Signed out while listing: write nothing into a pruned tree.
            if (![self.accountURL isEqual:account]) {
                finish(nil, VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"Dropbox account changed"));
                return;
            }
            NSURL *directory = [self directoryForDropboxPath:path account:account];
            NSArray<NSDictionary *> *sidecars = [self reconcileDirectory:directory path:path withEntries:entries];
            // Side by side and off the disk queue, which other refreshes need.
            dispatch_group_t fetched = dispatch_group_create();
            for (NSDictionary *sidecar in sidecars) {
                dispatch_group_enter(fetched);
                [self downloadDropboxPath:sidecar[@"path"] toURL:sidecar[@"url"] completion:^(NSError *fetchError) {
                    if (fetchError) {
                        LogWarn(@"Dropbox: could not fetch %@: %@",
                                [sidecar[@"url"] lastPathComponent], fetchError.localizedDescription);
                    }
                    dispatch_group_leave(fetched);
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
    [_client callEndpoint:@"files/search_v2" arguments:arguments
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

#pragma mark - Downloads (the disk queue)

// Every downloaded song under the account, oldest download first. A sheet is
// not one: it is a few bytes the listing needs.
- (NSArray<NSDictionary *> *)downloadsUnder:(NSURL *)account {
    NSMutableArray<NSDictionary *> *downloads = [NSMutableArray array];
    NSDirectoryEnumerator<NSURL *> *walk = [NSFileManager.defaultManager
            enumeratorAtURL:account
 includingPropertiesForKeys:nil
                    options:NSDirectoryEnumerationSkipsHiddenFiles
               errorHandler:nil];
    for (NSURL *url in walk) {
        struct stat st;
        if (lstat(url.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)
                || VibeFileModeIsRemotePlaceholder(st.st_mode)
                || [PlaylistFile isCueExtension:url.pathExtension]) {
            continue;
        }
        [downloads addObject:@{@"url": url, @"size": @(st.st_size), @"modified": @(st.st_mtimespec.tv_sec),
                               @"downloaded": @(st.st_birthtimespec.tv_sec + st.st_birthtimespec.tv_nsec / 1e9)}];
    }
    [downloads sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"downloaded"] compare:b[@"downloaded"]];
    }];
    return downloads;
}

// Size and mtime are kept, so the cache key, and with it the cached tags and
// waveform, still match when the song is downloaded again.
- (BOOL)evictDownload:(NSDictionary *)download {
    return VibeWritePlaceholder(download[@"url"], [download[@"size"] longLongValue],
                                (time_t)[download[@"modified"] longLongValue]);
}

// Oldest first, never the one just fetched: it is about to be opened.
// Answers what the downloads take afterwards.
- (long long)enforceDownloadBudgetKeeping:(NSURL *)keep {
    NSURL *account = self.accountURL;
    if (!account) {
        return 0;
    }
    NSArray<NSDictionary *> *downloads = [self downloadsUnder:account];
    long long total = 0;
    for (NSDictionary *download in downloads) {
        total += [download[@"size"] longLongValue];
    }
    NSString *kept = VibeComparablePath(keep.path);
    for (NSDictionary *download in downloads) {
        if (total <= _downloadBudget) {
            break;
        }
        if ([VibeComparablePath([download[@"url"] path]) isEqualToString:kept]) {
            continue;
        }
        if ([self evictDownload:download]) {
            total -= [download[@"size"] longLongValue];
            LogInfo(@"Dropbox: over budget, %@ back to a placeholder", [download[@"url"] lastPathComponent]);
        }
    }
    return total;
}

- (void)measureDownloadsWithCompletion:(void (^)(long long))completion {
    dispatch_async(_diskQueue, ^{
        NSURL *account = self.accountURL;
        long long total = 0;
        for (NSDictionary *download in account ? [self downloadsUnder:account] : @[]) {
            total += [download[@"size"] longLongValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(total);
        });
    });
}

- (void)removeDownloadsWithCompletion:(dispatch_block_t)completion {
    dispatch_async(_diskQueue, ^{
        NSURL *account = self.accountURL;
        NSUInteger removed = 0;
        for (NSDictionary *download in account ? [self downloadsUnder:account] : @[]) {
            removed += [self evictDownload:download] ? 1 : 0;
        }
        LogInfo(@"Dropbox: removed %lu downloads", (unsigned long)removed);
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

#pragma mark - Ranged reads

- (NSData *)readPlaceholderAtURL:(NSURL *)url
                          offset:(uint64_t)offset
                          length:(uint64_t)length
                           error:(NSError **)error {
    NSString *path = [self downloadArgumentForURL:url];
    if (!path || length == 0) {
        if (error) *error = VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"not in the Dropbox mirror");
        return nil;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *bytes = nil;
    __block NSError *failure = nil;
    dispatch_block_t cancel = [_client readPath:path offset:offset length:length
                                     completion:^(NSData *data, NSError *readError) {
        bytes = data;
        failure = readError;
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kRangedReadTimeout * NSEC_PER_SEC))) != 0) {
        cancel();
        // The cancel completes the read; its answer is the timeout's.
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (error) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
        return nil;
    }
    if (!bytes && error) {
        *error = failure;
    }
    return bytes;
}

#pragma mark - Fetch

- (BOOL)fetchPlaceholderAtURL:(NSURL *)url
                     onCancel:(void (^)(dispatch_block_t))onCancel
                        error:(NSError **)error {
    NSString *path = [self downloadArgumentForURL:url];
    if (!path) {
        if (error) *error = VibeDropboxMakeError(VibeDropboxErrorNotLinked, @"not in the Dropbox mirror");
        return NO;
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    onCancel([self downloadDropboxPath:path toURL:url completion:^(NSError *downloadError) {
        failure = downloadError;
        dispatch_semaphore_signal(done);
    }]);
    // The client always completes: its request timeout bounds a stall.
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (failure) {
        if (error) *error = failure;
        return NO;
    }
    LogInfo(@"Dropbox: downloaded %@ in %.1fs", url.lastPathComponent, CFAbsoluteTimeGetCurrent() - start);
    dispatch_async(_diskQueue, ^{
        long long total = [self enforceDownloadBudgetKeeping:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:VibeDropboxDownloadsDidChangeNotification
                                                              object:self
                                                            userInfo:@{VibeDropboxDownloadsBytesKey: @(total)}];
        });
    });
    return YES;
}

@end
