//
//  GoogleDriveMirror.m
//  Vibe (iOS)
//

#import "GoogleDriveMirror.h"

#include <os/lock.h>
#include <sys/stat.h>

#import "AccountMirrorInternal.h"
#import "GoogleDriveRules.h"
#import "HTTPTransferClientInternal.h"
#import "PlaceholderFiles.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"

// The saved download budget.
static NSString *const kDownloadBudgetKey = @"VibeiOSGoogleDriveDownloadBudget";
// files.list's own maximum page.
static const NSUInteger kListPageSize = 1000;
// Search asks one page and keeps at most this many hits.
static const NSUInteger kSearchPageSize = 100;
static const NSUInteger kSearchResultLimit = 50;
// A search hit's folders are looked up this deep at most. A hit deeper, or
// one whose folders never reach My Drive's root, is left out.
static const NSUInteger kMaximumAncestry = 32;
// My Drive's alias, which every folder query takes.
static NSString *const kRootID = @"root";
// On every mirror directory: {"id": its folder's id, "files": {index key:
// {"id", "version"}}}, "files" once a listing made it, a folder's record
// with no version. On the directory, not the files, because a placeholder's
// attributes are as unreadable as its bytes.
static NSString *const kIndexAttribute = @"com.commonwealthrecordings.vibe.googledrive";

@implementation GoogleDriveMirror {
    os_unfair_lock _foldersLock;
    // What folders were listed or looked up as, by id: {"name", "parent"},
    // for search hits' ancestry. Under the lock, and dropped with the
    // account.
    NSMutableDictionary<NSString *, NSDictionary *> *_folders;
    // My Drive's own id, which a folder's parents name. Under the lock.
    NSString *_rootFolderID;
}

// The store's, typed as the Google Drive client it was made with.
@dynamic client;

+ (BOOL)isConfigured {
#if DEBUG
    return YES;
#else
    NSString *clientID = [NSBundle.mainBundle objectForInfoDictionaryKey:VibeGoogleDriveClientIDInfoKey];
    return [clientID isKindOfClass:NSString.class] && clientID.length > 0;
#endif
}

+ (GoogleDriveMirror *)shared {
    static GoogleDriveMirror *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *clientID = [NSBundle.mainBundle objectForInfoDictionaryKey:VibeGoogleDriveClientIDInfoKey];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        // Fail fast offline: a waiting request holds a materialization lane.
        configuration.waitsForConnectivity = NO;
        GoogleDriveClient *client = [[GoogleDriveClient alloc]
                initWithClientID:[clientID isKindOfClass:NSString.class] ? clientID : @""
                 keychainService:VibeGoogleDriveKeychainService
                   configuration:configuration];
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                              inDomain:NSUserDomainMask
                                                     appropriateForURL:nil
                                                                create:YES
                                                                 error:NULL];
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:kDownloadBudgetKey];
        shared = [[GoogleDriveMirror alloc] initWithClient:client
                                                   rootURL:[support URLByAppendingPathComponent:@"Google Drive"
                                                                                    isDirectory:YES]
                                            downloadBudget:kVibeAccountDownloadBudgets[VibeAccountDownloadBudgetIndex(saved)]];
    });
    return shared;
}

- (instancetype)initWithClient:(GoogleDriveClient *)client
                       rootURL:(NSURL *)rootURL
                downloadBudget:(long long)downloadBudget {
    self = [super initWithClient:client rootURL:rootURL indexAttribute:kIndexAttribute downloadBudget:downloadBudget];
    if (self) {
        _foldersLock = OS_UNFAIR_LOCK_INIT;
        _folders = [NSMutableDictionary dictionary];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(forgetFolders:)
                                                   name:VibeAccountDidChangeNotification
                                                 object:client];
    }
    return self;
}

- (NSString *)serviceName {
    return VibeNotLocalized(@"Google Drive");
}

- (NSString *)glyphName {
    return @"google-drive-glyph";
}

- (NSString *)downloadBudgetKey {
    return kDownloadBudgetKey;
}

- (void)forgetFolders:(NSNotification *)notification {
    os_unfair_lock_lock(&_foldersLock);
    [_folders removeAllObjects];
    _rootFolderID = nil;
    os_unfair_lock_unlock(&_foldersLock);
}

#pragma mark - The index

