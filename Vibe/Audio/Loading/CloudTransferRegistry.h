//
//  CloudTransferRegistry.h
//  Vibe
//
//  Which files are on the wire. AudioFileMaterializationCoordinator publishes
//  begin/end only when its accepted classification says the file is dataless;
//  a local file and a claim queued behind lane capacity publish nothing, so
//  the lanes bound the row indicators as they bound the transfers.
//
//  Main thread only. The registry names no rows; the observer re-reads the
//  rows it shows.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CloudTransferRegistry;

@protocol CloudTransferRegistryObserver <NSObject>
// One coalesced callback per runloop turn, on main.
- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry;
@end

@interface CloudTransferRegistry : NSObject

+ (instancetype)sharedRegistry;

// One observer: each shell has one row list (PlaylistController on macOS,
// LibraryViewController on iOS). A second needs counted registration, not
// replacement.
@property (nonatomic, weak, nullable) id<CloudTransferRegistryObserver> observer;

// YES only while a provider transfer is running for url's standardized path.
- (BOOL)isTransferringURL:(NSURL *)url;

// <0 while no fraction is known (always, on iOS against a third-party
// provider; DownloadProgressMonitor.h) and when nothing is transferring;
// isTransferringURL: is the gate. A zero sample stays indeterminate.
- (float)progressForURL:(NSURL *)url;

// The shell declares the file its own monitor watches, before building that
// monitor, and releases it where it tears the monitor down. While declared the
// registry runs no monitor for that path, across a readmitted run's end and
// begin too, so no file is watched twice. One slot: each shell has one
// monitor. A second declarer needs counted registration, not replacement.
- (void)beginExternalProgressForURL:(NSURL *)url;
- (void)endExternalProgress;

// The declared file's fraction; any other URL's is dropped.
- (void)noteProgress:(float)fraction forURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
