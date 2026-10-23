//
//  VibeUpdater.m
//  vibe-libs
//

#import "VibeUpdater.h"
#import "UpdaterRules.h"

static NSString *const kReportedCheckPeriodsKey = @"VibeReportedUpdateCheckPeriods";

@implementation VibeUpdater {
    NSString *_feedURLString;
    BOOL (^_betaUpdates)(void);
    // The periods the check in flight reports. Its feed's load saves them.
    // Sparkle calls its delegate on main.
    NSArray<NSString *> *_pendingCheckPeriods;
}

- (instancetype)initWithFeedURLString:(NSString *)feedURLString betaUpdates:(BOOL (^)(void))betaUpdates {
    if ((self = [super init])) {
        _feedURLString = [feedURLString copy];
        _betaUpdates = [betaUpdates copy];
        _controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO
                                                                    updaterDelegate:self
                                                                 userDriverDelegate:nil];
    }
    return self;
}

// An unstarted updater still stores its settings, so an app's settings rows
// read and write the real ones, and a check it is asked for logs and does
// nothing.
- (void)start {
    [_controller startUpdater];
}

- (NSTimeInterval)checkInterval {
    SPUUpdater *updater = _controller.updater;
    return VibeUpdaterCheckInterval(updater.automaticallyChecksForUpdates, updater.updateCheckInterval);
}

- (void)setCheckInterval:(NSTimeInterval)interval {
    SPUUpdater *updater = _controller.updater;
    updater.automaticallyChecksForUpdates = interval > 0;
    if (interval > 0) {
        updater.updateCheckInterval = interval;
    }
}

// nil keeps the Info.plist's feed.
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater {
    return _feedURLString;
}

// Asked at every check.
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater {
    return VibeUpdaterAllowedChannels(_betaUpdates());
}

// The app version is already in Sparkle's User-Agent.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)feedParametersForUpdater:(SPUUpdater *)updater
                                                         sendingSystemProfile:(BOOL)sendingProfile {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
#if defined(__arm64__)
    NSString *architecture = @"arm64";
#else
    NSString *architecture = @"x86_64";
#endif
    NSArray<NSString *> *periods = VibeUpdaterCheckPeriods(NSDate.date);
    _pendingCheckPeriods = periods;
    return VibeUpdaterFeedParameters([NSString stringWithFormat:@"%ld.%ld", (long)os.majorVersion,
                                                                (long)os.minorVersion],
                                     architecture, _betaUpdates(),
                                     NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"", periods,
                                     [NSUserDefaults.standardUserDefaults arrayForKey:kReportedCheckPeriodsKey]);
}

// Only a loaded feed uses up its periods. A check that fails offline flags
// them again on the next one.
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    if (_pendingCheckPeriods) {
        [NSUserDefaults.standardUserDefaults setObject:_pendingCheckPeriods forKey:kReportedCheckPeriodsKey];
        _pendingCheckPeriods = nil;
    }
}

@end