- (NSString *)folderIDForURL:(NSURL *)url {
    if ([self isAccountRootURL:url]) {
        return kRootID;
    }
    if (![self isMirroredURL:url]) {
        return nil;
    }
    NSString *identifier = [self indexOfDirectory:url][@"id"];
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

// A file's record in its folder's index: {"id", "version"}. Nil outside the
// linked account, and for a name no listing gave.
- (NSDictionary *)recordOfFileAtURL:(NSURL *)url {
    if (![self isMirroredURL:url]) {
        return nil;
    }
    NSDictionary *files = [self indexOfDirectory:url.URLByDeletingLastPathComponent][@"files"];
    NSDictionary *record = [files isKindOfClass:NSDictionary.class] ? files[VibeAccountIndexKey(url.lastPathComponent)] : nil;
    return [record isKindOfClass:NSDictionary.class] && [record[@"id"] isKindOfClass:NSString.class] ? record : nil;
}

// The name each id holds in a directory, whose names are `existing`: its
// index's records with a name on disk, then the folders a search hit made
// here, which only their own index names. Reads only, any thread.
- (NSDictionary<NSString *, NSString *> *)localNamesInDirectory:(NSURL *)directory
                                                         existing:(NSArray<NSString *> *)existing {
    NSDictionary<NSString *, NSString *> *names = VibeAccountNameIndex(existing);
    NSDictionary *records = [self indexOfDirectory:directory][@"files"];
    records = [records isKindOfClass:NSDictionary.class] ? records : @{};
    NSMutableDictionary<NSString *, NSString *> *byID = [NSMutableDictionary dictionary];
    for (NSString *key in records) {
        NSDictionary *record = records[key];
        NSString *identifier = [record isKindOfClass:NSDictionary.class] ? record[@"id"] : nil;
        if ([identifier isKindOfClass:NSString.class] && names[key]) {
            byID[identifier] = names[key];
        }
    }
    for (NSString *name in existing) {
        if ([name hasPrefix:@"."] || records[VibeAccountIndexKey(name)]) {
            continue;
        }
        NSURL *child = [directory URLByAppendingPathComponent:name isDirectory:YES];
        struct stat st;
        NSString *identifier = lstat(child.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)
                ? [self indexOfDirectory:child][@"id"] : nil;
        if ([identifier isKindOfClass:NSString.class] && !byID[identifier]) {
            byID[identifier] = name;
        }
    }
    return byID;
}

// What files/get?alt=media is asked for: the id the folder's listing
// recorded for the name. No spelling is ever sent.
- (id)remoteTargetForURL:(NSURL *)url error:(NSError **)error {
    NSString *identifier = [self recordOfFileAtURL:url][@"id"];
    if (!identifier) {
        if (error) *error = VibeAccountMakeError(VibeAccountErrorNotLinked, @"not in the Google Drive mirror");
        return nil;
    }
    return identifier;
}

#pragma mark - Listing

- (void)listFolderID:(NSString *)folderID
           pageToken:(NSString *)pageToken
             entries:(NSMutableArray<NSDictionary *> *)entries
          completion:(void (^)(NSArray<NSDictionary *> *entries, NSError *error))completion {
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    query[@"q"] = VibeGoogleDriveChildrenQuery(folderID);
    query[@"fields"] = [NSString stringWithFormat:@"nextPageToken,incompleteSearch,files(%@)",
                        VIBE_GOOGLE_DRIVE_FILE_FIELDS];
    query[@"pageSize"] = [NSString stringWithFormat:@"%lu", (unsigned long)kListPageSize];
    query[@"spaces"] = @"drive";
    query[@"pageToken"] = pageToken;
    [self.client getPath:@"files" query:query completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        // Reconciled only whole: a part of a listing would delete the rest.
        if ([result[@"incompleteSearch"] boolValue]) {
            completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"Google Drive answered part of the folder"));
            return;
        }
        NSArray *page = result[@"files"];
        if ([page isKindOfClass:NSArray.class]) {
            for (id entry in page) {
                if ([entry isKindOfClass:NSDictionary.class]) {
                    [entries addObject:entry];
                }
            }
        }
        // A short or empty page is not the end; only a missing token is.
        NSString *next = result[@"nextPageToken"];
        if ([next isKindOfClass:NSString.class] && next.length > 0) {
            [self listFolderID:folderID pageToken:next entries:entries completion:completion];
            return;
        }
        completion(entries, nil);
    }];
}

