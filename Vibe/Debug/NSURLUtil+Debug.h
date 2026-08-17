//
//  NSURLUtil+Debug.h
//  Vibe
//
//  The dataless probe: makes chosen files answer isDatalessFile: as
//  placeholders, so a stress run can drive the cloud lane with no file
//  provider anywhere in reach. See VibeFakeCloud, its only installer.
//
//  It has to be injected rather than staged on disk. SF_DATALESS belongs to
//  the dataless-file machinery and cannot be set by hand, and a file that
//  merely carried the flag would not block on read anyway — so there is no way
//  to make a real file behave like a placeholder.
//
//  Same installed-block shape as NSURLUtil's own handlers, and for the same
//  reason: that layer stays testable and knows nothing about who installed
//  this. Unset — always, in a shipping build — means the real test.
//
//  Declaration-only, like AudioPlayer+Debug.h: the implementation stays in
//  NSURLUtil.m, which is what keeps the shipping header free of #if DEBUG.
//
//  Debug builds only, like everything in this directory.
//

#if DEBUG

#import "NSURLUtil.h"

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^VibeDatalessProbe)(NSURL *url);

@interface NSURLUtil (Debug)

+ (void)setDatalessProbe:(nullable VibeDatalessProbe)probe;

// The lane-routing measurement, for a REAL provider: while enabled, every
// stat the dataless test performs records its directory, its verdict, and the
// raw st_flags, bounded per run. This is how an unflagged provider — the
// shape NSURLUtil.m's comment predicts — is confirmed or ruled out against
// iCloud Drive or whatever provider a report names, without instrumenting a
// release. It records nothing while the fake probe is installed, since a
// fake's answers say nothing about the kernel flag. Enabling resets what was
// recorded. Off by default; the stat path pays nothing until it is turned on.
+ (void)setDatalessDiagnosticsEnabled:(BOOL)enabled;
+ (NSDictionary *)datalessDiagnostics;

@end

NS_ASSUME_NONNULL_END

#endif
