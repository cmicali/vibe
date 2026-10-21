//
//  DownloadProgressMonitor.m
//  Vibe
//

#import "DownloadProgressMonitorInternal.h"
#import "DownloadProgressRules.h"
#import "DownloadProgressSourceAdapters.h"
#import "DownloadProgressMonitor+Debug.h"
#import "VibeMacros.h"

@implementation DownloadProgressMonitor {
    float _lastRawReported;
    void (^_movementHandler)(void);
    void (^_handler)(float);

    DownloadAllocatedSizeSource *_allocatedSizeSource;
    DownloadICloudProgressSource *_iCloudSource;
#if TARGET_OS_OSX
    DownloadFileProviderProgressSource *_fileProviderSource;
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

+ (instancetype)monitorForURL:(NSURL *)url
                     movement:(void (^)(void))movement
                      handler:(void (^)(float fraction))handler {
    DownloadProgressMonitor *monitor = [[DownloadProgressMonitor alloc] initWithURL:url];
    monitor->_movementHandler = [movement copy];
    [monitor startWithHandler:handler];
    return monitor;
}

- (void)startWithHandler:(void (^)(float))handler {
    _handler = [handler copy];
    _startedAt = CFAbsoluteTimeGetCurrent();

#if DEBUG
    if ([self startFakeProgress]) {
        return; // replaces every real source (+Debug.h)
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

// Source-independent, so no source gets its own liveness policy.
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