// A directory no listing made has no id. Its parent is listed first, which
// makes it with its id when Drive holds it, and so up to the nearest
// directory a listing made. So a playlist naming another folder, and a
// restored bookmark, still open.
- (void)refreshDirectoryAtURL:(NSURL *)url completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *account = self.accountURL;
    if (!account || ![self isMirroredURL:url]) {
        completion(nil, VibeAccountMakeError(VibeAccountErrorNotLinked, @"not in the Google Drive mirror"));
        return;
    }
    NSString *folderID = [self folderIDForURL:url];
    if (folderID) {
        [self listFolderID:folderID intoDirectory:url account:account completion:completion];
        return;
    }
    [self refreshDirectoryAtURL:url.URLByDeletingLastPathComponent completion:^(NSURL *parentURL, NSError *error) {
        if (!parentURL) {
            completion(nil, error);
            return;
        }
        NSString *childID = [self folderIDForURL:url];
        if (!childID) {
            completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"not on Google Drive"));
            return;
        }
        [self listFolderID:childID intoDirectory:url account:account completion:completion];
    }];
}

- (void)listFolderID:(NSString *)folderID
       intoDirectory:(NSURL *)directory
             account:(NSURL *)account
          completion:(void (^)(NSURL *, NSError *))completion {
    void (^finish)(NSURL *, NSError *) = ^(NSURL *folderURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(folderURL, error);
        });
    };
    [self listFolderID:folderID pageToken:nil entries:[NSMutableArray array]
            completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        if (error) {
            finish(nil, error);
            return;
        }
        dispatch_async(self.diskQueue, ^{
            // Signed out while listing: write nothing into a pruned tree.
            if (![self.accountURL isEqual:account]) {
                finish(nil, VibeAccountMakeError(VibeAccountErrorNotLinked, @"Google Drive account changed"));
                return;
            }
            [self prepareRoot];
            [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                                    attributes:nil error:NULL];
            [self ensureDirectoryAtURL:directory];
            BOOL discarded = NO;
            NSDictionary<NSURL *, id> *sidecars = [self reconcileDirectory:directory folderID:folderID
                                                             withEntries:entries discarded:&discarded];
            [self finishListingOfDirectory:directory sidecars:sidecars discarded:discarded completion:completion];
        });
    }];
}

