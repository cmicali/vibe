//
//  CloudFileMaterializer.m
//  Vibe
//

#import "CloudFileMaterializer.h"
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

@implementation CloudFileMaterializer {
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
// under the same lock the coordinator uses.
- (BOOL)waitOutFakeTransfer:(NSTimeInterval)seconds error:(NSError *__autoreleasing *)error {
    dispatch_semaphore_t wait = dispatch_semaphore_create(0);
    os_unfair_lock_lock(&_lock);
    _fakeWait = wait;
    os_unfair_lock_unlock(&_lock);

    BOOL cancelled = dispatch_semaphore_wait(wait,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;

    os_unfair_lock_lock(&_lock);
    if (_fakeWait == wait) {
        _fakeWait = nil;
    }
    os_unfair_lock_unlock(&_lock);

    if (cancelled && error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    }
    return !cancelled;
}

#endif

- (BOOL)materializeURL:(NSURL *)url error:(NSError *__autoreleasing *)error {
#if DEBUG
    NSTimeInterval (^fakeSeconds)(NSURL *) = nil;
    void (^didFinish)(NSURL *, BOOL) = nil;
    VibeFakeTransferHooks(&fakeSeconds, &didFinish);
    NSTimeInterval fake = fakeSeconds ? fakeSeconds(url) : 0;
    if (fake > 0) {
        // Cancelled leaves the file a placeholder, exactly as a real one does.
        BOOL completed = [self waitOutFakeTransfer:fake error:error];
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
    _coordinator = coordinator;
    os_unfair_lock_unlock(&_lock);

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
    os_unfair_lock_unlock(&_lock);

    if (!materialized && error) {
        *error = coordinationError;
    }
    return materialized;
}

- (void)cancel {
    os_unfair_lock_lock(&_lock);
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
