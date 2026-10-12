//
//  DownloadProgressMonitorInternal.h
//  Vibe
//
//  The source-independent delivery seam, for tests, and the state the debug
//  seam's fake progress reads (DownloadProgressMonitor+Debug.m).
//

#import "DownloadProgressMonitor.h"

NS_ASSUME_NONNULL_BEGIN

@interface DownloadProgressMonitor () {
    NSURL *_url;
    NSString *_path;
    BOOL _cancelled;
    float _lastReported;
    CFAbsoluteTime _startedAt;
    // Debug builds only. The fake progress's tick.
    dispatch_source_t _fakeTimer;
}
@end

@interface DownloadProgressMonitor (Internal)

- (instancetype)initWithURL:(NSURL *)url;
- (void)startWithHandler:(void (^)(float fraction))handler;
- (void)reportFraction:(float)fraction;

@end

NS_ASSUME_NONNULL_END