// The disk queue. Answers the playlist files to fetch: they are read while
// the folder opens, so they come down with the listing; tracks wait for
// their open. *discarded is set when downloaded bytes went.
- (NSDictionary<NSURL *, id> *)reconcileDirectory:(NSURL *)directory
                                         folderID:(NSString *)folderID
                                      withEntries:(NSArray<NSDictionary *> *)entries
                                        discarded:(BOOL *)discarded {
    NSFileManager *files = NSFileManager.defaultManager;
    NSArray<NSString *> *existing = [files contentsOfDirectoryAtPath:directory.path error:NULL] ?: @[];

    // What each id held here: its slot, and the version recorded for it.
    NSDictionary<NSString *, NSString *> *previous = [self localNamesInDirectory:directory existing:existing];
    NSMutableDictionary<NSString *, NSString *> *versions = [NSMutableDictionary dictionary];
    NSDictionary *records = [self indexOfDirectory:directory][@"files"];
    for (NSDictionary *record in [records isKindOfClass:NSDictionary.class] ? records.allValues : @[]) {
        if ([record isKindOfClass:NSDictionary.class] && [record[@"id"] isKindOfClass:NSString.class]
                && [record[@"version"] isKindOfClass:NSString.class]) {
            versions[record[@"id"]] = record[@"version"];
        }
    }

    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    NSMutableArray<NSDictionary *> *mirrored = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if (VibeGoogleDriveEntryIsMirrored(entry, playable)) {
            [mirrored addObject:entry];
        }
    }
    NSDictionary<NSString *, NSString *> *slots = VibeGoogleDriveSlots(mirrored, previous);

    NSMutableDictionary<NSString *, NSDictionary *> *written = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *kept = [NSMutableSet set];
    NSMutableDictionary<NSURL *, id> *sidecars = [NSMutableDictionary dictionary];
    NSUInteger placeholders = 0;
    for (NSDictionary *entry in mirrored) {
        NSString *identifier = entry[@"id"];
        NSString *local = slots[identifier];
        if (!local || [kept containsObject:local]) {
            continue;   // the same id twice in one listing
        }
        [kept addObject:local];
        NSString *key = VibeAccountIndexKey(local);
        if (VibeGoogleDriveIsFolder(entry)) {
            NSURL *child = [directory URLByAppendingPathComponent:local isDirectory:YES];
            // A slot now naming another folder drops what the old one held.
            NSString *had = [self indexOfDirectory:child][@"id"];
            if ([had isKindOfClass:NSString.class] && ![had isEqualToString:identifier]) {
                [files removeItemAtURL:child error:NULL];
                [self forgetCachedIndexes];
                *discarded = YES;
            }
            [self ensureDirectoryAtURL:child];
            NSString *parent = VibeGoogleDriveParentOf(entry);
            os_unfair_lock_lock(&_foldersLock);
            _folders[identifier] = parent ? @{@"name": entry[@"name"], @"parent": parent} : @{@"name": entry[@"name"]};
            os_unfair_lock_unlock(&_foldersLock);
            NSMutableDictionary *childIndex = [[self indexOfDirectory:child] mutableCopy]
                    ?: [NSMutableDictionary dictionary];
            childIndex[@"id"] = identifier;
            [self writeIndex:childIndex ofDirectory:child];
            written[key] = @{@"id": identifier};
            continue;
        }
        NSURL *url = [directory URLByAppendingPathComponent:local isDirectory:NO];
        int64_t size = VibeGoogleDriveSizeOf(entry);
        NSString *version = VibeGoogleDriveVersionOf(entry);
        NSString *had = [previous[identifier] isEqualToString:local] ? versions[identifier] : nil;
        struct stat st;
        BOOL present = lstat(url.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode);
        // The version decides, never the date: a client may keep modifiedTime
        // across a new upload. A file naming no version is judged by its
        // size alone.
        BOOL current = present && st.st_size == (off_t)size
                && (version ? [had isEqualToString:version] : had == nil);
        NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObject:identifier forKey:@"id"];
        if (current) {
            record[@"version"] = version;
            written[key] = record;
            continue;
        }
        time_t stamp = VibeGoogleDriveStamp(VibeAccountParseTimestamp(entry[@"modifiedTime"]), present,
                                            present ? st.st_mtimespec.tv_sec : 0);
        if ([PlaylistFile isPlaylistExtension:local.pathExtension.lowercaseString]) {
            // The new version is recorded once its bytes land
            // (modificationTimeOfMetadata:forURL:), so a failed fetch is
            // tried again by the next listing.
            record[@"version"] = had;
            written[key] = record;
            sidecars[url] = identifier;
            continue;
        }
        record[@"version"] = version;
        written[key] = record;
        if ([GoogleDriveMirror writePlaceholderAtURL:url size:size modified:stamp]) {
            placeholders++;
            *discarded = *discarded || (present && !VibeFileModeIsRemotePlaceholder(st.st_mode));
        }
        else {
            LogWarn(@"Google Drive: could not write placeholder %@: %s", local, strerror(errno));
        }
    }

    [self writeIndex:@{@"id": folderID, @"files": written} ofDirectory:directory];
    if ([self removeDepartedIn:directory existing:existing kept:kept]) {
        *discarded = YES;
    }
    LogInfo(@"Google Drive: reconciled %@: %lu entries, %lu new placeholders, %lu sidecars",
            directory.lastPathComponent, (unsigned long)entries.count,
            (unsigned long)placeholders, (unsigned long)sidecars.count);
    return sidecars;
}

#pragma mark - Search

- (void)searchQuery:(NSString *)query
         completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    NSDictionary<NSString *, NSString *> *parameters = @{
        @"q": VibeGoogleDriveSearchQuery(query),
        @"fields": [NSString stringWithFormat:@"files(%@)", VIBE_GOOGLE_DRIVE_FILE_FIELDS],
        @"pageSize": [NSString stringWithFormat:@"%lu", (unsigned long)kSearchPageSize],
        @"spaces": @"drive",
        @"corpora": @"user",
    };
    NSSet<NSString *> *playable = PlayableExtensions.lookup;
    void (^finish)(NSArray<NSDictionary *> *, NSError *) = ^(NSArray<NSDictionary *> *entries, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(entries, error);
        });
    };
    [self.client getPath:@"files" query:parameters completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            finish(nil, error);
            return;
        }
        [self placeEntries:VibeGoogleDriveSearchEntries(result, playable, kSearchResultLimit) completion:finish];
    }];
}

