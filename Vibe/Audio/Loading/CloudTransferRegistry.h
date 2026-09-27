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

// The shell's own monitor for the foreground open feeds this, so the registry
// cancels its own and never watches that file twice.
- (void)noteProgress:(float)fraction forURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
