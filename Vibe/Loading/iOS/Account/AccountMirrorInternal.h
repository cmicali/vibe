//
//  AccountMirrorInternal.h
//  Vibe (iOS)
//
//  What a service's mirror shares with the base past the shell's calls: the
//  directory helpers, the end of a listing, and the hooks it overrides.
//

#import "AccountMirror.h"
#import "RemotePlaceholderStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

@interface AccountMirror ()

// The disk queue. A directory at url, made when missing; a file in the way
// is replaced.
- (void)ensureDirectoryAtURL:(NSURL *)url;

// The disk queue, at the end of a listing's reconcile: removes each name in
// `existing` that is not in `kept` (a departed file or folder), and each
// hidden part file a dead process left. Answers whether downloaded bytes
// went with them.
- (BOOL)removeDepartedIn:(NSURL *)directory
                existing:(NSArray<NSString *> *)existing
                    kept:(NSSet<NSString *> *)kept;

// The disk queue, last in a listing: reports the downloads' new total when
// bytes were discarded, downloads the playlist files (the target the client
// downloads, by the URL it is installed at) side by side off the disk queue,
// then completes on main with the directory.
- (void)finishListingOfDirectory:(NSURL *)directory
                        sidecars:(NSDictionary<NSURL *, id> *)sidecars
                       discarded:(BOOL)discarded
                      completion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
