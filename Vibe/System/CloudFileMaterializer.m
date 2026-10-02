//
//  CloudFileMaterializer.m
//  Vibe
//

#import "CloudFileMaterializer.h"
#import "NSURLUtil.h"
#if DEBUG
#import "CloudFileMaterializer+Debug.h"
#endif

#include <errno.h>
#include <os/lock.h>

// The remote backend, installed as one pair (setRemoteFetch:read:).
static os_unfair_lock sRemoteLock = OS_UNFAIR_LOCK_INIT;
static CloudFileRemoteFetch sRemoteFetch;
static CloudFileRemoteRead sRemoteRead;

static CloudFileRemoteFetch VibeRemoteFetch(void) {
    os_unfair_lock_lock(&sRemoteLock);
    CloudFileRemoteFetch fetch = sRemoteFetch;
    os_unfair_lock_unlock(&sRemoteLock);
    return fetch;
}

#if DEBUG
// TRAP: written by the debug channel on main, read on download workers. An
// unlocked read of a block global is a retain racing a release.
static os_unfair_lock sFakeLock = OS_UNFAIR_LOCK_INIT;
static NSTimeInterval (^sFakeTransferSeconds)(NSURL *, NSString *);   // nil or 0: the real read
static BOOL (^sFakeAcquireSlot)(NSURL *, NSString *, BOOL (^)(void));
static void (^sFakeReleaseSlot)(NSURL *, NSString *);
static void (^sFakeTransferDidFinish)(NSURL *, NSString *, BOOL);

static void VibeFakeTransferHooks(NSTimeInterval (^*seconds)(NSURL *, NSString *),
                                  BOOL (^*acquireSlot)(NSURL *, NSString *, BOOL (^)(void)),
                                  void (^*releaseSlot)(NSURL *, NSString *),
                                  void (^*didFinish)(NSURL *, NSString *, BOOL)) {
    os_unfair_lock_lock(&sFakeLock);
    *seconds = sFakeTransferSeconds;
    *acquireSlot = sFakeAcquireSlot;
    *releaseSlot = sFakeReleaseSlot;
    *didFinish = sFakeTransferDidFinish;
    os_unfair_lock_unlock(&sFakeLock);
}
#endif

@interface CloudFileMaterializationToken ()
@property (nonatomic, getter=isCancelled) BOOL cancelled;
- (instancetype)initForMaterializer;
@end

@implementation CloudFileMaterializationToken

- (instancetype)initForMaterializer {
    return [super init];
}

@end

@implementation CloudFileMaterializer {
    // Set before dispatch, so a cancel before entry lands.
    CloudFileMaterializationToken *_token;
    // What -cancel, callable from any thread, runs: the coordinator's cancel,
    // the remote backend's, or the fake transfer's signal.
    dispatch_block_t  _cancelTransfer;
    os_unfair_lock    _lock;
}

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

static NSError *VibeMaterializationCancelledError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

+ (void)setRemoteFetch:(CloudFileRemoteFetch)fetch read:(CloudFileRemoteRead)read {
    NSParameterAssert((fetch == nil) == (read == nil));
    os_unfair_lock_lock(&sRemoteLock);
    sRemoteFetch = [fetch copy];
    sRemoteRead = [read copy];
    os_unfair_lock_unlock(&sRemoteLock);
    [NSURLUtil setRemotePlaceholdersEnabled:fetch != nil];
}

+ (CloudFileRemoteRead)remoteRead {
    os_unfair_lock_lock(&sRemoteLock);
    CloudFileRemoteRead read = sRemoteRead;
    os_unfair_lock_unlock(&sRemoteLock);
    return read;
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

#if DEBUG

+ (void)setFakeTransferProvider:(NSTimeInterval (^)(NSURL *url, NSString *role))secondsForURL
                    acquireSlot:(BOOL (^)(NSURL *url, NSString *role, BOOL (^cancelled)(void)))acquireSlot
                    releaseSlot:(void (^)(NSURL *url, NSString *role))releaseSlot
                      didFinish:(void (^)(NSURL *url, NSString *role, BOOL completed))didFinish {
    os_unfair_lock_lock(&sFakeLock);
    sFakeTransferSeconds = [secondsForURL copy];
    sFakeAcquireSlot = [acquireSlot copy];
    sFakeReleaseSlot = [releaseSlot copy];
    sFakeTransferDidFinish = [didFinish copy];
    os_unfair_lock_unlock(&sFakeLock);
}

- (BOOL)tokenIsCancelled:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    BOOL cancelled = (_token != token || token.isCancelled);
    os_unfair_lock_unlock(&_lock);
    return cancelled;
}

