//
//  CloudTransferRegistryInternal.h
//  Vibe
//
//  The coordinator's publication edges and the test seam.
//

#import "CloudTransferRegistry.h"

NS_ASSUME_NONNULL_BEGIN

// DownloadProgressMonitor in production; tests inject fakes via the factory.
@protocol VibeCloudTransferMonitor <NSObject>
- (void)cancel;
@end

// Delivers fractions to handler and raw movement to movement, on main, until
// cancelled. nil leaves the transfer indeterminate.
typedef id<VibeCloudTransferMonitor> _Nullable (^VibeCloudTransferMonitorFactory)(
        NSURL *url, void (^handler)(float fraction), void (^movement)(void));

@interface CloudTransferRegistry (Internal)

- (instancetype)initWithMonitorFactory:(VibeCloudTransferMonitorFactory)monitorFactory;

// Dispatched to main from the coordinator's state queue, whose FIFO order
// keeps a readmitted run's end-then-begin in order. began is idempotent per
// path; ended cancels the path's monitor.
- (void)beganTransferForPath:(NSString *)path url:(NSURL *)url;
- (void)endedTransferForPath:(NSString *)path;

// Debug channel: standardized path → progress.
- (NSDictionary<NSString *, NSNumber *> *)transferSnapshot;

@end

NS_ASSUME_NONNULL_END
