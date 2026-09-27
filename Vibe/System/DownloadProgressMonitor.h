//
//  DownloadProgressMonitor.h
//  Vibe
//
//  Best-effort progress for a file its provider is materializing: shimmer
//  while indeterminate, a fill once a fraction is known.
//
//  Three sources, best wins: a poll of allocated against logical size
//  (everywhere); iCloud's NSMetadataQuery percentDownloaded (both platforms);
//  the File Provider NSProgress publication via addSubscriberForFileURL:
//  (macOS, exact, about 1 Hz).
//
//  Measured: iCloud Drive and Dropbox stage the download and swap it in, so
//  the poll reads 0 until the last step (an iPhone against Dropbox: dataless,
//  0 allocated, for all 9 s of a 66 MB file). A third-party provider on iOS
//  therefore shows only the shimmer, a platform limit: addSubscriberForFileURL:
//  is unavailable on iOS, NSFileProviderItem has no percentage (and its
//  download flags are ignored for replicated extensions), and
//  globalProgressForKind: needs the provider's own domain. Do not go looking
//  for a consumer-side File Provider progress API again.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DownloadProgressMonitor : NSObject

// Cancels `existing` and observes url until cancelled or materialized,
// delivering only while currentURL still answers url: a monitor outlives fast
// track changes. Never triggers the download. Main thread only; every block
// runs there.
//
// handler gets [0, 1] in whole-percent steps, a final 1.0 on completion, and
// nothing after cancel. movement is the uncoalesced liveness feed for the
// open's abandon deadline: any finite, strictly positive raw increase
// (VibeDownloadProgressIsMovement). Nil when the caller only paints.
+ (instancetype)monitorReplacing:(nullable DownloadProgressMonitor *)existing
                          forURL:(NSURL *)url
                      currentURL:(NSURL *_Nullable (^)(void))currentURL
                        movement:(nullable void (^)(void))movement
                         handler:(void (^)(float fraction))handler;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
