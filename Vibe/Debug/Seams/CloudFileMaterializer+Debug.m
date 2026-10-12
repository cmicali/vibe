//
//  CloudFileMaterializer+Debug.m
//  Vibe
//

#import "CloudFileMaterializer+Debug.h"

#if DEBUG

#import "CloudFileMaterializerInternal.h"

#include <os/lock.h>

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

@implementation CloudFileMaterializer (Debug)

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

- (BOOL)runFakeTransferForURL:(NSURL *)url
                        token:(CloudFileMaterializationToken *)token
                       result:(BOOL *)result
                        error:(NSError *__autoreleasing *)error {
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
        *result = completed && !fakeFails;
        return YES;
    }
    return NO;
}

@end

#endif
