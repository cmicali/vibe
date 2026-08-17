//
//  CloudFileMaterializer.m
//  Vibe
//

#import "CloudFileMaterializer.h"
#import "NSURLUtil.h"
#if DEBUG
#import "CloudFileMaterializer+Debug.h"   // the fake transfer, declared out of the shipping header
#endif

#include <os/lock.h>

#if DEBUG
// TRAP: these are written by the debug channel on main and read on whichever
// worker is about to download, so they need the lock even though only a test
// harness installs them — an unsynchronized read of a block global is a retain
// racing a release, not merely something TSan dislikes. Found by TSan on the
// first cloud-profile run, in the harness rather than the app.
static os_unfair_lock sFakeLock = OS_UNFAIR_LOCK_INIT;
static NSTimeInterval (^sFakeTransferSeconds)(NSURL *, NSString *);   // nil, or 0 for a URL = the real read
static BOOL (^sFakeAcquireSlot)(NSURL *, NSString *, BOOL (^)(void));
static void (^sFakeReleaseSlot)(NSURL *);
static void (^sFakeTransferDidFinish)(NSURL *, NSString *, BOOL);

static void VibeFakeTransferHooks(NSTimeInterval (^*seconds)(NSURL *, NSString *),
                                  BOOL (^*acquireSlot)(NSURL *, NSString *, BOOL (^)(void)),
                                  void (^*releaseSlot)(NSURL *),
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
    // Installed by -prepareMaterialization before the caller dispatches its
    // worker. Keeping the pending call in the same slot as the live
    // coordinator closes the cancel-before-entry window without turning
    // cancellation into a permanent latch.
    CloudFileMaterializationToken *_token;
    // The coordinator of the download in flight, which is the only thing
    // -cancel has to reach. Held under a lock because cancel is documented as
    // callable from any thread and is the whole point of the class.
    NSFileCoordinator *_coordinator;
#if DEBUG
    // The fake transfer's waiter, signalled by -cancel. Same slot discipline as
    // the coordinator above, so cancel reaches whichever of the two is live.
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
#if DEBUG
    dispatch_semaphore_t oldFakeWait = _fakeWait;
    _fakeWait = nil;
#endif
    _token = token;
    os_unfair_lock_unlock(&_lock);

    [oldCoordinator cancel];
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

// Atomically consumes a still-current token for a URL which was already local.
// A cancel that wins this lock makes the call fail; one that lands afterwards
// correctly sees no work left to cancel.
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
                    releaseSlot:(void (^)(NSURL *url))releaseSlot
                      didFinish:(void (^)(NSURL *url, NSString *role, BOOL completed))didFinish {
    os_unfair_lock_lock(&sFakeLock);
    sFakeTransferSeconds = [secondsForURL copy];
    sFakeAcquireSlot = [acquireSlot copy];
    sFakeReleaseSlot = [releaseSlot copy];
    sFakeTransferDidFinish = [didFinish copy];
    os_unfair_lock_unlock(&sFakeLock);
}

// Reads under the same lock every other token transition takes, so the slot
// poll's cancellation check cannot race a -cancel mid-write.
- (BOOL)tokenIsCancelled:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    BOOL cancelled = (_token != token || token.isCancelled);
    os_unfair_lock_unlock(&_lock);
    return cancelled;
}

// Waits out the fake transfer, or returns NO the moment -cancel signals. The
// semaphore is the cancel path's only reach into this, so it goes in the slot
// under the same lock the coordinator uses. The already-prepared token is
// checked while installing it, which covers cancellation before this method
// was entered as well as cancellation during the wait.
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
    // The fake is asked AHEAD of the placeholder probe, so an
    // unflagged-placeholder mode — where the probe disowns a file whose
    // transfer has not run — still costs the transfer. The provider contract
    // carries the old ordering's job: it answers 0 for a path whose transfer
    // already completed, so a replayed file is not re-downloaded.
    NSTimeInterval (^fakeSeconds)(NSURL *, NSString *) = nil;
    BOOL (^acquireSlot)(NSURL *, NSString *, BOOL (^)(void)) = nil;
    void (^releaseSlot)(NSURL *) = nil;
    void (^didFinish)(NSURL *, NSString *, BOOL) = nil;
    VibeFakeTransferHooks(&fakeSeconds, &acquireSlot, &releaseSlot, &didFinish);
    NSString *role = self.label ?: @"unlabeled";
    NSTimeInterval fake = fakeSeconds ? fakeSeconds(url, role) : 0;
    if (fake > 0) {
        // The shared provider slot first, cancellable while queued; then the
        // transfer itself. Cancelled leaves the file a placeholder, exactly as
        // a real one does.
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
            releaseSlot(url);
        }
        if (!admitted && error) {
            *error = VibeMaterializationCancelledError();
        }
        if (didFinish) {
            didFinish(url, role, completed);
        }
        return completed;
    }
#endif

    // Keep the placeholder probe inside the prepared call. Besides making local
    // files cheap, this means callers never have to bypass materialization and
    // accidentally leave a prepared token live forever.
    if (![NSURLUtil isDatalessFile:url]) {
        BOOL current = [self consumeLocalToken:token];
        if (!current && error) {
            *error = VibeMaterializationCancelledError();
        }
        return current;
    }

    // A fresh coordinator per download, deliberately. Cancellation poisons a
    // coordinator for good — every later -coordinate... on it returns
    // NSUserCancelledError without invoking the block — so reusing one would
    // turn the first abort into a permanent refusal to download anything.
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
    // options 0 is the whole mechanism: a plain coordinated read is what asks
    // the provider for the contents. (ImmediatelyAvailableMetadataOnly is the
    // opposite request and would defeat the purpose — it also answers only for
    // the file system's own metadata, never the tags inside the audio.)
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError
                                byAccessor:^(NSURL *readURL) {
        // TRAP: cancellation is racy by contract — the accessor can already be
        // running when cancel lands — so reaching here is what "the bytes are
        // here" means, and nothing expensive belongs inside it. The caller
        // opens the now-local file itself, after coordination has ended.
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

- (void)cancel {
    os_unfair_lock_lock(&_lock);
    _token.cancelled = YES;
    _token = nil;
    NSFileCoordinator *coordinator = _coordinator;
    _coordinator = nil;
#if DEBUG
    dispatch_semaphore_t fakeWait = _fakeWait;
    _fakeWait = nil;
#endif
    os_unfair_lock_unlock(&_lock);
    [coordinator cancel];
#if DEBUG
    if (fakeWait) {
        dispatch_semaphore_signal(fakeWait);
    }
#endif
}

@end
