//
//  CloudTransferRegistry.h
//  Vibe
//
//  Which files are on the wire, and how far each has come: the one home of
//  "this file is loading". AudioFileMaterializationCoordinator publishes
//  begin/end only when its accepted classification says the file is dataless;
//  a local file and a claim queued behind lane capacity publish nothing, so
//  the lanes bound the row indicators as they bound the transfers.
//
//  TRAP: each transfer has one DownloadProgressMonitor, the registry's own,
//  and every reader (rows, the playing track's loading fill, the open
//  deadline) observes it. A consumer's own monitor on the playing file means
//  the registry standing aside for it, and a stream starts long before its
//  download ends, so ending that monitor at the start freezes the playing
//  row's fraction for the rest of the download.
//
//  Main thread only. The registry names no rows; an observer re-reads what it
//  shows.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class CloudTransferRegistry;

@protocol CloudTransferRegistryObserver <NSObject>
// One coalesced callback per runloop turn, on main, for any begin, end or
// change of a shown fraction.
- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry;
@optional
// A transfer moved: any finite, strictly positive raw increase, uncoalesced,
// for the player's open deadline (noteOpenProgressForOpenRequestIdentifier:),
// never for painting. path is the transfer's key, its
// VibeStandardizedAudioOpenPath.
- (void)cloudTransferRegistry:(CloudTransferRegistry *)registry didMoveTransferForPath:(NSString *)path;
@end

@interface CloudTransferRegistry : NSObject

+ (instancetype)sharedRegistry;

// Weak; each shell has its row list and its player model.
- (void)addObserver:(id<CloudTransferRegistryObserver>)observer;
- (void)removeObserver:(id<CloudTransferRegistryObserver>)observer;

// YES only while a transfer is running for url's standardized path.
- (BOOL)isTransferringURL:(NSURL *)url;

// <0 while no fraction is known (always, on iOS against a third-party
// provider; DownloadProgressMonitor.h) and when nothing is transferring;
// isTransferringURL: is the gate. A zero sample stays indeterminate.
- (float)progressForURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
