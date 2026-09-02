//
//  DownloadProgressSourceAdapters.m
//  Vibe
//

#import "DownloadProgressSourceAdaptersInternal.h"

#include <errno.h>
#include <sys/stat.h>

static const NSTimeInterval kPollIntervalSeconds = 0.25;

// The provider's first-poll diagnostic. Read once because NSURL memoizes
// resource values, so a per-tick read would keep answering the first value.
static NSString *VibeDownloadingStatus(NSURL *url) {
    id status = nil;
    [url getResourceValue:&status forKey:NSURLUbiquitousItemDownloadingStatusKey error:NULL];
    return status ?: @"(none)";
}

@implementation DownloadAllocatedSizeSource {
    NSURL *_url;
    NSString *_path;
    DownloadAllocatedSizeSampleHandler _handler;
    dispatch_source_t _timer;
    BOOL _cancelled;
}

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadAllocatedSizeSampleHandler)handler {
    self = [super init];
    if (self) {
        _url = [url copy];
        _path = [url.path copy];
        _handler = [handler copy];
    }
    return self;
}

- (void)start {
    if (_cancelled || _timer) {
        return;
    }
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW,
            (uint64_t)(kPollIntervalSeconds * NSEC_PER_SEC), 50 * NSEC_PER_MSEC);

    NSString *path = _path;
    NSURL *url = _url;
    __weak DownloadAllocatedSizeSource *weakSelf = self;
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
            return;
        }
        if (st.st_size <= 0) {
            if (firstTick) {
                firstTick = NO;
                LogInfo(@"Download progress: %@ reports no size yet (flags=0x%x)",
                        path.lastPathComponent, st.st_flags);
            }
            return;
        }

        BOOL dataless = (st.st_flags & SF_DATALESS) != 0;
        long long logical = (long long)st.st_size;
        long long allocated = (long long)st.st_blocks * 512;
        if (firstTick) {
            firstTick = NO;
            LogInfo(@"Download progress: first poll %@ — size=%lld allocated=%lld dataless=%d flags=0x%x status=%@",
                    path.lastPathComponent, logical, allocated, dataless,
                    st.st_flags, VibeDownloadingStatus(url));
        }

        double fraction = MIN(1.0, (double)allocated / (double)logical);
        // TRAP: clear SF_DATALESS alone is not proof of materialization. Some
        // providers never set it, so allocated blocks must agree.
        BOOL materialized = !dataless && allocated >= logical;
        if (materialized) {
            fraction = 1.0;
        }
        else if (fraction <= 0) {
            return;
        }

        run_on_main_thread({
            DownloadAllocatedSizeSource *source = weakSelf;
            if (!source || source->_cancelled || !source->_handler) {
                return;
            }
            source->_handler((float)fraction, materialized, dataless,
                             allocated, logical);
        });
    });
    dispatch_resume(_timer);
}

- (void)cancel {
    _cancelled = YES;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    _handler = nil;
}

- (void)dealloc {
    [self cancel];
}

@end

@implementation DownloadICloudProgressSource {
    NSURL *_url;
    NSString *_path;
    DownloadProgressFractionHandler _handler;
    DownloadMetadataQueryFactory _queryFactory;
    DownloadUbiquitousItemProbe _ubiquitousProbe;
    NSMetadataQuery *_query;
    BOOL _active;
}

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler {
    return [self initWithURL:url handler:handler queryFactory:^NSMetadataQuery *{
        return [[NSMetadataQuery alloc] init];
    } ubiquitousProbe:^BOOL(NSURL *candidate) {
        id ubiquitous = nil;
        return [candidate getResourceValue:&ubiquitous
                                    forKey:NSURLIsUbiquitousItemKey
                                     error:NULL]
                && [ubiquitous boolValue];
    }];
}

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler
                queryFactory:(DownloadMetadataQueryFactory)queryFactory
             ubiquitousProbe:(DownloadUbiquitousItemProbe)ubiquitousProbe {
    self = [super init];
    if (self) {
        _url = [url copy];
        _path = [url.path copy];
        _handler = [handler copy];
        _queryFactory = [queryFactory copy];
        _ubiquitousProbe = [ubiquitousProbe copy];
    }
    return self;
}

- (BOOL)isActive {
    return _active;
}

- (void)startIfUbiquitous {
    if (_query || !_handler || !_ubiquitousProbe(_url)) {
        return;
    }

    NSMetadataQuery *query = _queryFactory();
    query.searchScopes = @[NSMetadataQueryUbiquitousDataScope,
                           NSMetadataQueryUbiquitousDocumentsScope,
                           NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope];
    query.predicate = [NSPredicate predicateWithFormat:@"%K == %@",
                       NSMetadataItemFSNameKey, _path.lastPathComponent];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(queryUpdated:)
                   name:NSMetadataQueryDidFinishGatheringNotification object:query];
    [center addObserver:self selector:@selector(queryUpdated:)
                   name:NSMetadataQueryDidUpdateNotification object:query];
    _query = query;
    if (![query startQuery]) {
        [self cancel];
    }
}

