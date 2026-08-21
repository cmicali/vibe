//
//  CloudFileMaterializer+Debug.h
//  Vibe
//
//  A stand-in transfer of a fixed duration, for stress runs with no file
//  provider in reach: materializeURL: waits that long instead of coordinating
//  a read, and -cancel cuts the wait short exactly as it cuts a real one
//  short. Zero — the default, and the only value a shipping build can have —
//  restores the real path. See VibeFakeCloud, its only installer.
//
//  It fakes the WAIT, deliberately, and not the cancellation. What is under
//  test is this app's ordering — which download runs next, which is abandoned,
//  what is re-queued — and that cannot be exercised at any useful rate against
//  a real provider. NSFileCoordinator's own semantics are Apple's, and are
//  exercised on a device instead.
//
//  Declaration-only, like AudioPlayer+Debug.h: the implementation stays in
//  CloudFileMaterializer.m, beside the cancel path it has to cooperate with,
//  and that is what keeps the shipping header free of #if DEBUG.
//
//  Debug builds only, like everything in this directory.
//

#if DEBUG

#import "CloudFileMaterializer.h"

NS_ASSUME_NONNULL_BEGIN

@interface CloudFileMaterializer (Debug)

// secondsForURL decides each file's transfer on its own — real folders are not
// uniform, and a fake that is cannot reach the cases that matter: a file slow
// enough to outlast a listener's patience, or one so slow it trips the player's
// open timeout. Returning 0 for a URL means "not a fake at all", so a mixed
// corpus works without a second switch. It must answer 0 for a path whose
// transfer already completed, because materializeURL: asks it AHEAD of the
// dataless probe — that ordering is what lets an unflagged-placeholder mode
// keep transferring files the probe disowns. This class keeps only the wait
// and the cancel; every question of WHICH files and HOW LONG belongs to the
// installer.
//
// role is the materializer's label — which caller's transfer this is — so the
// installer's trace can tell playback from prefetch from metadata.
//
// acquireSlot models the provider's scarce transfer capacity: it blocks until
// the shared slot is free, polling cancelled() to abort a queued transfer the
// way -cancel aborts a running one, and returns whether the slot was taken.
// releaseSlot returns it, and carries the same role so the installer can tell
// WHICH of several transfers of one path ended. Nil means unlimited capacity.
//
// didFinish fires once per fake transfer, on the materializing thread, saying
// which way it ended: completed means the file is now "local" and should stop
// answering the dataless probe, cancelled means it is still a placeholder —
// the same two outcomes a real one has. It fires for a transfer cancelled
// while still queued for the slot, too.
+ (void)setFakeTransferProvider:(nullable NSTimeInterval (^)(NSURL *url, NSString *role))secondsForURL
                    acquireSlot:(nullable BOOL (^)(NSURL *url, NSString *role, BOOL (^cancelled)(void)))acquireSlot
                    releaseSlot:(nullable void (^)(NSURL *url, NSString *role))releaseSlot
                      didFinish:(nullable void (^)(NSURL *url, NSString *role, BOOL completed))didFinish;

@end

NS_ASSUME_NONNULL_END

#endif
