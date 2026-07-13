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
    // Hour-long files (DJ sets, live recordings) roll over to h:mm:ss instead
    // of showing "90:00". Separate pre-configured formatter so the sub-hour
    // rendering (m:ss, no leading zero-hours) stays exactly as it was.
    _hourTimeFormatter = [[NSDateComponentsFormatter alloc] init];
    _hourTimeFormatter.unitsStyle = NSDateComponentsFormatterUnitsStylePositional;
    _hourTimeFormatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    // DropLeading renders "1:30:00", not "01:30:00" (the hour is never zero
    // here — this formatter is only chosen for durations >= an hour).
    _hourTimeFormatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropLeading;
}

- (NSString *)durationStringFromTimeInterval:(NSTimeInterval)duration {
    if (isnan(duration) || duration < 0) {
        duration = 0;
    }
    NSDateComponentsFormatter *formatter = duration >= 3600 ? _hourTimeFormatter : _timeFormatter;
    NSString *result = [formatter stringFromTimeInterval:duration];
    return result ?: @"";
}

@end
