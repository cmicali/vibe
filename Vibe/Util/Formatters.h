//
//  Formatters.h
//  Vibe
//

#import <Foundation/Foundation.h>

// MAIN THREAD ONLY: NSDateComponentsFormatter (unlike NSDateFormatter) has no
// documented thread-safety guarantee.
@interface Formatters : NSObject

+ (Formatters *)sharedInstance;

- (NSString *)durationStringFromTimeInterval:(NSTimeInterval)duration;
// Total or remaining wall-clock duration; elapsed is already wall time.
// Invalid arithmetic displays zero.
- (NSString *)durationStringForFileDuration:(NSTimeInterval)duration rate:(double)rate
                         elapsedDisplayTime:(NSTimeInterval)elapsed remaining:(BOOL)remaining;

// Fixed-fraction decimal in the user's locale: "44.1" in en, "44,1" in de.
// Digits are clamped to 0–3.
- (NSString *)decimalString:(double)value fractionDigits:(NSInteger)digits;

// "44.1 kHz", per locale.
- (NSString *)sampleRateString:(double)hertz;
// "128.0 BPM": the tempo readout both platforms draw.
- (NSString *)bpmString:(double)bpm;

// The one join behind every info line: the non-empty fields, in order, with
// the " | " separator. Layout punctuation, not prose, so never localized.
- (NSString *)infoLineFromFields:(NSArray<NSString *> *)fields;
// "128.0 BPM | 8A", either alone, or empty. A bpm of 0 or less is no tempo.
// The key is always the LAST field: the mac colors it as the line's suffix.
- (NSString *)tempoLineWithBPM:(double)bpm keyText:(NSString *)keyText;

// The pitch readout: "+3.2%", "−3.2%" (U+2212), "0.0%", per locale.
- (NSString *)signedPercentString:(double)percent;

// The gain readout: "+3.5", "−6", "0".
- (NSString *)signedDecimalString:(double)value;

// A 0-1 fraction as a whole, unsigned percentage per locale, for spoken
// slider values; out-of-range input clamps.
- (NSString *)percentString:(double)fraction;

// Grouped: "1,234" in en, "1.234" in de.
- (NSString *)countString:(unsigned long long)count;

// At most two units, localized: "3 days, 4 hours".
- (NSString *)spelledDurationString:(NSTimeInterval)duration;

@end
