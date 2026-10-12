//
//  CloudFileMaterializer.m
//  Vibe
//

#import "CloudFileMaterializer.h"
#import "FilePaths.h"
#import "PlaceholderFiles.h"
#import "CloudFileMaterializerInternal.h"
#import "CloudFileMaterializer+Debug.h"

#include <errno.h>
#include <os/lock.h>

// The remote backends, one per root (setRemoteRoot:fetch:read:availability:).
// Each is {root, prefix, fetch, read, availability?}, the prefix a comparable
// path ending in "/". Sorted longest prefix first, and the first match is
// then the longest. Replaced whole under the lock, never mutated.
static os_unfair_lock sRemoteLock = OS_UNFAIR_LOCK_INIT;
static NSArray<NSDictionary *> *sRemoteBackends;

static NSArray<NSDictionary *> *VibeRemoteBackends(void) {
    os_unfair_lock_lock(&sRemoteLock);
    NSArray<NSDictionary *> *backends = sRemoteBackends;
    os_unfair_lock_unlock(&sRemoteLock);
    return backends;
}

// The snapshot holds the blocks. A replacement then cannot release one mid-call.
static NSDictionary *VibeRemoteBackendForURL(NSURL *url) {
    NSArray<NSDictionary *> *backends = VibeRemoteBackends();
    if (backends.count == 0) {
        return nil;
    }
    NSString *path = VibeComparablePath(url.path);
    for (NSDictionary *backend in backends) {
        if ([path hasPrefix:backend[@"prefix"]]) {
            return backend;
        }
    }
    return nil;
}

static NSError *VibeNoRemoteBackendError(void) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
}

@implementation CloudFileMaterializationToken

- (instancetype)initForMaterializer {
    return [super init];
}

@end

@implementation CloudFileMaterializer

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (CloudFileMaterializationToken *)prepareMaterialization {
    CloudFileMaterializationToken *token = [[CloudFileMaterializationToken alloc] initForMaterializer];

    os_unfair_lock_lock(&_lock);
    CloudFileMaterializationToken *oldToken = _token;
    oldToken.cancelled = YES;
    dispatch_block_t cancelTransfer = _cancelTransfer;
    _cancelTransfer = nil;
    _token = token;
    os_unfair_lock_unlock(&_lock);

    if (cancelTransfer) {
        cancelTransfer();
    }
    return token;
}

// The transfer's cancel, installed while token is current; NO when a cancel
// already came, and the caller then cancels the transfer itself.
- (BOOL)installCancelTransfer:(dispatch_block_t)cancel token:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    if (current) {
        _cancelTransfer = [cancel copy];
    }
    os_unfair_lock_unlock(&_lock);
    return current;
}

- (void)finishTransferForToken:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    if (_token == token) {
        _token = nil;
        _cancelTransfer = nil;
    }
    os_unfair_lock_unlock(&_lock);
}

NSError *VibeMaterializationCancelledError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

+ (void)setRemoteRoot:(NSURL *)root fetch:(CloudFileRemoteFetch)fetch read:(CloudFileRemoteRead)read
         availability:(CloudFileRemoteAvailability)availability {
    NSParameterAssert((fetch == nil) == (read == nil) && (fetch || !availability) && (root || !fetch));
    NSString *prefix = root ? [VibeComparablePath(root.path) stringByAppendingString:@"/"] : nil;
    NSMutableDictionary *installed = nil;
    if (fetch && root) {
        installed = [@{@"root": root, @"prefix": prefix, @"fetch": [fetch copy], @"read": [read copy]} mutableCopy];
        if (availability) {
            installed[@"availability"] = [availability copy];
        }
    }
    os_unfair_lock_lock(&sRemoteLock);
    NSMutableArray<NSDictionary *> *backends = [NSMutableArray array];
    if (prefix) {
        for (NSDictionary *backend in sRemoteBackends) {
            if (![backend[@"prefix"] isEqualToString:prefix]) {
                [backends addObject:backend];
            }
        }
    }
    if (installed) {
        [backends addObject:installed];
    }
    [backends sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([b[@"prefix"] length]) compare:@([a[@"prefix"] length])];
    }];
    sRemoteBackends = [backends copy];
    // Set under the lock. Two racing installs then cannot leave PlaceholderFiles
    // with the older roots. PlaceholderFiles' lock never takes this one.
    [PlaceholderFiles setRemotePlaceholderRoots:[backends valueForKey:@"root"]];
    os_unfair_lock_unlock(&sRemoteLock);
}

