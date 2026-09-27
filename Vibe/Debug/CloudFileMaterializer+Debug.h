//
//  CloudFileMaterializer+Debug.h
//  Vibe
//
//  A stand-in transfer of a fixed duration, for stress runs with no file
//  provider in reach: materializeURL: waits instead of coordinating a read, and
//  -cancel cuts the wait short as it would a real one. It fakes the wait, not
//  the cancellation: what is under test is the app's download ordering, which
//  a real provider cannot exercise at a useful rate. VibeFakeCloud is the only
//  installer. Declaration-only, like AudioPlayer+Debug.h.
//

#if DEBUG

#import "CloudFileMaterializer.h"

NS_ASSUME_NONNULL_BEGIN

@interface CloudFileMaterializer (Debug)

// secondsForURL: each file's transfer time, per file so one can outlast a
// listener or trip the player's open timeout. 0 means the real path, so a
// mixed corpus needs no second switch; negative runs for the magnitude, then
// fails. It must answer 0 for a path whose transfer completed, because
// materializeURL: asks it ahead of the dataless probe, which is what keeps an
// unflagged-placeholder mode transferring files the probe disowns. role is the
// materializer's label: playback, prefetch or metadata.
//
// acquireSlot: blocks until the provider's shared slot is free, polling
// cancelled() so a queued transfer aborts as a running one does; returns
// whether it took the slot. releaseSlot carries the role so the installer can
// tell which of several transfers of one path ended. nil means unlimited.
//
// didFinish: once per fake transfer, on the materializing thread, including
// one cancelled while queued. completed means the file is now local and should
// stop answering the dataless probe; otherwise it stays a placeholder.
+ (void)setFakeTransferProvider:(nullable NSTimeInterval (^)(NSURL *url, NSString *role))secondsForURL
                    acquireSlot:(nullable BOOL (^)(NSURL *url, NSString *role, BOOL (^cancelled)(void)))acquireSlot
                    releaseSlot:(nullable void (^)(NSURL *url, NSString *role))releaseSlot
                      didFinish:(nullable void (^)(NSURL *url, NSString *role, BOOL completed))didFinish;

@end

NS_ASSUME_NONNULL_END

#endif
