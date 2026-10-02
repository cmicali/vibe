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

static os_unfair_lock sRemoteFetchLock = OS_UNFAIR_LOCK_INIT;
static CloudFileRemoteFetch sRemoteFetch;
static CloudFileRemoteRead sRemoteRead;

static CloudFileRemoteFetch VibeRemoteFetch(void) {
    os_unfair_lock_lock(&sRemoteFetchLock);
    CloudFileRemoteFetch fetch = sRemoteFetch;
    os_unfair_lock_unlock(&sRemoteFetchLock);
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
    // What -cancel, callable from any thread, reaches.
    NSFileCoordinator *_coordinator;
    dispatch_block_t _remoteCancel;
#if DEBUG
    // The fake transfer's waiter, signalled by -cancel.
    dispatch_semaphore_t _fakeWait;
#endif
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
    NSFileCoordinator *oldCoordinator = _coordinator;
    _coordinator = nil;
    dispatch_block_t oldRemoteCancel = _remoteCancel;
    _remoteCancel = nil;
#if DEBUG
    dispatch_semaphore_t oldFakeWait = _fakeWait;
    _fakeWait = nil;
#endif
    _token = token;
    os_unfair_lock_unlock(&_lock);

    [oldCoordinator cancel];
    if (oldRemoteCancel) {
        oldRemoteCancel();
    }
#if DEBUG
    if (oldFakeWait) {
        dispatch_semaphore_signal(oldFakeWait);
    }
#endif
    return token;
}

static NSError *VibeMaterializationCancelledError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

+ (void)setRemoteRead:(CloudFileRemoteRead)read {
    os_unfair_lock_lock(&sRemoteFetchLock);
    sRemoteRead = [read copy];
    os_unfair_lock_unlock(&sRemoteFetchLock);
}

+ (CloudFileRemoteRead)remoteRead {
    os_unfair_lock_lock(&sRemoteFetchLock);
    CloudFileRemoteRead read = sRemoteRead;
    os_unfair_lock_unlock(&sRemoteFetchLock);
    return read;
}

+ (void)setRemoteFetch:(CloudFileRemoteFetch)fetch {
    os_unfair_lock_lock(&sRemoteFetchLock);
    sRemoteFetch = [fetch copy];
    os_unfair_lock_unlock(&sRemoteFetchLock);
    [NSURLUtil setRemotePlaceholdersEnabled:fetch != nil];
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
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    if (current) {
        _fakeWait = wait;
    }
    os_unfair_lock_unlock(&_lock);

    if (!current) {
        if (error) {
            *error = VibeMaterializationCancelledError();
        }
        return NO;
    }

    BOOL cancelled = dispatch_semaphore_wait(wait,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;

    os_unfair_lock_lock(&_lock);
    if (_fakeWait == wait) {
        _fakeWait = nil;
    }
    if (_token == token) {
        _token = nil;
    }
    os_unfair_lock_unlock(&_lock);

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
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    if (current) {
        _coordinator = coordinator;
    }
    os_unfair_lock_unlock(&_lock);

    if (!current) {
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

    os_unfair_lock_lock(&_lock);
    if (_coordinator == coordinator) {
        _coordinator = nil;
    }
    if (_token == token) {
        _token = nil;
    }
    os_unfair_lock_unlock(&_lock);

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
        CloudFileMaterializer *strongSelf = weakSelf;
        BOOL live = NO;
        if (strongSelf) {
            os_unfair_lock_lock(&strongSelf->_lock);
            live = (strongSelf->_token == token && !token.isCancelled);
            if (live) {
                strongSelf->_remoteCancel = [cancel copy];
            }
            os_unfair_lock_unlock(&strongSelf->_lock);
        }
        if (!live) {
            cancel();
        }
    }, &fetchError);

    os_unfair_lock_lock(&_lock);
    BOOL cancelled = token.isCancelled;
    if (_token == token) {
        _token = nil;
        _remoteCancel = nil;
    }
    os_unfair_lock_unlock(&_lock);

    if (!fetched && error) {
        *error = cancelled ? VibeMaterializationCancelledError() : fetchError;
    }
    return fetched && !cancelled;
}

- (void)cancel {
    os_unfair_lock_lock(&_lock);
    _token.cancelled = YES;
    _token = nil;
    NSFileCoordinator *coordinator = _coordinator;
    _coordinator = nil;
    dispatch_block_t remoteCancel = _remoteCancel;
    _remoteCancel = nil;
#if DEBUG
    dispatch_semaphore_t fakeWait = _fakeWait;
    _fakeWait = nil;
#endif
    os_unfair_lock_unlock(&_lock);
    [coordinator cancel];
    if (remoteCancel) {
        remoteCancel();
    }
#if DEBUG
    if (fakeWait) {
        dispatch_semaphore_signal(fakeWait);
    }
#endif
}

@end
