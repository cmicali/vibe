//
//  AppDelegate+Updates.m
//  Vibe
//

#if VIBE_DIRECT_DISTRIBUTION

#import "AppDelegate+Updates.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "SettingsRules.h"

@implementation AppDelegate (Updates)

#if DEBUG
// A Debug build checks only the feed this names, so the debug channel, stress
// runs and screenshots never raise an update dialog.
static NSString *DebugUpdateFeed(void) {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [args indexOfObject:@"--update-feed"];
    return index != NSNotFound && index + 1 < args.count ? args[index + 1] : nil;
}

- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater {
    return DebugUpdateFeed();
}
#endif

- (SPUStandardUpdaterController *)makeUpdaterController {
#if DEBUG
    if (!DebugUpdateFeed()) {
        return nil;
    }
#endif
    return [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO
                                                         updaterDelegate:self
                                                      userDriverDelegate:nil];
}

// Any other stored interval reads as the nearest preset.
- (NSTimeInterval)updateCheckInterval {
    SPUUpdater *updater = self.updaterController.updater;
    if (!updater.automaticallyChecksForUpdates) {
        return 0;
    }
    return VibeNearestPreset((NSInteger)updater.updateCheckInterval,
                             kVibeUpdateCheckIntervalPresets, kVibeUpdateCheckIntervalPresetCount);
}

- (void)setUpdateCheckInterval:(NSTimeInterval)interval {
    SPUUpdater *updater = self.updaterController.updater;
    updater.automaticallyChecksForUpdates = interval > 0;
    if (interval > 0) {
        updater.updateCheckInterval = interval;
    }
}

// Asked at every check. A stable item carries no channel and always qualifies.
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater {
    return AppSettings.sharedInstance.receiveBetaUpdates ? [NSSet setWithObject:@"beta"] : [NSSet set];
}

// The feed parameters for this check's UTC day, ISO week, and month, in the
// order UpdateCheckPeriods returns them.
static NSString *const kUpdateCheckPeriodKeys[] = {@"d", @"w", @"m"};
static NSString *const kReportedUpdateCheckPeriodsKey = @"VibeReportedUpdateCheckPeriods";
// The periods the check in flight reports. Its feed's load saves them. Sparkle
// calls its delegate on main, and the app runs one updater.
static NSArray<NSString *> *sPendingUpdateCheckPeriods;

static NSArray<NSString *> *UpdateCheckPeriods(NSDate *date) {
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierISO8601];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDateComponents *c = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                               NSCalendarUnitYearForWeekOfYear | NSCalendarUnitWeekOfYear
                                      fromDate:date];
    return @[
        [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)c.year, (long)c.month, (long)c.day],
        [NSString stringWithFormat:@"%04ld-W%02ld", (long)c.yearForWeekOfYear, (long)c.weekOfYear],
        [NSString stringWithFormat:@"%04ld-%02ld", (long)c.year, (long)c.month],
    ];
}

// Appended to the feed URL at every check, for the site's update-check counts
// (functions/appcast.xml.js). The app version is already in Sparkle's
// User-Agent. Nothing here identifies the Mac, and the privacy policy lists
// every key.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)feedParametersForUpdater:(SPUUpdater *)updater
                                                         sendingSystemProfile:(BOOL)sendingProfile {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
#if defined(__arm64__)
    NSString *arch = @"arm64";
#else
    NSString *arch = @"x86_64";
#endif
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *parameters = [@[
        @{@"key": @"os", @"value": [NSString stringWithFormat:@"%ld.%ld", (long)os.majorVersion, (long)os.minorVersion]},
        @{@"key": @"arch", @"value": arch},
        @{@"key": @"channel", @"value": AppSettings.sharedInstance.receiveBetaUpdates ? @"beta" : @"stable"},
        @{@"key": @"lang", @"value": NSBundle.mainBundle.preferredLocalizations.firstObject ?: @""},
    ] mutableCopy];
    // A period's flag goes with this copy's first check in it. The site counts
    // active copies from the flags, so no check needs an identifier.
    NSArray<NSString *> *periods = UpdateCheckPeriods(NSDate.date);
    NSArray *reported = [NSUserDefaults.standardUserDefaults arrayForKey:kReportedUpdateCheckPeriodsKey];
    for (NSUInteger i = 0; i < periods.count; i++) {
        if (i >= reported.count || ![reported[i] isEqual:periods[i]]) {
            [parameters addObject:@{@"key": kUpdateCheckPeriodKeys[i], @"value": @"1"}];
        }
    }
    sPendingUpdateCheckPeriods = periods;
    return parameters;
}

// Only a loaded feed uses up its periods. A check that fails offline flags
// them again on the next one.
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    if (sPendingUpdateCheckPeriods) {
        [NSUserDefaults.standardUserDefaults setObject:sPendingUpdateCheckPeriods
                                                forKey:kReportedUpdateCheckPeriodsKey];
        sPendingUpdateCheckPeriods = nil;
    }
}

@end

#endif
