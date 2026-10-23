//
//  UpdaterRules.h
//  vibe-libs
//
//  The updater's decisions, over values only: the channels a check allows,
//  the check interval Sparkle's store means, and the feed's parameters.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A stable item carries no channel and always qualifies.
static inline NSSet<NSString *> *VibeUpdaterAllowedChannels(BOOL betaUpdates) {
    return betaUpdates ? [NSSet setWithObject:@"beta"] : [NSSet set];
}

// Sparkle keeps the interval while automatic checks are off, which read as 0.
static inline NSTimeInterval VibeUpdaterCheckInterval(BOOL automaticChecks, NSTimeInterval storedInterval) {
    return automaticChecks ? storedInterval : 0;
}

// The UTC day, ISO week, and month of date, in the order of the feed's period
// keys d, w, and m.
static inline NSArray<NSString *> *VibeUpdaterCheckPeriods(NSDate *date) {
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

// Appended to the feed URL at every check. Nothing here identifies the Mac.
// A period's flag goes with a copy's first check in it, so a site can count
// active copies without an identifier. reported is the periods of the last
// check whose feed loaded.
static inline NSArray<NSDictionary<NSString *, NSString *> *> *
VibeUpdaterFeedParameters(NSString *osVersion, NSString *architecture, BOOL betaUpdates, NSString *language,
                          NSArray<NSString *> *periods, NSArray *_Nullable reported) {
    NSString *const periodKeys[] = {@"d", @"w", @"m"};
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *parameters = [@[
        @{@"key": @"os", @"value": osVersion},
        @{@"key": @"arch", @"value": architecture},
        @{@"key": @"channel", @"value": betaUpdates ? @"beta" : @"stable"},
        @{@"key": @"lang", @"value": language},
    ] mutableCopy];
    for (NSUInteger i = 0; i < periods.count && i < sizeof(periodKeys) / sizeof(periodKeys[0]); i++) {
        if (i >= reported.count || ![reported[i] isEqual:periods[i]]) {
            [parameters addObject:@{@"key": periodKeys[i], @"value": @"1"}];
        }
    }
    return parameters;
}

NS_ASSUME_NONNULL_END
