//
//  DownloadProgressSourceAdaptersInternal.h
//  Vibe
//

#import "DownloadProgressSourceAdapters.h"

NS_ASSUME_NONNULL_BEGIN

// Construction boundaries only; the rest stays production under tests.
typedef NSMetadataQuery * _Nonnull (^DownloadMetadataQueryFactory)(void);

@interface DownloadICloudProgressSource (Internal)

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler
                queryFactory:(DownloadMetadataQueryFactory)queryFactory;

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
