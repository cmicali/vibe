//
//  DownloadProgressMonitor.m
//  Vibe
//

#import "DownloadProgressMonitor.h"
#if DEBUG
#import "DownloadProgressMonitor+Debug.h"   // the fake progress, declared out of the shipping header
#endif

#include <errno.h>
#include <os/lock.h>
#include <sys/stat.h>

// 4 Hz: fast enough for a live-feeling bar, cheap enough that a stat per
// tick is free. Sampling is a timer on a utility queue — never the main
// thread, and never the player or loader queues.
static const NSTimeInterval kPollIntervalSeconds = 0.25;

#if DEBUG
// 1 Hz, because that is what the real thing delivers: the File Provider
// publication lands about once a second and polling between firings returns
// the same value, so a fake that ticked faster would exercise an easing the
// indicator never sees in production.
static const NSTimeInterval kFakeProgressIntervalSeconds = 1.0;

// TRAP: installed and cleared from wherever VibeFakeCloud is driven, and read
// on this class's own paths, so it takes the lock for the same reason
// CloudFileMaterializer's hooks do — an unsynchronized read of a block global
// is a retain racing a release, not merely something TSan dislikes.
static os_unfair_lock sFakeProgressLock = OS_UNFAIR_LOCK_INIT;
static VibeFakeDownloadProgress sFakeProgress;

static VibeFakeDownloadProgress VibeFakeProgressHook(void) {
    os_unfair_lock_lock(&sFakeProgressLock);
    VibeFakeDownloadProgress provider = sFakeProgress;
    os_unfair_lock_unlock(&sFakeProgressLock);
    return provider;
}
#endif

static void *kFractionContext = &kFractionContext;

// The provider's own answer for the first-poll diagnostic: NotDownloaded,
// Downloaded or Current for a file-provider item, nothing at all for a plain
// local file. Read once per monitor — NSURL memoizes resource values, so a
// per-tick read would answer from the first one anyway.
static NSString *VibeDownloadingStatus(NSURL *url) {
    id status = nil;
    [url getResourceValue:&status forKey:NSURLUbiquitousItemDownloadingStatusKey error:NULL];
    return status ?: @"(none)";
}

@implementation DownloadProgressMonitor {
    NSURL               *_url;
    NSString            *_path;
    dispatch_source_t   _timer;
    BOOL                _cancelled;   // main-confined, like start/cancel
    float               _lastReported;
    CFAbsoluteTime      _startedAt;
    void                (^_handler)(float);
    // The iCloud exception: a genuine ubiquitous item is the one kind of cloud
    // file whose percentage the system will tell a consuming app, through
    // NSMetadataQuery. Nil for everything else, which is most things.
    NSMetadataQuery     *_metadataQuery;
    BOOL                _metadataActive;
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

+ (instancetype)monitorReplacing:(DownloadProgressMonitor *)existing
                          forURL:(NSURL *)url
                      currentURL:(NSURL *_Nullable (^)(void))currentURL
                         handler:(void (^)(float fraction))handler {
    [existing cancel];
    DownloadProgressMonitor *monitor = [[DownloadProgressMonitor alloc] initWithURL:url];
    NSURL *wanted = [url copy];
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
        return; // the fake stands in for all three sources; see +Debug.h
    }
#endif

    [self startMetadataQueryIfUbiquitous];

#if TARGET_OS_OSX
    __weak DownloadProgressMonitor *weakSelf = self;
    // The publishing handler runs on the main thread when a provider begins
    // (or already is) publishing progress for this URL; the returned block
    // runs when it unpublishes — the download finished or was abandoned. The
    // callback cannot distinguish those outcomes, so the poll verifies which.
    _subscriberToken = [NSProgress addSubscriberForFileURL:_url
            withPublishingHandler:^NSProgressUnpublishingHandler(NSProgress *progress) {
        DownloadProgressMonitor *self = weakSelf;
        if (!self || self->_cancelled) {
            return nil;
        }
        [self detachPublishedProgress];
        self->_publisherActive = YES;
        self->_publishedProgress = progress;
        [progress addObserver:self forKeyPath:@"fractionCompleted"
                      options:NSKeyValueObservingOptionInitial context:kFractionContext];
        __weak NSProgress *weakProgress = progress;
        return ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                DownloadProgressMonitor *self = weakSelf;
                NSProgress *progress = weakProgress;
                if (!self || !progress || self->_publishedProgress != progress) {
                    return;
                }
                [self detachPublishedProgress];
                if (!self->_cancelled) {
                    LogInfo(@"Download progress: provider unpublished %@ — poll resumed",
                            self->_path.lastPathComponent);
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
    NSURL *url = _url;
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
        long long allocated = (long long)st.st_blocks * 512;
        if (firstTick) {
            firstTick = NO;
            // The provider's own downloading status joins the flags because it
            // is the only way to tell a provider that does not mark its
            // placeholders SF_DATALESS from a file that is genuinely local.
            LogInfo(@"Download progress: first poll %@ — size=%lld allocated=%lld dataless=%d flags=0x%x status=%@",
                    path.lastPathComponent, (long long)st.st_size,
                    allocated, dataless, st.st_flags, VibeDownloadingStatus(url));
        }
        // 512-byte blocks; allocated can exceed logical on materialized files,
        // so clamp.
        double fraction = MIN(1.0, (double)allocated / (double)st.st_size);
        // TRAP: a clear SF_DATALESS is not proof the file is here. It is clear
        // for a provider that never sets it at all, and taking that for
        // materialized reported an instant, motionless 100% for a download
        // that had not started — which is how a fill that "does not work"
        // looks. Both signals have to agree: the flag is down AND the blocks
        // are there. Nothing is lost by being strict, because the open landing
        // cancels this monitor anyway; the test only decides when to stop
        // polling a file that is not going anywhere.
        BOOL materialized = !dataless && allocated >= st.st_size;
        if (materialized) {
            fraction = 1.0;
        }
        else if (fraction <= 0) {
            return; // no number worth reporting: the indicator stays indeterminate
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
            if (self->_metadataActive && dataless) {
                return; // iCloud's own numbers are driving
            }
            if (fraction > self->_lastReported) {
                LogInfo(@"Download progress (poll): %.0f%% (%lld/%lld bytes, dataless=%d, %.1fs) %@",
                        fraction * 100, allocated, (long long)st.st_size,
                        dataless, CFAbsoluteTimeGetCurrent() - self->_startedAt,
                        path.lastPathComponent);
            }
            [self reportFraction:(float)fraction];
            if (materialized) {
                [self cancel]; // the file is here: the 1.0 above was final
            }
        });
    });
    dispatch_resume(_timer);
}

