//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "Formatters.h"


@implementation Formatters {
    NSDateComponentsFormatter *_timeFormatter;
    NSDateComponentsFormatter *_hourTimeFormatter;
    NSNumberFormatter         *_decimalFormatter;
    NSNumberFormatter         *_signedPercentFormatter;
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

    // Fraction digits are set per call. No grouping: small readouts (kHz, BPM).
    _decimalFormatter = [[NSNumberFormatter alloc] init];
    _decimalFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    _decimalFormatter.usesGroupingSeparator = NO;

    // Multiplier 1: the value is already a percentage — percent style only
    // places the % symbol per locale. minusSign matches the U+2212 on the fader.
    _signedPercentFormatter = [[NSNumberFormatter alloc] init];
    _signedPercentFormatter.numberStyle = NSNumberFormatterPercentStyle;
    _signedPercentFormatter.multiplier = @1;
    _signedPercentFormatter.usesGroupingSeparator = NO;
    _signedPercentFormatter.minimumFractionDigits = 1;
    _signedPercentFormatter.maximumFractionDigits = 1;
    _signedPercentFormatter.positivePrefix = [@"+" stringByAppendingString:_signedPercentFormatter.positivePrefix ?: @""];
    _signedPercentFormatter.minusSign = @"−";
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

- (NSString *)decimalString:(double)value fractionDigits:(NSInteger)digits {
    if (isnan(value)) {
        value = 0;
    }
    _decimalFormatter.minimumFractionDigits = digits;
    _decimalFormatter.maximumFractionDigits = digits;
    return [_decimalFormatter stringFromNumber:@(value)] ?: @"";
}

- (NSString *)signedPercentString:(double)percent {
    if (isnan(percent)) {
        percent = 0;
    }
    // Exact zero reads "0.0%" with no sign — the readout's neutral state.
    if (percent == 0) {
        NSString *zero = [_signedPercentFormatter stringFromNumber:@0];
        if ([zero hasPrefix:@"+"]) {
            zero = [zero substringFromIndex:1];
        }
        return zero ?: @"";
    }
    return [_signedPercentFormatter stringFromNumber:@(percent)] ?: @"";
}

@end
