//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

// MAIN THREAD ONLY: NSDateComponentsFormatter (unlike NSDateFormatter) has no
// documented thread-safety guarantee.
@interface Formatters : NSObject

+ (Formatters *)sharedInstance;

- (NSString *)durationStringFromTimeInterval:(NSTimeInterval)duration;

// Fixed-fraction decimal in the user's locale: "44.1" in en, "44,1" in de.
- (NSString *)decimalString:(double)value fractionDigits:(NSInteger)digits;

// Signed percentage for the pitch readout ("+3.2%", "−3.2%", "0.0%"), placed
// per locale; the minus is U+2212, matching the fader's printed scale.
- (NSString *)signedPercentString:(double)percent;

// Grouped whole number for counts: "1,234" in en, "1.234" in de.
- (NSString *)countString:(unsigned long long)count;

// Elapsed time in words, at most two units — "3 days, 4 hours", "12 minutes,
// 5 seconds" — localized by NSDateComponentsFormatter.
- (NSString *)spelledDurationString:(NSTimeInterval)duration;

@end
