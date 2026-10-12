//
//  DownloadProgressMonitor+Debug.h
//  Vibe
//
//  A stand-in for the provider's progress reporting, so a stress run can drive
//  the loading indicator's determinate half with no file provider. VibeFakeCloud
//  is its only installer. This class keeps the tick, the whole-percent gate and
//  the cancel; which files and how far along belong to the installer.
//  Implemented in DownloadProgressMonitor.m (declaration-only, like
//  AudioPlayer+Debug.h).
//
//  TRAP: the fake REPLACES every real source rather than joining them. Under
//  the fake cloud the file on disk is genuinely local, so the allocated-size
//  poll would report a final 100% on its first tick and cancel the monitor
//  while the fake transfer still has seconds to run.
//

#if DEBUG

#import "DownloadProgressMonitor.h"

NS_ASSUME_NONNULL_BEGIN

// url's transfer fraction now, or negative for "not a fake" (at start, the
// real sources run instead). Main thread, once per tick.
typedef float (^VibeFakeDownloadProgress)(NSURL *url);

@interface DownloadProgressMonitor (Debug)

+ (void)setFakeProgressProvider:(nullable VibeFakeDownloadProgress)provider;

@end

NS_ASSUME_NONNULL_END

#endif