#if DEBUG

#pragma mark - The fake source

+ (void)setFakeProgressProvider:(VibeFakeDownloadProgress)provider {
    os_unfair_lock_lock(&sFakeProgressLock);
    sFakeProgress = [provider copy];
    os_unfair_lock_unlock(&sFakeProgressLock);
}

// YES when a fake transfer owns this URL, and the timer is now running in
// place of the three real sources. Asked once: a URL the installer disowns is
// a real file and has to reach those sources instead.
- (BOOL)startFakeProgress {
    VibeFakeDownloadProgress provider = VibeFakeProgressHook();
    if (!provider || provider(_url) < 0) {
        return NO;
    }
    NSURL *url = _url;
    __weak DownloadProgressMonitor *weakSelf = self;
    // Main queue: the arithmetic is free and reportFraction: is main-confined
    // anyway, so there is nothing to hop for.
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW,
            (uint64_t)(kFakeProgressIntervalSeconds * NSEC_PER_SEC), 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{
        DownloadProgressMonitor *self = weakSelf;
        if (!self || self->_cancelled) {
            return;
        }
        float fraction = provider(url);
        if (fraction <= 0) {
            return; // nothing worth reporting: the indicator stays indeterminate, as with the poll
        }
        if (fraction > self->_lastReported) {
            LogInfo(@"Download progress (fake): %.0f%% (%.1fs) %@", fraction * 100,
                    CFAbsoluteTimeGetCurrent() - self->_startedAt, self->_path.lastPathComponent);
        }
        [self reportFraction:fraction];
        if (fraction >= 1.0f) {
            [self cancel]; // the transfer is done: the 1.0 above was final
        }
    });
    dispatch_resume(_timer);
    return YES;
}

#endif

#pragma mark - The iCloud source

