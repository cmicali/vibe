//
//  DownloadProgressMonitor.m
//  Vibe
//

#import "DownloadProgressMonitor.h"
#import "DownloadProgressRules.h"
#import "DownloadProgressSourceAdapters.h"
#if DEBUG
#import "DownloadProgressMonitor+Debug.h"
#endif

#include <os/lock.h>

#if DEBUG
// The fake matches the File Provider publication's measured cadence.
static const NSTimeInterval kFakeProgressIntervalSeconds = 1.0;

// TRAP: the debug driver writes this from its command path while monitors read
// it on main. Copying a block races its release without the lock.
static os_unfair_lock sFakeProgressLock = OS_UNFAIR_LOCK_INIT;
static VibeFakeDownloadProgress sFakeProgress;

static VibeFakeDownloadProgress VibeFakeProgressHook(void) {
    os_unfair_lock_lock(&sFakeProgressLock);
    VibeFakeDownloadProgress provider = sFakeProgress;
    os_unfair_lock_unlock(&sFakeProgressLock);
    return provider;
}
#endif

@implementation DownloadProgressMonitor {
    NSURL *_url;
    NSString *_path;
    BOOL _cancelled;
    float _lastReported;
    float _lastRawReported;
    void (^_movementHandler)(void);
    CFAbsoluteTime _startedAt;
    void (^_handler)(float);

    DownloadAllocatedSizeSource *_allocatedSizeSource;
    DownloadICloudProgressSource *_iCloudSource;
#if TARGET_OS_OSX
    DownloadFileProviderProgressSource *_fileProviderSource;
#endif
#if DEBUG
    dispatch_source_t _fakeTimer;
#endif
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = [url copy];
        _path = [url.path copy];
        _lastReported = -1;
        _lastRawReported = 0;
    }
    return self;
}

+ (instancetype)monitorReplacing:(DownloadProgressMonitor *)existing
                          forURL:(NSURL *)url
                      currentURL:(NSURL *_Nullable (^)(void))currentURL
                        movement:(void (^)(void))movement
                         handler:(void (^)(float fraction))handler {
    [existing cancel];
    DownloadProgressMonitor *monitor = [[DownloadProgressMonitor alloc] initWithURL:url];
    NSURL *wanted = [url copy];
    if (movement) {
        monitor->_movementHandler = ^{
            if ([currentURL() isEqual:wanted]) {
                movement();
            }
        };
    }
    [monitor startWithHandler:^(float fraction) {
        if ([currentURL() isEqual:wanted]) {
            handler(fraction);
        }
    }];
    return monitor;
}

- (void)startWithHandler:(void (^)(float))handler {
    _handler = [handler copy];
    _startedAt = CFAbsoluteTimeGetCurrent();

#if DEBUG
    if ([self startFakeProgress]) {
        return; // the fake replaces every real source; see +Debug.h
    }
#endif

    __weak DownloadProgressMonitor *weakSelf = self;
    _iCloudSource = [[DownloadICloudProgressSource alloc]
            initWithURL:_url handler:^(float fraction) {
        DownloadProgressMonitor *self = weakSelf;
        if (self && !self->_cancelled) {
            [self reportFraction:fraction];
        }
    }];
    [_iCloudSource startIfUbiquitous];

#if TARGET_OS_OSX
    _fileProviderSource = [[DownloadFileProviderProgressSource alloc]
            initWithURL:_url handler:^(float fraction) {
        DownloadProgressMonitor *self = weakSelf;
        if (self && !self->_cancelled) {
            [self reportFraction:fraction];
        }
    }];
    [_fileProviderSource start];
#endif

    _allocatedSizeSource = [[DownloadAllocatedSizeSource alloc]
            initWithURL:_url
                 handler:^(float fraction, BOOL materialized, BOOL dataless,
                           long long allocatedBytes, long long logicalBytes) {
        DownloadProgressMonitor *self = weakSelf;
        if (!self || self->_cancelled) {
            return;
        }
        BOOL fileProviderActive = NO;
#if TARGET_OS_OSX
        fileProviderActive = self->_fileProviderSource.isActive;
#endif
        if (!VibeDownloadPollShouldPublish(dataless, self->_iCloudSource.isActive,
                                           fileProviderActive)) {
            return;
        }
        if (fraction > self->_lastReported) {
            LogInfo(@"Download progress (poll): %.0f%% (%lld/%lld bytes, dataless=%d, %.1fs) %@",
                    fraction * 100, allocatedBytes, logicalBytes, dataless,
                    CFAbsoluteTimeGetCurrent() - self->_startedAt,
                    self->_path.lastPathComponent);
        }
        [self reportFraction:fraction];
        if (materialized) {
            [self cancel];
        }
    }];
    [_allocatedSizeSource start];
}

#if DEBUG

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

#endif

// Coalescing and movement are intentionally source-independent. A newly added
// source cannot accidentally acquire a different liveness policy.
- (void)reportFraction:(float)fraction {
    if (_cancelled) {
        return;
    }
    if (_movementHandler && VibeDownloadProgressIsMovement(_lastRawReported, fraction)) {
        _lastRawReported = fraction;
        _movementHandler();
    }
    if (!isfinite(fraction) || fraction < 0 || !_handler) {
        return;
    }
    if (fraction < _lastReported + 0.01f
            && !(fraction >= 1.0f && _lastReported < 1.0f)) {
        return;
    }
    _lastReported = fraction;
    _handler(MIN(1.0f, fraction));
}

- (void)cancel {
    _cancelled = YES;
#if DEBUG
    if (_fakeTimer) {
        dispatch_source_cancel(_fakeTimer);
        _fakeTimer = nil;
    }
#endif
    [_allocatedSizeSource cancel];
    _allocatedSizeSource = nil;
    [_iCloudSource cancel];
    _iCloudSource = nil;
#if TARGET_OS_OSX
    [_fileProviderSource cancel];
    _fileProviderSource = nil;
#endif
    _handler = nil;
}

- (void)dealloc {
    [self cancel];
}

@end
