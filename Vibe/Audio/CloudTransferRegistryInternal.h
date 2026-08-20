//
//  CloudTransferRegistryInternal.h
//  Vibe
//
//  The coordinator's publication edges and the test seam. Not public API: the
//  only callers are AudioFileMaterializationCoordinator's start/finish edges
//  and the tests.
//

#import "CloudTransferRegistry.h"

NS_ASSUME_NONNULL_BEGIN

// What the registry holds per transfer it watches itself; DownloadProgressMonitor
// conforms in the implementation. Tests inject fakes through the factory.
@protocol VibeCloudTransferMonitor <NSObject>
- (void)cancel;
@end

// Mints a monitor for a transferring path's URL, delivering fractions to
// handler on main until cancelled. nil means no monitor could be built, which
// leaves the transfer indeterminate — exactly the third-party iOS case.
typedef id<VibeCloudTransferMonitor> _Nullable (^VibeCloudTransferMonitorFactory)(
        NSURL *url, void (^handler)(float fraction));

@interface CloudTransferRegistry (Internal)

- (instancetype)initWithMonitorFactory:(VibeCloudTransferMonitorFactory)monitorFactory;

// The coordinator's edges, dispatched to main from its state queue. began is
// idempotent per path — a cancelled-and-readmitted run ends and re-begins,
// and FIFO delivery to main keeps that order. ended cancels the path's own
// monitor; nothing may outlive its transfer.
- (void)beganTransferForPath:(NSString *)path url:(NSURL *)url;
- (void)endedTransferForPath:(NSString *)path;

// Introspection for the debug channel: standardized path → progress.
- (NSDictionary<NSString *, NSNumber *> *)transferSnapshot;

@end

NS_ASSUME_NONNULL_END