- (void)queryUpdated:(NSNotification *)note {
    NSMetadataQuery *query = _query;
    if (!query) {
        return;
    }
    [query disableUpdates];
    BOOL matched = NO;
    for (NSUInteger i = 0; i < query.resultCount; i++) {
        NSMetadataItem *item = [query resultAtIndex:i];
        NSURL *itemURL = [item valueForAttribute:NSMetadataItemURLKey];
        if (![itemURL.URLByStandardizingPath.path
                isEqualToString:_url.URLByStandardizingPath.path]) {
            continue;
        }
        matched = YES;
        NSNumber *percent = [item valueForAttribute:NSMetadataUbiquitousItemPercentDownloadedKey];
        if (percent != nil) {
            _active = YES;
            LogInfo(@"Download progress (iCloud): %.0f%% %@",
                    percent.doubleValue, _path.lastPathComponent);
            if (_handler) {
                _handler((float)(percent.doubleValue / 100.0));
            }
        }
        break;
    }
    [query enableUpdates];

    // TRAP: NSURLIsUbiquitousItemKey is not an iCloud test — every File
    // Provider item answers YES, a Dropbox file included. Gathering is what
    // proves that iCloud does not index this particular item.
    if (!matched && [note.name isEqualToString:NSMetadataQueryDidFinishGatheringNotification]) {
        LogInfo(@"Download progress: %@ is not an indexed iCloud item — poll only",
                _path.lastPathComponent);
        [self cancel];
    }
}

- (void)cancel {
    if (_query) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:nil object:_query];
        [_query stopQuery];
        _query = nil;
    }
    _active = NO;
    _handler = nil;
}

- (void)dealloc {
    [self cancel];
}

@end

#if TARGET_OS_OSX

static void *kFileProviderFractionContext = &kFileProviderFractionContext;

@implementation DownloadFileProviderProgressSource {
    NSURL *_url;
    NSString *_path;
    DownloadProgressFractionHandler _handler;
    id _subscriberToken;
    DownloadFileProviderSubscriber _subscriber;
    DownloadFileProviderUnsubscriber _unsubscriber;
    NSProgress *_publishedProgress;
    BOOL _active;
    BOOL _cancelled;
}

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler {
    return [self initWithURL:url handler:handler
            subscriber:^id(NSURL *candidate, NSProgressPublishingHandler publishingHandler) {
        return [NSProgress addSubscriberForFileURL:candidate
                              withPublishingHandler:publishingHandler];
    } unsubscriber:^(id subscriberToken) {
        [NSProgress removeSubscriber:subscriberToken];
    }];
}

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler
                  subscriber:(DownloadFileProviderSubscriber)subscriber
                unsubscriber:(DownloadFileProviderUnsubscriber)unsubscriber {
    self = [super init];
    if (self) {
        _url = [url copy];
        _path = [url.path copy];
        _handler = [handler copy];
        _subscriber = [subscriber copy];
        _unsubscriber = [unsubscriber copy];
    }
    return self;
}

- (BOOL)isActive {
    return _active;
}

- (void)start {
    if (_cancelled || _subscriberToken) {
        return;
    }
    __weak DownloadFileProviderProgressSource *weakSelf = self;
    _subscriberToken = _subscriber(_url,
            ^NSProgressUnpublishingHandler(NSProgress *progress) {
        // The publishing handler arrives on an arbitrary thread; _active and
        // _publishedProgress are main-confined (cancel, isActive), so attach on
        // main. The cancelled check moves inside the hop for the same reason.
        run_on_main_thread({
            DownloadFileProviderProgressSource *source = weakSelf;
            if (!source || source->_cancelled) {
                return;
            }
            [source detachPublishedProgress];
            source->_active = YES;
            source->_publishedProgress = progress;
            [progress addObserver:source forKeyPath:@"fractionCompleted"
                          options:NSKeyValueObservingOptionInitial
                          context:kFileProviderFractionContext];
        });
        __weak NSProgress *weakProgress = progress;
        return ^{
            run_on_main_thread({
                DownloadFileProviderProgressSource *source = weakSelf;
                NSProgress *progress = weakProgress;
                if (!source || !progress || source->_publishedProgress != progress) {
                    return;
                }
                [source detachPublishedProgress];
                if (!source->_cancelled) {
                    LogInfo(@"Download progress: provider unpublished %@ — poll resumed",
                            source->_path.lastPathComponent);
                }
            });
        };
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != kFileProviderFractionContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    double fraction = ((NSProgress *)object).fractionCompleted;
    __weak DownloadFileProviderProgressSource *weakSelf = self;
    __weak NSProgress *weakProgress = object;
    run_on_main_thread({
        DownloadFileProviderProgressSource *source = weakSelf;
        NSProgress *progress = weakProgress;
        if (!source || !progress || source->_cancelled
                || source->_publishedProgress != progress) {
            return;
        }
        LogInfo(@"Download progress (provider): %.0f%% %@",
                fraction * 100, source->_path.lastPathComponent);
        if (source->_handler) {
            source->_handler((float)fraction);
        }
    });
}

- (void)detachPublishedProgress {
    if (_publishedProgress) {
        [_publishedProgress removeObserver:self forKeyPath:@"fractionCompleted"
                                   context:kFileProviderFractionContext];
        _publishedProgress = nil;
    }
    _active = NO;
}

- (void)cancel {
    _cancelled = YES;
    if (_subscriberToken) {
        _unsubscriber(_subscriberToken);
        _subscriberToken = nil;
    }
    [self detachPublishedProgress];
    _handler = nil;
}

- (void)dealloc {
    [self cancel];
}

@end

#endif
