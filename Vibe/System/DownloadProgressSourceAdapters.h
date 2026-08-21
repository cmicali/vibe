//
//  DownloadProgressSourceAdapters.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DownloadAllocatedSizeSampleHandler)(float fraction,
                                                    BOOL materialized,
                                                    BOOL dataless,
                                                    long long allocatedBytes,
                                                    long long logicalBytes);
typedef void (^DownloadProgressFractionHandler)(float fraction);

// Private source adapters for DownloadProgressMonitor. Each owns exactly one
// system observation mechanism and its teardown; the monitor owns precedence
// and coalescing.
@interface DownloadAllocatedSizeSource : NSObject

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadAllocatedSizeSampleHandler)handler;
- (void)start;
- (void)cancel;

@end

@interface DownloadICloudProgressSource : NSObject

@property(nonatomic, readonly, getter=isActive) BOOL active;

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler;
- (void)startIfUbiquitous;
- (void)cancel;

@end

#if TARGET_OS_OSX
@interface DownloadFileProviderProgressSource : NSObject

@property(nonatomic, readonly, getter=isActive) BOOL active;

- (instancetype)initWithURL:(NSURL *)url
                     handler:(DownloadProgressFractionHandler)handler;
- (void)start;
- (void)cancel;

@end
#endif

NS_ASSUME_NONNULL_END
