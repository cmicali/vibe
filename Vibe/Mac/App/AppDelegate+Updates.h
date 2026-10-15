//
//  AppDelegate+Updates.h
//  Vibe
//
//  Sparkle, the direct download's updater (Mac/App/AGENTS.md, Updates).
//

#if VIBE_DIRECT_DISTRIBUTION

#import "AppDelegate.h"
#import <Sparkle/Sparkle.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppDelegate (Updates) <SPUUpdaterDelegate>

// Settings > General's check frequency in seconds, 0 for never. Sparkle
// stores it. While no updater runs (a Debug build launched without
// --update-feed) it is a stub that round-trips and checks nothing, so the
// rows stay testable.
@property (nonatomic) NSTimeInterval updateCheckInterval;

// The updater controller, unstarted. nil in a Debug build launched without
// --update-feed.
- (nullable SPUStandardUpdaterController *)makeUpdaterController;

@end

NS_ASSUME_NONNULL_END

#endif