// Each hit with its "ancestry": the folders from My Drive's root down to the
// one holding it, as {"id", "name"}. A hit whose folders never reach My
// Drive (shared with the user, never added) is left out. Hits keep their
// order, and hits in one folder share its lookups.
- (void)placeEntries:(NSArray<NSDictionary *> *)hits
          completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    NSMutableDictionary<NSString *, id> *chains = [NSMutableDictionary dictionary];
    NSLock *chainsLock = [[NSLock alloc] init];
    dispatch_group_t group = dispatch_group_create();
    NSMutableSet<NSString *> *parents = [NSMutableSet set];
    for (NSDictionary *hit in hits) {
        NSString *parent = VibeGoogleDriveParentOf(hit);
        if (parent) {
            [parents addObject:parent];
        }
    }
    // The root's id first, once, which every chain ends on.
    dispatch_group_enter(group);
    [self rootFolderIDWithCompletion:^(NSString *rootID) {
        for (NSString *parent in rootID ? parents : [NSSet set]) {
            dispatch_group_enter(group);
            [self ancestryOfFolderID:parent depth:0 completion:^(NSArray<NSDictionary *> *chain) {
                [chainsLock lock];
                chains[parent] = chain ?: NSNull.null;
                [chainsLock unlock];
                dispatch_group_leave(group);
            }];
        }
        dispatch_group_leave(group);
    }];
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *placed = [NSMutableArray arrayWithCapacity:hits.count];
        for (NSDictionary *hit in hits) {
            NSString *parent = VibeGoogleDriveParentOf(hit);
            NSArray *chain = parent ? chains[parent] : nil;
            if (![chain isKindOfClass:NSArray.class]) {
                continue;
            }
            NSMutableDictionary *entry = [hit mutableCopy];
            entry[@"ancestry"] = chain;
            [placed addObject:entry];
        }
        completion(placed, nil);
    });
}

// The folders from My Drive's root down to folderID, the root left out: []
// for the root itself, nil for a folder outside My Drive or past
// kMaximumAncestry. Each folder is looked up once per account.
- (void)ancestryOfFolderID:(NSString *)folderID
                     depth:(NSUInteger)depth
                completion:(void (^)(NSArray<NSDictionary *> *_Nullable chain))completion {
    if (depth > kMaximumAncestry) {
        completion(nil);
        return;
    }
    [self rootFolderIDWithCompletion:^(NSString *rootID) {
        if (!rootID) {
            completion(nil);
            return;
        }
        if ([folderID isEqualToString:rootID] || [folderID isEqualToString:kRootID]) {
            completion(@[]);
            return;
        }
        [self folderOfID:folderID completion:^(NSDictionary *folder) {
            NSString *parent = folder[@"parent"];
            if (!parent) {
                completion(nil);
                return;
            }
            [self ancestryOfFolderID:parent depth:depth + 1 completion:^(NSArray<NSDictionary *> *chain) {
                completion(chain ? [chain arrayByAddingObject:@{@"id": folderID, @"name": folder[@"name"]}] : nil);
            }];
        }];
    }];
}

- (void)rootFolderIDWithCompletion:(void (^)(NSString *_Nullable rootID))completion {
    os_unfair_lock_lock(&_foldersLock);
    NSString *root = _rootFolderID;
    os_unfair_lock_unlock(&_foldersLock);
    if (root) {
        completion(root);
        return;
    }
    [self.client getPath:@"files/root" query:@{@"fields": @"id"} completion:^(NSDictionary *result, NSError *error) {
        NSString *identifier = [result[@"id"] isKindOfClass:NSString.class] ? result[@"id"] : nil;
        if (identifier) {
            os_unfair_lock_lock(&self->_foldersLock);
            self->_rootFolderID = identifier;
            os_unfair_lock_unlock(&self->_foldersLock);
        }
        completion(identifier);
    }];
}

