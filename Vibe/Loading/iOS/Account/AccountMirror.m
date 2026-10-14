//
//  AccountMirror.m
//  Vibe (iOS)
//

#import "AccountMirrorInternal.h"

#include <sys/stat.h>

#import "DropboxMirror.h"
#import "FilePaths.h"
#import "FileSearchRules.h"
#import "GoogleDriveMirror.h"
#import "LinkRules.h"
#import "PlaceholderFiles.h"
#import "PlaylistFile.h"

NSNotificationName const VibeAccountDownloadsDidChangeNotification = @"VibeAccountDownloadsDidChangeNotification";
NSString *const VibeAccountDownloadsBytesKey = @"bytes";

// A part file this old belongs to a download that died with the process.
static const NSTimeInterval kStalePartSeconds = 24 * 60 * 60;

@implementation AccountMirror {
    // The disk queue's: the playlist files being fetched, by local path,
    // each with the listings waiting on it. The claim on a sheet's download.
    NSMutableDictionary<NSString *, NSMutableArray<dispatch_block_t> *> *_sidecarWaiters;
}

// The store's, typed as the account it was made with.
@dynamic client;

+ (NSArray<AccountMirror *> *)mirrors {
    static NSArray<AccountMirror *> *mirrors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<AccountMirror *> *all = [NSMutableArray arrayWithObject:DropboxMirror.shared];
        if (GoogleDriveMirror.isConfigured) {
            [all addObject:GoogleDriveMirror.shared];
        }
        mirrors = [all copy];
    });
    return mirrors;
}

+ (AccountMirror *)mirrorOfURL:(NSURL *)url {
    for (AccountMirror *mirror in self.mirrors) {
        if ([mirror isMirroredURL:url]) {
            return mirror;
        }
    }
    return nil;
}

- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL
                indexAttribute:(NSString *)indexAttribute
                downloadBudget:(long long)downloadBudget {
    NSAssert([client isKindOfClass:OAuthAccountClient.class], @"a mirror's client is an account");
    self = [super initWithClient:client rootURL:rootURL indexAttribute:indexAttribute downloadBudget:downloadBudget];
    if (self) {
        _sidecarWaiters = [NSMutableDictionary dictionary];
        // Not pruned here: before first unlock the Keychain reads as no
        // account, and that must not cost the user their downloads.
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(pruneOtherAccounts:)
                                                   name:VibeAccountDidChangeNotification
                                                 object:client];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - The account

// "/", the one character a file name cannot keep, becomes "_".
- (NSURL *)accountURL {
    NSString *accountID = self.client.accountID;
    if (accountID.length == 0) {
        return nil;
    }
    return [self.rootURL URLByAppendingPathComponent:[accountID stringByReplacingOccurrencesOfString:@"/"
                                                                                           withString:@"_"]
                                         isDirectory:YES];
}

// Beside the account's directory, not in it: a listing of the account's root
// deletes every name the service does not hold there.
- (NSURL *)linksURL {
    NSString *account = self.accountURL.lastPathComponent;
    return account ? [self.rootURL URLByAppendingPathComponent:[account stringByAppendingString:@" links"]
                                                   isDirectory:YES]
                   : nil;
}

- (BOOL)isMirroredURL:(NSURL *)url {
    NSURL *account = self.accountURL;
    if (!account || !url.isFileURL) {
        return NO;
    }
    return VibeSearchRootCoversPath(VibeComparablePath(account.path), VibeComparablePath(url.path))
        || [self isSharedLinkURL:url];
}

- (BOOL)isSharedLinkURL:(NSURL *)url {
    NSURL *links = self.linksURL;
    return links && url.isFileURL && VibeSearchRootCoversPath(VibeComparablePath(links.path), VibeComparablePath(url.path));
}

- (BOOL)isAccountRootURL:(NSURL *)url {
    NSURL *account = self.accountURL;
    return account && url.isFileURL
            && [VibeComparablePath(account.path) isEqualToString:VibeComparablePath(url.path)];
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

// A folder its parent's listing made carries only what names it; one listed
// itself carries its files.
- (BOOL)hasListedDirectory:(NSURL *)url {
    return [self indexOfDirectory:url][@"files"] != nil;
}

#pragma mark - Listing (the disk queue)

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

- (BOOL)removeDepartedIn:(NSURL *)directory
                existing:(NSArray<NSString *> *)existing
                    kept:(NSSet<NSString *> *)kept {
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL discarded = NO;
    time_t staleBefore = time(NULL) - (time_t)kStalePartSeconds;
    for (NSString *name in existing) {
        NSURL *url = [directory URLByAppendingPathComponent:name];
        if ([name hasPrefix:@"."]) {
            // TRAP: by ctime, not mtime. The install dates a live part to its
            // version's remote mtime just before the rename, and an mtime
            // sweep landing between the two would delete a finished download.
            struct stat st;
            if ([name hasSuffix:VibeRemotePlaceholderPartSuffix] && lstat(url.fileSystemRepresentation, &st) == 0
                    && st.st_ctimespec.tv_sec < staleBefore) {
                [files removeItemAtURL:url error:NULL];
            }
            continue;
        }
        if ([kept containsObject:name]) {
            continue;
        }
        // TRAP: a departed directory takes its cached index with it, and its
        // descendants'. Kept, a folder that comes back on the service is
        // made empty here, its unchanged index skips the xattr write, and it
        // reads as listed: Play on its row opened nothing. The cache cannot
        // name a subtree, so it goes whole — for a departed file too, which
        // is rare enough not to tell apart — and refills from the xattrs.
        struct stat st;
        if (lstat(url.fileSystemRepresentation, &st) == 0
                && (S_ISDIR(st.st_mode) || (S_ISREG(st.st_mode) && !VibeFileModeIsRemotePlaceholder(st.st_mode)
                                            && ![PlaylistFile isPlaylistExtension:name.pathExtension.lowercaseString]))) {
            discarded = YES;   // a folder may hold downloads; not walked to find out
        }
        [files removeItemAtURL:url error:NULL];
        [self forgetCachedIndexes];
    }
    return discarded;
}

- (void)finishListingOfDirectory:(NSURL *)directory
                        sidecars:(NSDictionary<NSURL *, id> *)sidecars
                       discarded:(BOOL)discarded
                      completion:(void (^)(NSURL *, NSError *))completion {
    if (discarded) {
        // Rare — a file changed or left the service after it was downloaded
        // — so the walk the total needs is paid here.
        NSURL *account = self.budgetRootURL;
        long long total = 0;
        for (NSDictionary *download in account ? [self downloadsUnder:account] : @[]) {
            total += [download[@"size"] longLongValue];
        }
        [self downloadsDidChangeWithTotal:total];
    }
    // Side by side and off the disk queue, which other listings need.
    // TRAP: one download per sheet. Two listings of one folder both find it
    // missing, and two downloads share its part file: the second's response
    // unlinks the first's, and the first to finish renames the other's
    // half-written bytes into place, where the folder's open reads them. A
    // listing that finds the sheet claimed waits on that download instead.
    dispatch_group_t fetched = dispatch_group_create();
    for (NSURL *url in sidecars) {
        dispatch_group_enter(fetched);
        dispatch_block_t leave = ^{
            dispatch_group_leave(fetched);
        };
        NSString *key = url.path;
        NSMutableArray<dispatch_block_t> *waiters = _sidecarWaiters[key];
        if (waiters) {
            [waiters addObject:leave];
            continue;
        }
        _sidecarWaiters[key] = [NSMutableArray arrayWithObject:leave];
        [self downloadTarget:sidecars[url] installingAtURL:url progress:nil
                  completion:^(NSError *fetchError) {
            if (fetchError) {
                LogWarn(@"%@: could not fetch %@: %@", self.logName, url.lastPathComponent,
                        fetchError.localizedDescription);
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
}

#pragma mark - Shared folder links

- (BOOL)opensSharedFolderLink:(NSURL *)link {
    return NO;
}

- (void)openSharedFolderLink:(NSURL *)link completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *account = self.accountURL;
    NSURL *links = self.linksURL;
    if (!account || !links || ![self opensSharedFolderLink:link]) {
        completion(nil, VibeAccountMakeError(VibeAccountErrorNotLinked, @"no account for the link"));
        return;
    }
    void (^finish)(NSURL *, NSError *) = ^(NSURL *folderURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(folderURL, error);
        });
    };
    [self lookUpSharedFolderLink:link completion:^(NSString *name, NSDictionary *index, NSError *error) {
        if (!index) {
            finish(nil, error);
            return;
        }
        NSString *folderName = name.length > 0 && ![name containsString:@"/"] && ![name hasPrefix:@"."]
                ? name : self.serviceName;
        dispatch_async(self.diskQueue, ^{
            // Signed out, or another account, since the lookup: its links'
            // tree is pruned, or is the wrong one.
            if (![self.accountURL isEqual:account]) {
                finish(nil, VibeAccountMakeError(VibeAccountErrorNotLinked, @"the account changed"));
                return;
            }
            // A name the folder had before goes with what it held.
            NSURL *holder = [links URLByAppendingPathComponent:VibeLinkDirectoryName(link) isDirectory:YES];
            [self prepareRoot];
            [self ensureDirectoryAtURL:links];
            [self ensureDirectoryAtURL:holder];
            NSFileManager *files = NSFileManager.defaultManager;
            for (NSString *entry in [files contentsOfDirectoryAtPath:holder.path error:NULL]) {
                if (![entry isEqualToString:folderName]) {
                    [files removeItemAtURL:[holder URLByAppendingPathComponent:entry] error:NULL];
                    [self forgetCachedIndexes];
                }
            }
            NSURL *base = [holder URLByAppendingPathComponent:folderName isDirectory:YES];
            [self ensureDirectoryAtURL:base];
            NSMutableDictionary *top = [[self indexOfDirectory:base] mutableCopy] ?: [NSMutableDictionary dictionary];
            [top addEntriesFromDictionary:index];
            [self writeIndex:top ofDirectory:base];
            [self refreshSharedLinkDirectories:[NSMutableArray arrayWithObject:base] account:account
                                    completion:^(NSError *listError) {
                LogInfo(@"%@: %@ a shared folder through the account", self.logName,
                        listError ? @"could not list" : @"listed");
                finish(listError ? nil : base, listError);
            }];
        });
    }];
}

// Each directory in turn, and the directories each listing leaves below it,
// until none is left: a shared folder whole, which no later browse lists.
// Any failure ends it.
- (void)refreshSharedLinkDirectories:(NSMutableArray<NSURL *> *)directories
                             account:(NSURL *)account
                          completion:(void (^)(NSError *_Nullable error))completion {
    if (directories.count == 0) {
        completion(nil);
        return;
    }
    NSURL *directory = directories.firstObject;
    [directories removeObjectAtIndex:0];
    [self refreshDirectoryAtURL:directory completion:^(NSURL *folderURL, NSError *error) {
        if (!folderURL || ![self.accountURL isEqual:account]) {
            completion(error ?: VibeAccountMakeError(VibeAccountErrorNotLinked, @"the account changed"));
            return;
        }
        dispatch_async(self.diskQueue, ^{
            NSArray<NSURL *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folderURL
                                                                    includingPropertiesForKeys:nil
                                                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                         error:NULL];
            for (NSURL *entry in entries) {
                struct stat st;
                if (lstat(entry.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode)) {
                    [directories addObject:entry];
                }
            }
            [self refreshSharedLinkDirectories:directories account:account completion:completion];
        });
    }];
}

- (void)lookUpSharedFolderLink:(NSURL *)link completion:(void (^)(NSString *, NSDictionary *, NSError *))completion {
    completion(nil, nil, VibeAccountMakeError(VibeAccountErrorAPI, @"no shared links"));
}

#pragma mark - The store's hooks

// The account's tree and its links' tree, which are all the root holds while
// linked: an account change prunes every other directory.
- (NSURL *)budgetRootURL {
    return self.accountURL ? self.rootURL : nil;
}

- (NSString *)logName {
    return self.serviceName;
}

// Any thread; posted on main. Every reader of a row's downloaded state hears
// it — Search's marks, a mirrored folder on screen, the size in Settings —
// whichever way the bytes came or went.
- (void)downloadsDidChangeWithTotal:(long long)total {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:VibeAccountDownloadsDidChangeNotification
                                                          object:self
                                                        userInfo:@{VibeAccountDownloadsBytesKey: @(total)}];
    });
}