+ (CloudFileAvailability *)availabilityForURL:(NSURL *)url {
    CloudFileRemoteAvailability availability = VibeRemoteBackendForURL(url)[@"availability"];
    return availability ? availability(url) : nil;
}

+ (CloudFileRemoteRead)remoteReadForURL:(NSURL *)url {
    return VibeRemoteBackendForURL(url)[@"read"];
}

// A cancel that wins this lock fails the call; a later one finds no work.
- (BOOL)consumeLocalToken:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    if (current) {
        _token = nil;
    }
    os_unfair_lock_unlock(&_lock);
    return current;
}

- (BOOL)materializeURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
            onReadable:(dispatch_block_t)onReadable
                 error:(NSError *__autoreleasing *)error {
#if DEBUG
    // Asked ahead of the placeholder probe; the provider answers 0 for a path
    // already transferred, which then takes the real path.
    BOOL fakeResult = NO;
    if ([self runFakeTransferForURL:url token:token result:&fakeResult error:error]) {
        return fakeResult;
    }
#endif

    // Inside the prepared call, so no caller bypasses it and strands its token.
    if (![PlaceholderFiles isDatalessFile:url]) {
        BOOL current = [self consumeLocalToken:token];
        if (!current && error) {
            *error = VibeMaterializationCancelledError();
        }
        return current;
    }

    if ([PlaceholderFiles isRemotePlaceholderFile:url]) {
        return [self fetchRemoteURL:url token:token onReadable:onReadable error:error];
    }

    // Fresh per download: cancelling poisons a coordinator for good.
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    if (![self installCancelTransfer:^{ [coordinator cancel]; } token:token]) {
        [coordinator cancel];
        if (error) {
            *error = VibeMaterializationCancelledError();
        }
        return NO;
    }

    __block BOOL materialized = NO;
    NSError *coordinationError = nil;
    // Options 0: a plain coordinated read is what asks for the contents;
    // ImmediatelyAvailableMetadataOnly would ask for the opposite.
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError
                                byAccessor:^(NSURL *readURL) {
        // TRAP: a cancel can land while the accessor runs, and cannot stop it,
        // so it only records that the bytes are here; the caller opens the
        // file after coordination ends.
        materialized = YES;
    }];
    [self finishTransferForToken:token];

    if (!materialized && error) {
        *error = coordinationError ?: VibeMaterializationCancelledError();
    }
    return materialized;
}

- (BOOL)fetchRemoteURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
            onReadable:(dispatch_block_t)onReadable
                 error:(NSError *__autoreleasing *)error {
    CloudFileRemoteFetch fetch = VibeRemoteBackendForURL(url)[@"fetch"];
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    os_unfair_lock_unlock(&_lock);
    if (!current || !fetch) {
        if (error) {
            *error = current ? VibeNoRemoteBackendError() : VibeMaterializationCancelledError();
        }
        return NO;
    }

    __weak CloudFileMaterializer *weakSelf = self;
    NSError *fetchError = nil;
    BOOL fetched = fetch(url, onReadable, ^(dispatch_block_t cancel) {
        if (![weakSelf installCancelTransfer:cancel token:token]) {
            cancel();
        }
    }, &fetchError);

    os_unfair_lock_lock(&_lock);
    BOOL cancelled = token.isCancelled;
    os_unfair_lock_unlock(&_lock);
    [self finishTransferForToken:token];

    if (!fetched && error) {
        *error = cancelled ? VibeMaterializationCancelledError() : fetchError;
    }
    return fetched && !cancelled;
}

- (void)cancel {
    os_unfair_lock_lock(&_lock);
    _token.cancelled = YES;
    _token = nil;
    dispatch_block_t cancelTransfer = _cancelTransfer;
    _cancelTransfer = nil;
    os_unfair_lock_unlock(&_lock);
    if (cancelTransfer) {
        cancelTransfer();
    }
}

@end
