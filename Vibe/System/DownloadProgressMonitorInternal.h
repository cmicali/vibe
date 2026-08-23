//
//  DownloadProgressMonitorInternal.h
//  Vibe
//
//  The source-independent delivery seam. The monitor and its tests both use
//  this surface so movement, coalescing, replacement and cancellation are
//  exercised without depending on a system progress source.
//

#import "DownloadProgressMonitor.h"

NS_ASSUME_NONNULL_BEGIN

@interface DownloadProgressMonitor (Internal)

- (instancetype)initWithURL:(NSURL *)url;
- (void)startWithHandler:(void (^)(float fraction))handler;
- (void)reportFraction:(float)fraction;

@end

NS_ASSUME_NONNULL_END
