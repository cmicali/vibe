//
//  DownloadProgressMonitor.m
//  Vibe
//

#import "DownloadProgressMonitor.h"

#include <errno.h>
#include <sys/stat.h>

// 4 Hz: fast enough for a live-feeling bar, cheap enough that a stat per
// tick is free. Sampling is a timer on a utility queue — never the main
// thread, and never the player or loader queues.
static const NSTimeInterval kPollIntervalSeconds = 0.25;

static void *kFractionContext = &kFractionContext;

@implementation DownloadProgressMonitor {
    NSURL               *_url;
    NSString            *_path;
    dispatch_source_t   _timer;
    BOOL                _cancelled;   // main-confined, like start/cancel
    float               _lastReported;
    CFAbsoluteTime      _startedAt;
    void                (^_handler)(float);
#if TARGET_OS_OSX
    // The File Provider progress publication. Exact when it fires, so it
    // silences the poll; not every provider publishes, so the poll stays the
    // floor.
    id                  _subscriberToken;
    NSProgress          *_publishedProgress;
    BOOL                _publisherActive;
#endif
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = [url copy];
        _path = [url.path copy];
        _lastReported = -1;
    }
    return self;
}

- (void)startWithHandler:(void (^)(float))handler {
    _handler = [handler copy];
    _startedAt = CFAbsoluteTimeGetCurrent();

#if TARGET_OS_OSX
    __weak DownloadProgressMonitor *weakSelf = self;
    // The publishing handler runs on the main thread when a provider begins
    // (or already is) publishing progress for this URL; the returned block
    // runs when it unpublishes — the download finished or was abandoned.
    _subscriberToken = [NSProgress addSubscriberForFileURL:_url
            withPublishingHandler:^NSProgressUnpublishingHandler(NSProgress *progress) {
        DownloadProgressMonitor *self = weakSelf;
        if (!self || self->_cancelled) {
            return nil;
        }
        self->_publisherActive = YES;
        self->_publishedProgress = progress;
        [progress addObserver:self forKeyPath:@"fractionCompleted"
                      options:NSKeyValueObservingOptionInitial context:kFractionContext];
        return ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                DownloadProgressMonitor *self = weakSelf;
                if (!self) {
                    return;
                }
                [self detachPublishedProgress];
                if (!self->_cancelled) {
                    [self reportFraction:1.0];  // unpublish means the download ended
                }
            });
        };
    }];
#endif

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW,
            (uint64_t)(kPollIntervalSeconds * NSEC_PER_SEC), 50 * NSEC_PER_MSEC);
    NSString *path = _path;
    __weak DownloadProgressMonitor *weakTimerSelf = self;
    // One diagnostic line per monitor on the first poll, whatever it finds:
    // whether a provider's placeholder is visible as a dataless file with a
    // real size — the only signal this poll can turn into a fraction — varies
    // by provider and OS, and a silent monitor is indistinguishable from a
    // broken one without it.
    __block BOOL firstTick = YES;
    dispatch_source_set_event_handler(_timer, ^{
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) != 0) {
            int statErrno = errno;
            if (firstTick) {
                firstTick = NO;
                LogInfo(@"Download progress: cannot stat %@ (errno=%d)",
                        path.lastPathComponent, statErrno);
            }
            return; // unreadable: nothing to report yet
        }
        if (st.st_size <= 0) {
            if (firstTick) {
                firstTick = NO;
                LogInfo(@"Download progress: %@ reports no size yet (flags=0x%x)",
                        path.lastPathComponent, st.st_flags);
            }
            return; // empty or sizeless placeholder: nothing to report yet
        }
        BOOL dataless = (st.st_flags & SF_DATALESS) != 0;
        if (firstTick) {
            firstTick = NO;
            LogInfo(@"Download progress: first poll %@ — size=%lld allocated=%lld dataless=%d flags=0x%x",
                    path.lastPathComponent, (long long)st.st_size,
                    (long long)st.st_blocks * 512, dataless, st.st_flags);
        }
        // 512-byte blocks; allocated can exceed logical on materialized
        // files, so clamp.
        double fraction = MIN(1.0, (double)st.st_blocks * 512.0 / (double)st.st_size);
        if (!dataless) {
            fraction = 1.0;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            DownloadProgressMonitor *self = weakTimerSelf;
            if (!self || self->_cancelled) {
                return;
            }
#if TARGET_OS_OSX
            if (self->_publisherActive && dataless) {
                return; // the provider's own numbers are driving
            }
#endif
            if (fraction > self->_lastReported) {
                LogInfo(@"Download progress (poll): %.0f%% (%lld/%lld bytes, dataless=%d, %.1fs) %@",
                        fraction * 100, (long long)st.st_blocks * 512, (long long)st.st_size,
                        dataless, CFAbsoluteTimeGetCurrent() - self->_startedAt,
                        path.lastPathComponent);
            }
            [self reportFraction:(float)fraction];
            if (!dataless) {
                [self cancel]; // fully materialized: the 1.0 above was final
            }
        });
    });
    dispatch_resume(_timer);
}

// The shared spout: coalesces to whole-percent moves, never fires after
// cancel, never runs backwards (the poll's block counts can wobble).
- (void)reportFraction:(float)fraction {
    if (_cancelled || !_handler) {
        return;
    }
    if (fraction < _lastReported + 0.01f && !(fraction >= 1.0f && _lastReported < 1.0f)) {
        return;
    }
    _lastReported = fraction;
    _handler(MIN(1.0f, fraction));
}

#if TARGET_OS_OSX
- (void)detachPublishedProgress {
    if (_publishedProgress) {
        [_publishedProgress removeObserver:self forKeyPath:@"fractionCompleted"
                                   context:kFractionContext];
        _publishedProgress = nil;
    }
    _publisherActive = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context != kFractionContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    double fraction = ((NSProgress *)object).fractionCompleted;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_cancelled) {
            LogInfo(@"Download progress (provider): %.0f%% %@",
                    fraction * 100, self->_path.lastPathComponent);
            [self reportFraction:(float)fraction];
        }
    });
}
#endif

- (void)cancel {
    _cancelled = YES;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
#if TARGET_OS_OSX
    if (_subscriberToken) {
        [NSProgress removeSubscriber:_subscriberToken];
        _subscriberToken = nil;
    }
    [self detachPublishedProgress];
#endif
    _handler = nil;
}

@end