// iCloud Drive is the ONE cloud whose transfer a consuming app can watch:
// NSMetadataQuery publishes NSMetadataUbiquitousItemPercentDownloadedKey for a
// ubiquitous item, which no third-party File Provider has an equivalent of. So
// this runs only when the URL actually is one, and everything else falls to
// the poll and, on macOS, the provider's own publication.
//
// It observes rather than starts: the contract above is that the monitor never
// triggers the download, and it does not need to — the percentage is reported
// for a materialization whoever asked for it, and the player's open is asking.
//
// TRAP: NSURLIsUbiquitousItemKey is not an iCloud test. MEASURED on a device,
// a Dropbox file answers YES to it — every File Provider item does — so the
// flag only gets us as far as "some cloud", and the query is what settles it.
// Hence the gathering check below: an item iCloud does not index is one it
// will never report a percentage for, and the query stops there rather than
// idling for the length of the download.
- (void)startMetadataQueryIfUbiquitous {
    id ubiquitous = nil;
    if (![_url getResourceValue:&ubiquitous forKey:NSURLIsUbiquitousItemKey error:NULL]
            || ![ubiquitous boolValue]) {
        return;
    }
    // Matched on filename and then confirmed by path: a path predicate alone
    // misses an external document, whose indexed path need not be the one this
    // process was handed.
    NSMetadataQuery *query = [[NSMetadataQuery alloc] init];
    query.searchScopes = @[NSMetadataQueryUbiquitousDataScope,
                           NSMetadataQueryUbiquitousDocumentsScope,
                           NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope];
    query.predicate = [NSPredicate predicateWithFormat:@"%K == %@",
                       NSMetadataItemFSNameKey, _path.lastPathComponent];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(metadataQueryUpdated:)
                   name:NSMetadataQueryDidFinishGatheringNotification object:query];
    [center addObserver:self selector:@selector(metadataQueryUpdated:)
                   name:NSMetadataQueryDidUpdateNotification object:query];
    _metadataQuery = query;
    [query startQuery];
}

- (void)metadataQueryUpdated:(NSNotification *)note {
    if (_cancelled) {
        return;
    }
    NSMetadataQuery *query = _metadataQuery;
    [query disableUpdates];
    BOOL matched = NO;
    for (NSUInteger i = 0; i < query.resultCount; i++) {
        NSMetadataItem *item = [query resultAtIndex:i];
        NSURL *itemURL = [item valueForAttribute:NSMetadataItemURLKey];
        if (![itemURL.URLByStandardizingPath.path isEqualToString:_url.URLByStandardizingPath.path]) {
            continue;
        }
        matched = YES;
        NSNumber *percent = [item valueForAttribute:NSMetadataUbiquitousItemPercentDownloadedKey];
        if (percent != nil) {
            _metadataActive = YES;   // silences the poll, which cannot do better
            LogInfo(@"Download progress (iCloud): %.0f%% %@",
                    percent.doubleValue, _path.lastPathComponent);
            [self reportFraction:(float)(percent.doubleValue / 100.0)];
        }
        break;
    }
    [query enableUpdates];
    // Gathering has seen everything iCloud indexes. An item missing from that
    // is a third-party provider's, which will never report a percentage, so
    // the query stops rather than idling for the length of the download.
    if (!matched && [note.name isEqualToString:NSMetadataQueryDidFinishGatheringNotification]) {
        LogInfo(@"Download progress: %@ is not an indexed iCloud item — poll only",
                _path.lastPathComponent);
        [self stopMetadataQuery];
    }
}

- (void)stopMetadataQuery {
    if (!_metadataQuery) {
        return;
    }
    [NSNotificationCenter.defaultCenter removeObserver:self name:nil object:_metadataQuery];
    [_metadataQuery stopQuery];
    _metadataQuery = nil;
    _metadataActive = NO;
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
    // Weak, like every other hop in this class: the provider publishes on its
    // own threads, so a strong capture here would resurrect a monitor the main
    // thread is releasing.
    __weak DownloadProgressMonitor *weakSelf = self;
    __weak NSProgress *weakProgress = object;
    dispatch_async(dispatch_get_main_queue(), ^{
        DownloadProgressMonitor *self = weakSelf;
        NSProgress *progress = weakProgress;
        if (self && progress && !self->_cancelled && self->_publishedProgress == progress) {
            LogInfo(@"Download progress (provider): %.0f%% %@",
                    fraction * 100, self->_path.lastPathComponent);
            [self reportFraction:(float)fraction];
        }
    });
}
#endif

// The KVO observation and the NSProgress subscriber outlive a released
// monitor: dropping one mid-download without cancelling it first would leave
// the file provider messaging a dead observer. Callers do cancel, and cancel
// is idempotent, so this is only the net.
- (void)dealloc {
    [self cancel];
}

- (void)cancel {
    _cancelled = YES;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    [self stopMetadataQuery];
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
