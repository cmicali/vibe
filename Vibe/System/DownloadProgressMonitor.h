//
//  DownloadProgressMonitor.h
//  Vibe
//
//  Best-effort download progress for a cloud file being materialized by its
//  file provider, feeding the loading indicator on both platforms: shimmer
//  while indeterminate, determinate fill when a fraction is known.
//
//  Three sources, best wins. Everywhere: the portable heuristic — poll the
//  dataless file's allocated size against its logical size, which works when
//  the provider materializes in place incrementally and degrades to
//  nothing-then-done when it stages and renames. iCloud only, both platforms:
//  NSMetadataQuery's percentDownloaded, the one cloud whose transfer the
//  system reports to a consuming app, which supersedes the poll when it
//  answers. macOS only: the File Provider NSProgress publication (the
//  mechanism behind Finder's pie badges) via addSubscriberForFileURL: — exact
//  when the provider publishes, and it supersedes both. A third-party
//  provider on iOS has none of the above beyond the poll.
//
//  MEASURED: both iCloud Drive and Dropbox stage the download out of line and
//  swap it in, so the allocated-size poll reads 0 for the whole transfer and
//  only ever reports the final step — the File Provider publication carries
//  the feature on macOS, and the poll is a floor for providers that
//  materialize in place. That publication lands about once a second, and
//  polling the proxy between firings returns the same value, so ~1 Hz is the
//  ceiling; the waveform eases between samples rather than snapping.
//
//  Which means a THIRD-PARTY provider on iOS reports no fraction at all, and
//  that is a platform limit rather than a gap here. There is no consumer-side
//  progress API: +addSubscriberForFileURL: is API_UNAVAILABLE(ios),
//  NSFileProviderItem exposes isDownloading/isDownloaded and no percentage —
//  and even those are documented as ignored for a replicated extension, which
//  is what a modern provider is — and NSFileProviderManager's
//  globalProgressForKind: needs a domain only the provider's own app can get.
//  A replicated extension also fetches into its own temp file and has the
//  system swap it in, which is exactly what the measurement above found and
//  what the poll cannot see. MEASURED on an iPhone against Dropbox: dataless=1
//  with allocated=0 for the whole 9s of a 66MB file, then complete in one
//  step. So expect the indeterminate shimmer there, and keep it honest: the
//  poll reports a fraction only when it has a positive one to report, and it
//  never infers "materialized" from a clear SF_DATALESS alone.
//
//  Do not go looking for a generic File Provider progress API again. iCloud's
//  NSMetadataQuery percentage above is the exception that exists, and it is
//  already taken.
//
//  The handler is the app's one download-progress spout: a future Dropbox
//  API client reports through the same shape.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DownloadProgressMonitor : NSObject

// Observes url until cancelled or the file is fully materialized. The
// monitor never triggers the download itself — the player's open does that.
// handler runs on the main thread with fraction in [0, 1]; it fires only
// when the value moves by at least a percent, and a final 1.0 fires when
// materialization completes. Never fires after cancel. Main thread only,
// like the delegate paths it feeds.
- (instancetype)initWithURL:(NSURL *)url;
- (void)startWithHandler:(void (^)(float fraction))handler;
- (void)cancel;

// The one way a screen starts one, because the guard below is the part both
// were restating. It cancels `existing`, starts a fresh monitor for url, and
// delivers a fraction ONLY while currentURL still answers url — a monitor
// outlives fast track changes, so a late sample would otherwise paint the
// wrong track's loading bar. Returns the new monitor for the caller to hold
// and later cancel. currentURL, movement, and handler all run on the main
// thread.
//
// movement is the UNCOALESCED liveness feed: it fires on any finite, strictly
// positive increase in the raw fraction, before the whole-percent gate the
// fraction handler rides. Initial zero, repeated, backward, negative and NaN
// samples are status, stalls or invalid — never movement. The open's abandon
// deadline eats this stream, never the gated one. Nil when the caller only
// paints.
+ (instancetype)monitorReplacing:(nullable DownloadProgressMonitor *)existing
                          forURL:(NSURL *)url
                      currentURL:(NSURL *_Nullable (^)(void))currentURL
                        movement:(nullable void (^)(void))movement
                         handler:(void (^)(float fraction))handler;

@end

NS_ASSUME_NONNULL_END
