//
//  DropboxMirror.m
//  Vibe (iOS)
//

#import "DropboxMirror.h"

#include <sys/stat.h>

#import "AccountMirrorInternal.h"
#import "DropboxLinkRules.h"
#import "DropboxRules.h"
#import "FileSearchRules.h"
#import "FilePaths.h"
#import "PlaceholderFiles.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"

// list_folder's own maximum page.
static const NSInteger kListPageLimit = 2000;
// The saved download budget. Shipped: never renamed.
static NSString *const kDownloadBudgetKey = @"VibeiOSDropboxDownloadBudget";
// Search uses the first page only.
static const NSInteger kSearchResultLimit = 50;
// On every mirror directory: {"path": its Dropbox path, "files": {index key:
// Dropbox id}}. Under linksURL, "link" is the shared link, "path" is below it,
// and each file's entry is its path below the link. On the directory, not the
// files, because a placeholder's attributes are as unreadable as its bytes.
static NSString *const kIndexAttribute = @"com.commonwealthrecordings.vibe.dropbox";

@implementation DropboxMirror

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
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:kDownloadBudgetKey];
        shared = [[DropboxMirror alloc] initWithClient:client
                                               rootURL:[support URLByAppendingPathComponent:@"Dropbox"
                                                                                isDirectory:YES]
                                        downloadBudget:kVibeAccountDownloadBudgets[VibeAccountDownloadBudgetIndex(saved)]];
    });
    return shared;
}

- (instancetype)initWithClient:(DropboxClient *)client
                       rootURL:(NSURL *)rootURL
                downloadBudget:(long long)downloadBudget {
    return [super initWithClient:client rootURL:rootURL indexAttribute:kIndexAttribute downloadBudget:downloadBudget];
}

- (NSString *)serviceName {
    return VibeNotLocalized(@"Dropbox");
}

- (NSString *)glyphName {
    return @"dropbox-glyph";
}

- (NSString *)downloadBudgetKey {
    return kDownloadBudgetKey;
}

#pragma mark - Paths

// The path below the account from the URL's spelling alone, with no index
// read, composed again (see VibeAccountIndexKey); nil outside the account's
// mirror. A folder whose local name gained a collision suffix answers that
// local spelling.
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
    if ([self isSharedLinkURL:url]) {
        NSDictionary *index = [self indexOfDirectory:url.URLByDeletingLastPathComponent];
        NSDictionary *files = index[@"files"];
        NSString *path = [files isKindOfClass:NSDictionary.class] ? files[VibeAccountIndexKey(url.lastPathComponent)] : nil;
        NSString *link = index[@"link"];
        if (![link isKindOfClass:NSString.class] || ![path isKindOfClass:NSString.class]) {
            if (error) *error = VibeAccountMakeError(VibeAccountErrorAPI, @"not listed from its shared link");
            return nil;
        }
        return @{@"url": link, @"path": path};
    }
    NSString *derived = [self derivedDropboxPathForURL:url];
    if (derived.length == 0) {
        if (error) *error = VibeAccountMakeError(VibeAccountErrorNotLinked, @"not in the Dropbox mirror");
        return nil;
    }
    NSDictionary *files = [self indexOfDirectory:url.URLByDeletingLastPathComponent][@"files"];
    NSString *identifier = [files isKindOfClass:NSDictionary.class]
            ? files[VibeAccountIndexKey(url.lastPathComponent)] : nil;
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
                VibeDropboxLocalName(component, VibeAccountNameIndex(existing)) isDirectory:YES];
        [self ensureDirectoryAtURL:directory];
    }
    return directory;
}