// {"name", "parent"} of a folder, nil when it is none or cannot be read.
- (void)folderOfID:(NSString *)folderID completion:(void (^)(NSDictionary *_Nullable folder))completion {
    os_unfair_lock_lock(&_foldersLock);
    NSDictionary *cached = _folders[folderID];
    os_unfair_lock_unlock(&_foldersLock);
    if (cached) {
        completion(cached);
        return;
    }
    [self.client getPath:[@"files/" stringByAppendingString:folderID]
                   query:@{@"fields": @"id,name,mimeType,parents"}
              completion:^(NSDictionary *result, NSError *error) {
        NSString *name = result[@"name"];
        if (![name isKindOfClass:NSString.class] || !VibeGoogleDriveIsFolder(result)) {
            completion(nil);
            return;
        }
        NSString *parent = VibeGoogleDriveParentOf(result);
        NSDictionary *folder = parent ? @{@"name": name, @"parent": parent} : @{@"name": name};
        os_unfair_lock_lock(&self->_foldersLock);
        self->_folders[folderID] = folder;
        os_unfair_lock_unlock(&self->_foldersLock);
        completion(folder);
    }];
}

// The disk queue. The directory a hit's folders lead to, each made when no
// listing made it, its own index naming its id. A made folder takes its
// name's first copy free; the parent's listing keeps it (reconcileDirectory:).
- (NSURL *)directoryForChain:(NSArray<NSDictionary *> *)chain account:(NSURL *)account {
    [self prepareRoot];
    [self ensureDirectoryAtURL:account];
    NSURL *directory = account;
    for (NSDictionary *link in chain) {
        NSString *identifier = link[@"id"];
        NSArray<NSString *> *existing = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path
                                                                                           error:NULL] ?: @[];
        NSString *name = [self localNamesInDirectory:directory existing:existing][identifier];
        if (!name) {
            NSDictionary<NSString *, NSString *> *names = VibeAccountNameIndex(existing);
            NSString *base = VibeGoogleDriveLocalBaseName(link[@"name"], YES);
            NSUInteger copy = 1;
            while (names[VibeAccountIndexKey(VibeGoogleDriveCopyName(base, copy, YES))]) {
                copy++;
            }
            name = VibeGoogleDriveCopyName(base, copy, YES);
        }
        directory = [directory URLByAppendingPathComponent:name isDirectory:YES];
        [self ensureDirectoryAtURL:directory];
        NSMutableDictionary *index = [[self indexOfDirectory:directory] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (![index[@"id"] isEqual:identifier]) {
            index[@"id"] = identifier;
            [self writeIndex:index ofDirectory:directory];
        }
    }
    return directory;
}

- (void)localURLForEntry:(NSDictionary *)entry
              completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *account = self.accountURL;
    NSArray<NSDictionary *> *ancestry = entry[@"ancestry"];
    NSString *identifier = entry[@"id"];
    NSString *name = entry[@"name"];
    if (!account || ![ancestry isKindOfClass:NSArray.class] || ![identifier isKindOfClass:NSString.class]
            || ![name isKindOfClass:NSString.class]) {
        completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"entry without a place"));
        return;
    }
    BOOL folder = VibeGoogleDriveIsFolder(entry);
    NSArray<NSDictionary *> *chain = folder ? [ancestry arrayByAddingObject:@{@"id": identifier, @"name": name}]
                                            : ancestry;
    void (^fail)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
    };
    dispatch_async(self.diskQueue, ^{
        // Signed out meanwhile: make nothing in a pruned tree.
        if (![self.accountURL isEqual:account]) {
            fail(VibeAccountMakeError(VibeAccountErrorNotLinked, @"Google Drive account changed"));
            return;
        }
        NSURL *directory = [self directoryForChain:chain account:account];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshDirectoryAtURL:directory completion:^(NSURL *folderURL, NSError *error) {
                if (!folderURL || folder) {
                    completion(folderURL, error);
                    return;
                }
                // Read on the disk queue, which writes the folder's names.
                dispatch_async(self.diskQueue, ^{
                    NSArray<NSString *> *existing = [NSFileManager.defaultManager
                            contentsOfDirectoryAtPath:folderURL.path error:NULL] ?: @[];
                    NSString *local = [self localNamesInDirectory:folderURL existing:existing][identifier];
                    NSURL *url = local ? [folderURL URLByAppendingPathComponent:local isDirectory:NO] : nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(url, url ? nil : VibeAccountMakeError(VibeAccountErrorAPI, @"not on Google Drive"));
                    });
                });
            }];
        });
    });
}

- (BOOL)entryIsFolder:(NSDictionary *)entry {
    return VibeGoogleDriveIsFolder(entry);
}

- (NSString *)parentNameOfEntry:(NSDictionary *)entry {
    NSArray *ancestry = entry[@"ancestry"];
    NSDictionary *parent = [ancestry isKindOfClass:NSArray.class] ? ancestry.lastObject : nil;
    NSString *name = [parent isKindOfClass:NSDictionary.class] ? parent[@"name"] : nil;
    return [name isKindOfClass:NSString.class] ? name : nil;
}

