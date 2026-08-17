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
static NSTimeInterval (^sFakeTransferSeconds)(NSURL *);   // nil, or 0 for a URL = the real read
static void (^sFakeTransferDidFinish)(NSURL *, BOOL);

static void VibeFakeTransferHooks(NSTimeInterval (^*seconds)(NSURL *),
                                  void (^*didFinish)(NSURL *, BOOL)) {
    os_unfair_lock_lock(&sFakeLock);
    *seconds = sFakeTransferSeconds;
    *didFinish = sFakeTransferDidFinish;
    os_unfair_lock_unlock(&sFakeLock);
}
#endif

@interface CloudFileMaterializationClaim ()
@property (nonatomic, getter=isCancelled) BOOL cancelled;
- (instancetype)initForMaterializer;
@end

@implementation CloudFileMaterializationClaim

- (instancetype)initForMaterializer {
    return [super init];
}

@end

@implementation CloudFileMaterializer {
    // Installed by -prepareMaterialization before the caller dispatches its
    // worker. Keeping the pending call in the same slot as the live
    // coordinator closes the cancel-before-entry window without turning
    // cancellation into a permanent latch.
    CloudFileMaterializationClaim *_claim;
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

- (CloudFileMaterializationClaim *)prepareMaterialization {
    CloudFileMaterializationClaim *claim = [[CloudFileMaterializationClaim alloc] initForMaterializer];

    os_unfair_lock_lock(&_lock);
    CloudFileMaterializationClaim *oldClaim = _claim;
    oldClaim.cancelled = YES;
    NSFileCoordinator *oldCoordinator = _coordinator;
    _coordinator = nil;
#if DEBUG
    dispatch_semaphore_t oldFakeWait = _fakeWait;
    _fakeWait = nil;
#endif
    _claim = claim;
    os_unfair_lock_unlock(&_lock);

    [oldCoordinator cancel];
#if DEBUG
    if (oldFakeWait) {
        dispatch_semaphore_signal(oldFakeWait);
    }
#endif
    return claim;
}

static NSError *VibeMaterializationCancelledError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

// Atomically consumes a still-current claim for a URL which was already local.
// A cancel that wins this lock makes the call fail; one that lands afterwards
// correctly sees no work left to cancel.
- (BOOL)consumeLocalClaim:(CloudFileMaterializationClaim *)claim {
    os_unfair_lock_lock(&_lock);
    BOOL current = (_claim == claim && !claim.isCancelled);
    if (current) {
        _claim = nil;
    }
    os_unfair_lock_unlock(&_lock);
    return current;
}

#if DEBUG

+ (void)setFakeTransferProvider:(NSTimeInterval (^)(NSURL *url))secondsForURL
                      didFinish:(void (^)(NSURL *url, BOOL completed))didFinish {
    os_unfair_lock_lock(&sFakeLock);
    sFakeTransferSeconds = [secondsForURL copy];
    sFakeTransferDidFinish = [didFinish copy];
    os_unfair_lock_unlock(&sFakeLock);
}

// Waits out the fake transfer, or returns NO the moment -cancel signals. The
// semaphore is the cancel path's only reach into this, so it goes in the slot
// under the same lock the coordinator uses. The already-prepared claim is
// checked while installing it, which covers cancellation before this method
// was entered as well as cancellation during the wait.
- (BOOL)waitOutFakeTransfer:(NSTimeInterval)seconds
                       claim:(CloudFileMaterializationClaim *)claim
                       error:(NSError *__autoreleasing *)error {
    dispatch_semaphore_t wait = dispatch_semaphore_create(0);
    os_unfair_lock_lock(&_lock);
    BOOL current = (_claim == claim && !claim.isCancelled);
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
    if (_claim == claim) {
        _claim = nil;
    }
    os_unfair_lock_unlock(&_lock);

    if (cancelled && error) {
        *error = VibeMaterializationCancelledError();
    }
    return !cancelled;
}

#endif

- (BOOL)materializeURL:(NSURL *)url
                 claim:(CloudFileMaterializationClaim *)claim
                 error:(NSError *__autoreleasing *)error {
    // Keep the placeholder probe inside the claimed call. Besides making local
    // files cheap, this means callers never have to bypass materialization and
    // accidentally leave a prepared claim live forever.
    //
    // TRAP: it must stay AHEAD of the fake transfer below, not behind it. The
    // fake's seconds-for-URL answer is a property of the path alone, while the
    // probe is what a completed transfer switches off — so asking the fake
    // first would re-run a file's whole download every time it is replayed,
    // and no stress run would ever settle.
    if (![NSURLUtil isDatalessFile:url]) {
        BOOL current = [self consumeLocalClaim:claim];
        if (!current && error) {
            *error = VibeMaterializationCancelledError();
        }
        return current;
    }

#if DEBUG
    NSTimeInterval (^fakeSeconds)(NSURL *) = nil;
    void (^didFinish)(NSURL *, BOOL) = nil;
    VibeFakeTransferHooks(&fakeSeconds, &didFinish);
    NSTimeInterval fake = fakeSeconds ? fakeSeconds(url) : 0;
    if (fake > 0) {
        // Cancelled leaves the file a placeholder, exactly as a real one does.
        BOOL completed = [self waitOutFakeTransfer:fake claim:claim error:error];
        if (didFinish) {
            didFinish(url, completed);
        }
        return completed;
    }
#endif

    // A fresh coordinator per download, deliberately. Cancellation poisons a
    // coordinator for good — every later -coordinate... on it returns
    // NSUserCancelledError without invoking the block — so reusing one would
    // turn the first abort into a permanent refusal to download anything.
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    os_unfair_lock_lock(&_lock);
    BOOL current = (_claim == claim && !claim.isCancelled);
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
    if (_claim == claim) {
        _claim = nil;
    }
    os_unfair_lock_unlock(&_lock);

    if (!materialized && error) {
        *error = coordinationError ?: VibeMaterializationCancelledError();
    }
    return materialized;
}

- (void)cancel {
    os_unfair_lock_lock(&_lock);
    _claim.cancelled = YES;
    _claim = nil;
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