// Answers the playlist files to fetch: they are read while the folder opens, so
// they come down with the listing; tracks wait for their open. *discarded is
// set when downloaded bytes went: a changed file back to a placeholder, or a
// departed file or folder deleted. With link, the folder is that shared
// link's. Its entries name no path, and each one's is the folder's and its
// name as Dropbox spells it.
- (NSDictionary<NSURL *, id> *)reconcileDirectory:(NSURL *)directory
                                             path:(NSString *)folderPath
                                             link:(nullable NSString *)link
                                      withEntries:(NSArray<NSDictionary *> *)entries
                                        discarded:(BOOL *)discarded {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSString *> *identifiers = [NSMutableDictionary dictionary];
    NSArray<NSString *> *existing = [files contentsOfDirectoryAtPath:directory.path error:NULL] ?: @[];
    NSDictionary<NSString *, NSString *> *existingNames = VibeAccountNameIndex(existing);
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    NSMutableSet<NSString *> *kept = [NSMutableSet set];
    NSMutableDictionary<NSURL *, id> *sidecars = [NSMutableDictionary dictionary];
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
                index[@"link"] = link;
                [self writeIndex:index ofDirectory:child];
            }
            continue;
        }
        if (kind != VibeDropboxEntryKindFile || !VibeAccountNameIsMirrored(name, playable)) {
            continue;
        }
        NSString *local = VibeDropboxLocalName(name, existingNames);
        [kept addObject:local];
        if ([identifier isKindOfClass:NSString.class]) {
            identifiers[VibeAccountIndexKey(local)] = identifier;
        }
        NSURL *url = [directory URLByAppendingPathComponent:local isDirectory:NO];
        long long size = [entry[@"size"] longLongValue];
        time_t modified = VibeAccountParseTimestamp(entry[@"server_modified"]);
        struct stat st;
        BOOL present = lstat(url.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode);
        if (present && VibeDropboxLocalMatchesEntry(st.st_size, st.st_mtimespec.tv_sec, size, modified)) {
            continue;
        }
        if ([PlaylistFile isPlaylistExtension:name.pathExtension.lowercaseString]) {
            if ([identifier isKindOfClass:NSString.class]) {
                sidecars[url] = link ? @{@"url": link, @"path": identifier} : identifier;
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
    if ([self removeDepartedIn:directory existing:existing kept:kept]) {
        *discarded = YES;
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

// A shared link's directory lists by the link and path its index records,
// into itself.
- (void)refreshDirectoryAtURL:(NSURL *)url completion:(void (^)(NSURL *, NSError *))completion {
    if ([self isSharedLinkURL:url]) {
        NSDictionary *index = [self indexOfDirectory:url];
        NSString *link = index[@"link"];
        NSString *path = index[@"path"];
        if (![link isKindOfClass:NSString.class] || ![path isKindOfClass:NSString.class]) {
            completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"not listed from its shared link"));
            return;
        }
        [self refreshDropboxFolder:path link:link directory:url completion:completion];
        return;
    }
    NSString *path = [self dropboxPathForURL:url];
    if (!path) {
        completion(nil, VibeAccountMakeError(VibeAccountErrorNotLinked, @"not in the Dropbox mirror"));
        return;
    }
    [self refreshDropboxFolder:path link:nil directory:nil completion:completion];
}

// Lists one folder, the account's or, with link, one of that shared link's.
// An account folder's directory is found from its path, a link's is given.
- (void)refreshDropboxFolder:(NSString *)path
                        link:(nullable NSString *)link
                   directory:(nullable NSURL *)given
                  completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *account = self.accountURL;
    if (!account) {
        completion(nil, VibeAccountMakeError(VibeAccountErrorNotLinked, @"no Dropbox account"));
        return;
    }
    void (^finish)(NSURL *, NSError *) = ^(NSURL *directory, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(directory, error);
        });
    };
    [self listFolder:path link:link cursor:nil entries:[NSMutableArray array]
          completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        if (error) {
            finish(nil, error);
            return;
        }
        dispatch_async(self.diskQueue, ^{
            // Signed out while listing: write nothing into a pruned tree.
            if (![self.accountURL isEqual:account]) {
                finish(nil, VibeAccountMakeError(VibeAccountErrorNotLinked, @"Dropbox account changed"));
                return;
            }
            NSURL *directory = given ?: [self directoryForDropboxPath:path account:account];
            if (given) {
                [self ensureDirectoryAtURL:given];
            }
            BOOL discarded = NO;
            NSDictionary<NSURL *, id> *sidecars = [self reconcileDirectory:directory path:path link:link
                                                              withEntries:entries discarded:&discarded];
            [self finishListingOfDirectory:directory sidecars:sidecars discarded:discarded completion:completion];
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
        completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"entry without a path"));
        return;
    }
    if (VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder) {
        [self refreshDropboxFolder:path link:nil directory:nil completion:completion];
        return;
    }
    NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : path.lastPathComponent;
    [self refreshDropboxFolder:VibeDropboxParentPath(path) link:nil directory:nil
                    completion:^(NSURL *folderURL, NSError *error) {
        if (!folderURL) {
            completion(nil, error);
            return;
        }
        // Listed on the disk queue, which writes the folder's names, never main.
        dispatch_async(self.diskQueue, ^{
            NSArray<NSString *> *existing = [NSFileManager.defaultManager
                    contentsOfDirectoryAtPath:folderURL.path error:NULL] ?: @[];
            NSURL *url = [folderURL URLByAppendingPathComponent:VibeDropboxLocalName(name, VibeAccountNameIndex(existing))
                                                    isDirectory:NO];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(url, nil);
            });
        });
    }];
}

