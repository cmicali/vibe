//
//  CloudTransferRegistry.h
//  Vibe
//
//  The coordinator's publication surface for "which files are on the wire":
//  AudioFileMaterializationCoordinator publishes its startClaim:/finishClaim:
//  edges here, gated on the dataless probe, so a local file — whose run is a
//  stat and a no-op coordinated read — publishes nothing, and a claim merely
//  queued behind lane capacity publishes nothing either. Lane capacity
//  therefore bounds the indicators as well as the transfers: dropping a large
//  cloud folder marks the one to three files actually downloading and leaves
//  every other row its number.
//
//  Main thread only, like DownloadProgressMonitor and the delegate paths it
//  feeds. The registry names no rows and knows no UI; the observer re-reads
//  whatever rows it is showing.
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

// ONE weak observer, because each shell has exactly one row list
// (PlaylistController on macOS, LibraryViewController on iOS). A second
// observer means upgrading this to counted registration, not silently
// replacing whoever registered first.
@property (nonatomic, weak, nullable) id<CloudTransferRegistryObserver> observer;

// YES only while a provider transfer is running for url's standardized path.
- (BOOL)isTransferringURL:(NSURL *)url;

// <0 when the transfer is running but no fraction is known yet — which is the
// indeterminate case, and on iOS against a third-party provider is the whole
// story. See DownloadProgressMonitor.h for why. Also <0 when nothing is
// transferring at all; isTransferringURL: is the gate. A provider's zero
// sample is status rather than progress and never leaves indeterminate: the
// row shows a determinate fill only once real, non-zero movement arrives.
- (float)progressForURL:(NSURL *)url;

// The foreground open reports through the shell's OWN monitor, which is tied
// to the open-request identifier and also feeds the player's timeout
// extension. Routing that fraction in here stops the registry minting a
// second monitor — a second NSMetadataQuery and File Provider subscription —
// for a file already being watched.
- (void)noteProgress:(float)fraction forURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