// NO the moment -cancel signals. The token is checked as the semaphore is
// installed, covering a cancel before entry as well as during the wait.
- (BOOL)waitOutFakeTransfer:(NSTimeInterval)seconds
                       token:(CloudFileMaterializationToken *)token
                       error:(NSError *__autoreleasing *)error {
    dispatch_semaphore_t wait = dispatch_semaphore_create(0);
    BOOL current = [self installCancelTransfer:^{
        dispatch_semaphore_signal(wait);
    } token:token];

    if (!current) {
        if (error) {
            *error = VibeMaterializationCancelledError();
        }
        return NO;
    }

    BOOL cancelled = dispatch_semaphore_wait(wait,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
    [self finishTransferForToken:token];

    if (cancelled && error) {
        *error = VibeMaterializationCancelledError();
    }
    return !cancelled;
}

#endif

- (BOOL)materializeURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
                 error:(NSError *__autoreleasing *)error {
#if DEBUG
    // Asked ahead of the placeholder probe; the provider answers 0 for a path
    // already transferred, which then takes the real path.
    NSTimeInterval (^fakeSeconds)(NSURL *, NSString *) = nil;
    BOOL (^acquireSlot)(NSURL *, NSString *, BOOL (^)(void)) = nil;
    void (^releaseSlot)(NSURL *, NSString *) = nil;
    void (^didFinish)(NSURL *, NSString *, BOOL) = nil;
    VibeFakeTransferHooks(&fakeSeconds, &acquireSlot, &releaseSlot, &didFinish);
    NSString *role = self.label ?: @"unlabeled";
    NSTimeInterval fake = fakeSeconds ? fakeSeconds(url, role) : 0;
    // Negative: run for the magnitude, then fail, as a provider error does.
    BOOL fakeFails = fake < 0;
    fake = fabs(fake);
    if (fake > 0) {
        // The provider slot first, cancellable while queued, then the
        // transfer. A cancel leaves the file a placeholder, as a real one does.
        BOOL admitted = YES;
        if (acquireSlot) {
            __weak CloudFileMaterializer *weakSelf = self;
            admitted = acquireSlot(url, role, ^BOOL{
                CloudFileMaterializer *strongSelf = weakSelf;
                return !strongSelf || [strongSelf tokenIsCancelled:token];
            });
        }
        BOOL completed = admitted && [self waitOutFakeTransfer:fake token:token error:error];
        if (admitted && releaseSlot) {
            releaseSlot(url, role);
        }
        if (!admitted && error) {
            *error = VibeMaterializationCancelledError();
        }
        if (completed && fakeFails && error) {
            *error = [NSError errorWithDomain:@"com.vibe.fake-cloud"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                             @"Fake provider transfer failed"}];
        }
        if (didFinish) {
            didFinish(url, role, completed && !fakeFails);
        }
        return completed && !fakeFails;
    }
#endif

    // Inside the prepared call, so no caller bypasses it and strands its token.
    if (![NSURLUtil isDatalessFile:url]) {
        BOOL current = [self consumeLocalToken:token];
        if (!current && error) {
            *error = VibeMaterializationCancelledError();
        }
        return current;
    }

    if ([NSURLUtil isRemotePlaceholderFile:url]) {
        return [self fetchRemoteURL:url token:token error:error];
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
                 error:(NSError *__autoreleasing *)error {
    CloudFileRemoteFetch fetch = VibeRemoteFetch();
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    os_unfair_lock_unlock(&_lock);
    if (!current || !fetch) {
        if (error) {
            *error = current ? [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]
                             : VibeMaterializationCancelledError();
        }
        return NO;
    }

    __weak CloudFileMaterializer *weakSelf = self;
    NSError *fetchError = nil;
    BOOL fetched = fetch(url, ^(dispatch_block_t cancel) {
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
