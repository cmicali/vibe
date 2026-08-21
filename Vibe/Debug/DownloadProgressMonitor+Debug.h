//
//  DownloadProgressMonitor+Debug.h
//  Vibe
//
//  A stand-in for the provider's own progress reporting, so a stress run can
//  drive the loading indicator's DETERMINATE half — the fill, its easing
//  between samples, and a stall — with no file provider in reach. See
//  VibeFakeCloud, its only installer.
//
//  TRAP: the fake REPLACES all three real sources rather than joining them.
//  Under the fake cloud the file on disk is genuinely local, so the
//  allocated-size poll finds SF_DATALESS down and every block present and
//  reports a final 100% on its first tick, 0.0s in — a full fill and a
//  self-cancelled monitor while the fake transfer still has seconds to run.
//  Nothing about the determinate half can be observed until the poll is out of
//  the way.
//
//  The division is CloudFileMaterializer+Debug.h's: this class keeps the tick,
//  the whole-percent gate and the cancel; WHICH files and HOW FAR ALONG belong
//  to the installer. A negative answer means "no transfer of ours in flight",
//  which is also how a mixed corpus works without a second switch.
//
//  Declaration-only, like AudioPlayer+Debug.h: the implementation stays in
//  DownloadProgressMonitor.m, beside the timer and cancel path it cooperates
//  with, and that is what keeps the shipping header free of #if DEBUG.
//
//  Debug builds only, like everything in this directory.
//

#if DEBUG

#import "DownloadProgressMonitor.h"

NS_ASSUME_NONNULL_BEGIN

// The fraction url's transfer has reached right now, or any negative value for
// "not a fake at all". Called on the main thread, once per tick.
typedef float (^VibeFakeDownloadProgress)(NSURL *url);

@interface DownloadProgressMonitor (Debug)

+ (void)setFakeProgressProvider:(nullable VibeFakeDownloadProgress)provider;

@end

NS_ASSUME_NONNULL_END

#endif
