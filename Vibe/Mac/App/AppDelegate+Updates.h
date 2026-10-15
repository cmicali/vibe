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
// stores it, started or not.
@property (nonatomic) NSTimeInterval updateCheckInterval;

// The updater controller, unstarted.
- (SPUStandardUpdaterController *)makeUpdaterController;

// Starts it, except in a Debug build launched without --update-feed.
- (void)startUpdaterIfConfigured;

@end

NS_ASSUME_NONNULL_END

#endif
