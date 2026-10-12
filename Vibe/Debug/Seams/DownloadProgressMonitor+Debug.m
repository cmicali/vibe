//
//  DownloadProgressMonitor+Debug.m
//  Vibe
//

#import "DownloadProgressMonitor+Debug.h"

#if DEBUG

#import "DownloadProgressMonitorInternal.h"

#include <os/lock.h>

// The fake matches the File Provider publication's measured cadence.
static const NSTimeInterval kFakeProgressIntervalSeconds = 1.0;

// TRAP: the debug driver writes this from its command path while monitors
// read it; copying a block races its release without the lock.
static os_unfair_lock sFakeProgressLock = OS_UNFAIR_LOCK_INIT;
static VibeFakeDownloadProgress sFakeProgress;

static VibeFakeDownloadProgress VibeFakeProgressHook(void) {
    os_unfair_lock_lock(&sFakeProgressLock);
    VibeFakeDownloadProgress provider = sFakeProgress;
    os_unfair_lock_unlock(&sFakeProgressLock);
    return provider;
}

@implementation DownloadProgressMonitor (Debug)

+ (void)setFakeProgressProvider:(VibeFakeDownloadProgress)provider {
    os_unfair_lock_lock(&sFakeProgressLock);
    sFakeProgress = [provider copy];
    os_unfair_lock_unlock(&sFakeProgressLock);
}

- (BOOL)startFakeProgress {
    VibeFakeDownloadProgress provider = VibeFakeProgressHook();
    if (!provider || provider(_url) < 0) {
        return NO;
    }
    NSURL *url = _url;
    __weak DownloadProgressMonitor *weakSelf = self;
    _fakeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                        dispatch_get_main_queue());
    dispatch_source_set_timer(_fakeTimer, DISPATCH_TIME_NOW,
            (uint64_t)(kFakeProgressIntervalSeconds * NSEC_PER_SEC), 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_fakeTimer, ^{
        DownloadProgressMonitor *self = weakSelf;
        if (!self || self->_cancelled) {
            return;
        }
        float fraction = provider(url);
        if (fraction < 0) {
            return;
        }
        if (fraction > self->_lastReported) {
            LogInfo(@"Download progress (fake): %.0f%% (%.1fs) %@", fraction * 100,
                    CFAbsoluteTimeGetCurrent() - self->_startedAt,
                    self->_path.lastPathComponent);
        }
        [self reportFraction:fraction];
        if (fraction >= 1.0f) {
            [self cancel];
        }
    });
    dispatch_resume(_fakeTimer);
    return YES;
}

@end

#endif
