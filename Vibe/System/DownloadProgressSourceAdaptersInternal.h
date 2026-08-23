//
//  DownloadProgressSourceAdaptersInternal.h
//  Vibe
//

#import "DownloadProgressSourceAdapters.h"

NS_ASSUME_NONNULL_BEGIN

// Construction boundaries only. Notifications, filtering, KVO and teardown
// remain inside the production adapters under host-less tests.
typedef NSMetadataQuery * _Nonnull (^DownloadMetadataQueryFactory)(void);
typedef BOOL (^DownloadUbiquitousItemProbe)(NSURL *url);

@interface DownloadICloudProgressSource (Internal)

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler
                queryFactory:(DownloadMetadataQueryFactory)queryFactory
             ubiquitousProbe:(DownloadUbiquitousItemProbe)ubiquitousProbe;

@end

#if TARGET_OS_OSX

typedef id _Nonnull (^DownloadFileProviderSubscriber)(
        NSURL *url, NSProgressPublishingHandler publishingHandler);
typedef void (^DownloadFileProviderUnsubscriber)(id subscriberToken);

@interface DownloadFileProviderProgressSource (Internal)

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler
                  subscriber:(DownloadFileProviderSubscriber)subscriber
                unsubscriber:(DownloadFileProviderUnsubscriber)unsubscriber;

@end

#endif

NS_ASSUME_NONNULL_END