- (BOOL)entryIsFolder:(NSDictionary *)entry {
    return VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder;
}

- (NSString *)parentNameOfEntry:(NSDictionary *)entry {
    NSString *display = [entry[@"path_display"] isKindOfClass:NSString.class] ? entry[@"path_display"]
                                                                              : entry[@"path_lower"];
    if (![display isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *parent = VibeDropboxParentPath(display);
    return parent.length > 0 ? parent.lastPathComponent : nil;
}

// A path, lowercased: Dropbox paths are case-insensitive.
- (NSString *)identityOfEntry:(NSDictionary *)entry {
    NSString *lower = entry[@"path_lower"];
    return [lower isKindOfClass:NSString.class] ? lower : nil;
}

- (NSString *)identityOfURL:(NSURL *)url {
    return [self dropboxPathForURL:url].lowercaseString;
}

// A stat per file entry. A path the mirror spells another way reads as not
// downloaded, which errs safe.
- (void)downloadedIdentitiesOfEntries:(NSArray<NSDictionary *> *)entries
                           completion:(void (^)(NSSet<NSString *> *))completion {
    NSURL *account = self.accountURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableSet<NSString *> *downloaded = [NSMutableSet set];
        for (NSDictionary *entry in entries) {
            NSString *display = entry[@"path_display"];
            NSString *lower = entry[@"path_lower"];
            if (!account || ![display isKindOfClass:NSString.class] || ![lower isKindOfClass:NSString.class]
                    || VibeDropboxEntryKindOf(entry) == VibeDropboxEntryKindFolder) {
                continue;
            }
            NSURL *local = [account URLByAppendingPathComponent:display];
            if ([NSFileManager.defaultManager fileExistsAtPath:local.path]
                    && ![PlaceholderFiles isRemotePlaceholderFile:local]) {
                [downloaded addObject:lower];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(downloaded);
        });
    });
}

#pragma mark - Shared folder links

- (BOOL)opensSharedFolderLink:(NSURL *)link {
    return VibeDropboxFolderLinkToken(link) != nil;
}

- (void)lookUpSharedFolderLink:(NSURL *)link
                    completion:(void (^)(NSString *, NSDictionary *, NSError *))completion {
    NSString *address = link.absoluteString;
    [self.client callEndpoint:@"sharing/get_shared_link_metadata" arguments:@{@"url": address}
                   completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }
        if (VibeDropboxEntryKindOf(result) != VibeDropboxEntryKindFolder) {
            completion(nil, nil, VibeAccountMakeError(VibeAccountErrorAPI, @"the shared link is not a folder"));
            return;
        }
        NSString *name = [result[@"name"] isKindOfClass:NSString.class] ? result[@"name"] : nil;
        completion(name, @{@"link": address, @"path": @""}, nil);
    }];
}

#pragma mark - The store's hooks

// Downloaded bytes take the version's mtime, so the next listing sees them
// as current.
- (time_t)modificationTimeOfMetadata:(NSDictionary *)metadata forURL:(NSURL *)url {
    return VibeAccountParseTimestamp(metadata[@"server_modified"]);
}

@end
