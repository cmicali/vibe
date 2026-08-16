//
//  DownloadProgressMonitor.h
//  Vibe
//
//  Best-effort download progress for a cloud file being materialized by its
//  file provider, feeding the loading indicator on both platforms: shimmer
//  while indeterminate, determinate fill when a fraction is known.
//
//  Two sources, best wins. Everywhere: the portable heuristic — poll the
//  dataless file's allocated size against its logical size, which works when
//  the provider materializes in place incrementally and degrades to
//  nothing-then-done when it stages and renames. macOS only: the File
//  Provider NSProgress publication (the mechanism behind Finder's pie
//  badges) via addSubscriberForFileURL: — exact when the provider publishes,
//  and it supersedes the poll. iOS has no consumer-side progress API for
//  third-party providers, so the poll is the whole story there.
//
//  MEASURED: both iCloud Drive and Dropbox stage the download out of line and
//  swap it in, so the allocated-size poll reads 0 for the whole transfer and
//  only ever reports the final step — the File Provider publication carries
//  the feature on macOS, and the poll is a floor for providers that
//  materialize in place. That publication lands about once a second, and
//  polling the proxy between firings returns the same value, so ~1 Hz is the
//  ceiling; the waveform eases between samples rather than snapping.
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
// and later cancel. currentURL and handler both run on the main thread.
+ (instancetype)monitorReplacing:(nullable DownloadProgressMonitor *)existing
                          forURL:(NSURL *)url
                      currentURL:(NSURL *_Nullable (^)(void))currentURL
                         handler:(void (^)(float fraction))handler;

@end

NS_ASSUME_NONNULL_END
