//
//  Formatters.m
//  Vibe
//

#import "Formatters.h"
#import "VibeStrings.h"


@implementation Formatters {
    NSTimeInterval _lastDurationSeconds;
    BOOL _lastDurationRemaining;
    NSString *_lastDurationText;
    NSDateComponentsFormatter *_timeFormatter;
    NSDateComponentsFormatter *_hourTimeFormatter;
    NSCache<NSNumber *, NSString *> *_timeStrings;
    NSDateComponentsFormatter *_spelledDurationFormatter;
    NSNumberFormatter         *_decimalFormatter;
    NSNumberFormatter         *_signedPercentFormatter;
    NSNumberFormatter         *_signedDecimalFormatter;
    NSNumberFormatter         *_percentFormatter;
    NSNumberFormatter         *_countFormatter;
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
    // A separate formatter for an hour or more, so sub-hour times stay m:ss.
    _hourTimeFormatter = [[NSDateComponentsFormatter alloc] init];
    _hourTimeFormatter.unitsStyle = NSDateComponentsFormatterUnitsStylePositional;
    _hourTimeFormatter.allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    // "1:30:00", not "01:30:00".
    _hourTimeFormatter.zeroFormattingBehavior = NSDateComponentsFormatterZeroFormattingBehaviorDropLeading;
    _timeStrings = [[NSCache alloc] init];
    _timeStrings.countLimit = 512;
    // A region change can move the digits without relaunching the app.
    NSCache *timeStrings = _timeStrings;
    [NSNotificationCenter.defaultCenter addObserverForName:NSCurrentLocaleDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) { [timeStrings removeAllObjects]; }];

    // Fraction digits are set per call. No grouping: small readouts (kHz, BPM).
    _decimalFormatter = [[NSNumberFormatter alloc] init];
    _decimalFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    _decimalFormatter.usesGroupingSeparator = NO;

    // Multiplier 1: the value is already a percentage. U+2212 matches the
    // fader's printed scale.
    _signedPercentFormatter = [[NSNumberFormatter alloc] init];
    _signedPercentFormatter.numberStyle = NSNumberFormatterPercentStyle;
    _signedPercentFormatter.multiplier = @1;
    _signedPercentFormatter.usesGroupingSeparator = NO;
    _signedPercentFormatter.minimumFractionDigits = 1;
    _signedPercentFormatter.maximumFractionDigits = 1;
    _signedPercentFormatter.positivePrefix = [@"+" stringByAppendingString:_signedPercentFormatter.positivePrefix ?: @""];
    _signedPercentFormatter.minusSign = @"−";

    _signedDecimalFormatter = [[NSNumberFormatter alloc] init];
    _signedDecimalFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    _signedDecimalFormatter.usesGroupingSeparator = NO;
    _signedDecimalFormatter.minimumFractionDigits = 0;
    _signedDecimalFormatter.maximumFractionDigits = 1;
    _signedDecimalFormatter.positivePrefix = [@"+" stringByAppendingString:_signedDecimalFormatter.positivePrefix ?: @""];
    _signedDecimalFormatter.minusSign = @"−";

    // Default multiplier: this one takes a 0-1 fraction.
    _percentFormatter = [[NSNumberFormatter alloc] init];
    _percentFormatter.numberStyle = NSNumberFormatterPercentStyle;
    _percentFormatter.maximumFractionDigits = 0;

    _countFormatter = [[NSNumberFormatter alloc] init];
    _countFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    _countFormatter.maximumFractionDigits = 0;

    _spelledDurationFormatter = [[NSDateComponentsFormatter alloc] init];
    _spelledDurationFormatter.unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
    _spelledDurationFormatter.allowedUnits = NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
    _spelledDurationFormatter.maximumUnitCount = 2;
}

- (NSString *)durationStringForFileDuration:(NSTimeInterval)duration rate:(double)rate
                         elapsedDisplayTime:(NSTimeInterval)elapsed remaining:(BOOL)remaining {
    NSTimeInterval value = duration / rate - (remaining ? elapsed : 0);
    if (!isfinite(value) || value < 0) value = 0;
    NSTimeInterval seconds = floor(value);
    if (!_lastDurationText || seconds != _lastDurationSeconds || remaining != _lastDurationRemaining) {
        NSString *text = [self durationStringFromTimeInterval:seconds];
        _lastDurationText = remaining ? [@"-" stringByAppendingString:text] : text;
        _lastDurationSeconds = seconds;
        _lastDurationRemaining = remaining;
    }
    return _lastDurationText;
}

- (NSString *)durationStringFromTimeInterval:(NSTimeInterval)duration {
    // stringFromTimeInterval: raises on a non-finite interval (a zero sample
    // rate, a failed open).
    if (!isfinite(duration) || duration < 0) {
        duration = 0;
    }
    // Keyed by the whole second, exact since both formatters truncate. The
    // labels ask on every tick and scrub frame, and the formatter was
    // two-thirds of the iOS player's tick.
    NSNumber *second = @(floor(duration));
    NSString *cached = [_timeStrings objectForKey:second];
    if (cached) {
        return cached;
    }
    NSDateComponentsFormatter *formatter = duration >= 3600 ? _hourTimeFormatter : _timeFormatter;
    NSString *result = [formatter stringFromTimeInterval:duration] ?: @"";
    [_timeStrings setObject:result forKey:second];
    return result;
}

- (NSString *)sampleRateString:(double)hertz {
    return [NSString stringWithFormat:STR_LABEL_SAMPLE_RATE, [self decimalString:hertz / 1000 fractionDigits:1]];
}

- (NSString *)bpmString:(double)bpm {
    return [NSString stringWithFormat:STR_LABEL_BPM, [self decimalString:bpm fractionDigits:1]];
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
    return [self signedString:percent with:_signedPercentFormatter];
}

- (NSString *)signedDecimalString:(double)value {
    return [self signedString:value with:_signedDecimalFormatter];
}

- (NSString *)signedString:(double)value with:(NSNumberFormatter *)formatter {
    if (isnan(value)) {
        value = 0;
    }
    // Zero is unsigned.
    if (value == 0) {
        NSString *zero = [formatter stringFromNumber:@0];
        if ([zero hasPrefix:@"+"]) {
            zero = [zero substringFromIndex:1];
        }
        return zero ?: @"";
    }
    return [formatter stringFromNumber:@(value)] ?: @"";
}

- (NSString *)percentString:(double)fraction {
    if (!isfinite(fraction)) {
        fraction = 0;
    }
    fraction = MAX(0.0, MIN(1.0, fraction));
    return [_percentFormatter stringFromNumber:@(fraction)] ?: @"";
}

- (NSString *)countString:(unsigned long long)count {
    return [_countFormatter stringFromNumber:@(count)] ?: @"";
}

- (NSString *)spelledDurationString:(NSTimeInterval)duration {
    if (!isfinite(duration) || duration < 0) {
        duration = 0;
    }
    return [_spelledDurationFormatter stringFromTimeInterval:duration] ?: @"";
}

@end
