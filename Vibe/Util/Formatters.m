//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "Formatters.h"


@implementation Formatters {
    NSDateComponentsFormatter *_timeFormatter;
    NSDateComponentsFormatter *_hourTimeFormatter;
}

+ (Formatters*)sharedInstance {
    static Formatters *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[Formatters alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    _timeFormatter = [[NSDateComponentsFormatter alloc] init];
    _timeFormatter.unitsStyle = NSDateComponentsFormatterUnitsStylePositional;
    _timeFormatter.allowedUnits = NSCalendarUnitMinute | NSCalendarUnitSecond;
    _timeFormatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorNone;
    // Hour-long files, such as DJ sets and live recordings, roll over to
    // h:mm:ss rather than showing "90:00". A separate pre-configured formatter
    // keeps the sub-hour rendering — m:ss, with no leading zero hours —
    // exactly as it was.
    _hourTimeFormatter = [[NSDateComponentsFormatter alloc] init];
    _hourTimeFormatter.unitsStyle = NSDateComponentsFormatterUnitsStylePositional;
    _hourTimeFormatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    // DropLeading renders "1:30:00" rather than "01:30:00". The hour is never
    // zero here, because this formatter is chosen only for durations of an
    // hour or more.
    _hourTimeFormatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropLeading;
}

- (NSString *)durationStringFromTimeInterval:(NSTimeInterval)duration {
    // stringFromTimeInterval: raises on a non-finite interval, and infinity
    // reaches here from a zero sample rate the same way NaN reaches it from a
    // failed open — isfinite covers both, plus -infinity.
    if (!isfinite(duration) || duration < 0) {
        duration = 0;
    }
    NSDateComponentsFormatter *formatter = duration >= 3600 ? _hourTimeFormatter : _timeFormatter;
    NSString *result = [formatter stringFromTimeInterval:duration];
    return result ?: @"";
}

@end