- (NSString *)identityOfEntry:(NSDictionary *)entry {
    NSString *identifier = entry[@"id"];
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

- (NSString *)identityOfURL:(NSURL *)url {
    return [self recordOfFileAtURL:url][@"id"];
}

// Each file's place through its folders' indexes, made by nothing: a folder
// no listing made reads as not downloaded. Each directory is read once, since
// hits share folders.
- (void)downloadedIdentitiesOfEntries:(NSArray<NSDictionary *> *)entries
                           completion:(void (^)(NSSet<NSString *> *))completion {
    NSURL *account = self.accountURL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *namesByPath = [NSMutableDictionary dictionary];
        NSDictionary<NSString *, NSString *> *(^namesIn)(NSURL *) = ^(NSURL *directory) {
            NSDictionary<NSString *, NSString *> *names = namesByPath[directory.path];
            if (!names) {
                NSArray<NSString *> *existing = [NSFileManager.defaultManager
                        contentsOfDirectoryAtPath:directory.path error:NULL] ?: @[];
                names = [self localNamesInDirectory:directory existing:existing];
                namesByPath[directory.path] = names;
            }
            return names;
        };
        NSMutableSet<NSString *> *downloaded = [NSMutableSet set];
        for (NSDictionary *entry in entries) {
            NSString *identifier = entry[@"id"];
            NSArray *ancestry = entry[@"ancestry"];
            if (!account || VibeGoogleDriveIsFolder(entry) || ![identifier isKindOfClass:NSString.class]
                    || ![ancestry isKindOfClass:NSArray.class]) {
                continue;
            }
            NSURL *directory = account;
            for (NSDictionary *link in ancestry) {
                NSString *name = [link isKindOfClass:NSDictionary.class] ? namesIn(directory)[link[@"id"]] : nil;
                directory = name ? [directory URLByAppendingPathComponent:name isDirectory:YES] : nil;
                if (!directory) {
                    break;
                }
            }
            NSString *local = directory ? namesIn(directory)[identifier] : nil;
            NSURL *url = local ? [directory URLByAppendingPathComponent:local isDirectory:NO] : nil;
            if (url && [NSFileManager.defaultManager fileExistsAtPath:url.path]
                    && ![PlaceholderFiles isRemotePlaceholderFile:url]) {
                [downloaded addObject:identifier];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(downloaded);
        });
    });
}

#pragma mark - The store's hooks

// Bytes of the version the folder's index records keep the placeholder's
// mtime, so the cached tags and waveform still match. Bytes of another
// version, re-uploaded since the listing, take a new stamp and record that
// version, so the next listing sees them as current and nothing cached for
// the old bytes is served for these.
//
// TRAP: synced onto the disk queue from the client's delivery queue, as
// LinkStore's is. Nothing on the disk queue may wait on the client, or the
// two deadlock.
- (time_t)modificationTimeOfMetadata:(NSDictionary *)metadata forURL:(NSURL *)url {
    time_t held = [super modificationTimeOfMetadata:metadata forURL:url];
    NSString *version = [self.client versionOfMetadata:metadata];
    if (!version) {
        return held;
    }
    __block time_t stamp = held;
    dispatch_sync(self.diskQueue, ^{
        NSURL *directory = url.URLByDeletingLastPathComponent;
        NSMutableDictionary *index = [[self indexOfDirectory:directory] mutableCopy];
        NSMutableDictionary *records = [index[@"files"] isKindOfClass:NSDictionary.class]
                ? [index[@"files"] mutableCopy] : nil;
        NSString *key = VibeAccountIndexKey(url.lastPathComponent);
        NSDictionary *record = records[key];
        // A file the folder's listing no longer names keeps what it has.
        if (![record isKindOfClass:NSDictionary.class] || [record[@"version"] isEqual:version]) {
            return;
        }
        stamp = VibeGoogleDriveStamp(VibeAccountParseTimestamp(metadata[@"modifiedTime"]), held >= 0, held);
        NSMutableDictionary *updated = [record mutableCopy];
        updated[@"version"] = version;
        records[key] = updated;
        index[@"files"] = records;
        [self writeIndex:index ofDirectory:directory];
    });
    return stamp;
}

@end