#pragma mark - Each service's

- (NSString *)serviceName {
    NSAssert(NO, @"every mirror names its service");
    return @"";
}

- (NSString *)glyphName {
    NSAssert(NO, @"every mirror names its glyph");
    return @"";
}

- (NSString *)downloadBudgetKey {
    NSAssert(NO, @"every mirror names its budget's key");
    return @"";
}

- (void)refreshDirectoryAtURL:(NSURL *)url completion:(void (^)(NSURL *, NSError *))completion {
    completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"no listing"));
}

- (void)searchQuery:(NSString *)query completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"no search"));
}

- (void)localURLForEntry:(NSDictionary *)entry completion:(void (^)(NSURL *, NSError *))completion {
    completion(nil, VibeAccountMakeError(VibeAccountErrorAPI, @"no search"));
}

- (NSString *)nameOfEntry:(NSDictionary *)entry {
    NSString *name = entry[@"name"];
    return [name isKindOfClass:NSString.class] ? name : @"";
}

- (BOOL)entryIsFolder:(NSDictionary *)entry {
    return NO;
}

- (NSString *)parentNameOfEntry:(NSDictionary *)entry {
    return nil;
}

- (NSString *)identityOfEntry:(NSDictionary *)entry {
    return nil;
}

- (NSString *)identityOfURL:(NSURL *)url {
    return nil;
}

- (void)downloadedIdentitiesOfEntries:(NSArray<NSDictionary *> *)entries
                           completion:(void (^)(NSSet<NSString *> *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion([NSSet set]);
    });
}

@end
