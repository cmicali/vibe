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

@end

NS_ASSUME_NONNULL_END

#endif
