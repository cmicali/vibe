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

@end

NS_ASSUME_NONNULL_END
