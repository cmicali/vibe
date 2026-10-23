//
//  VibeUpdater.h
//  vibe-libs
//
//  Sparkle for a direct-download build: the standard updater controller, and
//  the updater's delegate. It is created unstarted, and the app starts it.
//

#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>

NS_ASSUME_NONNULL_BEGIN

@interface VibeUpdater : NSObject <SPUUpdaterDelegate>

// feedURLString replaces the Info.plist's SUFeedURL when it is not nil.
// betaUpdates is asked at every check, so a change needs no push.
- (instancetype)initWithFeedURLString:(nullable NSString *)feedURLString
                          betaUpdates:(BOOL (^)(void))betaUpdates NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// The target of Check for Updates…, which validates it. Unstarted, it
// refuses the check and logs.
@property (nonatomic, readonly) SPUStandardUpdaterController *controller;

// The automatic check interval in seconds, 0 for never. Sparkle stores it,
// started or not.
@property (nonatomic) NSTimeInterval checkInterval;

- (void)start;

@end

NS_ASSUME_NONNULL_END
