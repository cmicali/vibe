//
//  DownloadProgressMonitorInternal.h
//  Vibe
//
//  The source-independent delivery seam, for tests.
//

#import "DownloadProgressMonitor.h"

NS_ASSUME_NONNULL_BEGIN

@interface DownloadProgressMonitor (Internal)

- (instancetype)initWithURL:(NSURL *)url;
- (void)startWithHandler:(void (^)(float fraction))handler;
- (void)reportFraction:(float)fraction;

@end

NS_ASSUME_NONNULL_END
