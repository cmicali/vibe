//
// The duration strings every time label renders through, and the
// locale-dependent number strings behind the kHz/BPM and pitch readouts.
//

#import <XCTest/XCTest.h>

#import "Formatters.h"

@interface FormattersTests : XCTestCase
@end

@implementation FormattersTests {
    Formatters *_formatters;
}

- (void)setUp {
    _formatters = [Formatters sharedInstance];
}

- (NSString *)stringFor:(NSTimeInterval)duration {
    return [_formatters durationStringFromTimeInterval:duration];
}

- (void)testSubMinuteDurationsKeepTheLeadingZeroMinute {
    XCTAssertEqualObjects([self stringFor:0], @"0:00");
    XCTAssertEqualObjects([self stringFor:9], @"0:09");
    XCTAssertEqualObjects([self stringFor:24], @"0:24");
    XCTAssertEqualObjects([self stringFor:59], @"0:59");
}

- (void)testMinutesAndSeconds {
    XCTAssertEqualObjects([self stringFor:60], @"1:00");
    XCTAssertEqualObjects([self stringFor:125], @"2:05");
    XCTAssertEqualObjects([self stringFor:599], @"9:59");
}

- (void)testSecondsAreTruncatedNotRounded {
    // The position label ticks with the playhead; rounding up would show a
    // second that hasn't happened yet.
    XCTAssertEqualObjects([self stringFor:24.9], @"0:24");
}

- (void)testHourLongFilesRollOverInsteadOfCountingMinutesForever {
    // DJ sets and live recordings: "90:00" is unreadable.
    XCTAssertEqualObjects([self stringFor:3599], @"59:59");
    XCTAssertEqualObjects([self stringFor:3600], @"1:00:00");
    XCTAssertEqualObjects([self stringFor:5400], @"1:30:00");
}

- (void)testTheHourIsNotZeroPadded {
    // DropLeading: "1:30:00", never "01:30:00".
    NSString *rendered = [self stringFor:5400];
    XCTAssertFalse([rendered hasPrefix:@"0"], @"got %@", rendered);
}

- (void)testDegenerateInputsRenderAsZeroRatherThanGarbage {
    // duration is -1 until the decode publishes a length, and a failed open
    // can leave it NaN; neither should reach the label as "-1:00" or "NaN".
    XCTAssertEqualObjects([self stringFor:NAN], @"0:00");
    XCTAssertEqualObjects([self stringFor:-1], @"0:00");
    XCTAssertEqualObjects([self stringFor:-3600], @"0:00");
}

- (void)testInfiniteDurationsAreSurvivable {
    // NSDateComponentsFormatter RAISES on a non-finite interval, so the guard
    // has to cover infinity (a zero sample rate) and not just NaN.
    XCTAssertEqualObjects([self stringFor:INFINITY], @"0:00");
    XCTAssertEqualObjects([self stringFor:-INFINITY], @"0:00");
}

- (void)testNeverReturnsNil {
    // The label binding has no nil branch.
    XCTAssertNotNil([self stringFor:0]);
    XCTAssertNotNil([self stringFor:5400]);
}

#pragma mark decimalString:fractionDigits:

// Formatters offers no locale injection — its NSNumberFormatters format in
// the machine's current locale — so exact expectations come from a reference
// formatter configured the same way, never from a hardcoded "." or ",". The
// suite must pass unchanged on a de_DE machine, where 44.1 renders "44,1".
- (NSNumberFormatter *)referenceDecimalFormatterWithFractionDigits:(NSInteger)digits {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.minimumFractionDigits = digits;
    formatter.maximumFractionDigits = digits;
    return formatter;
}

- (void)testDecimalStringPadsToTheRequestedFractionDigits {
    // The sample-rate readout renders 44 as "44.1"-shaped, never bare "44".
    XCTAssertEqualObjects([_formatters decimalString:44 fractionDigits:1],
                          [[self referenceDecimalFormatterWithFractionDigits:1] stringFromNumber:@44]);
    XCTAssertEqualObjects([_formatters decimalString:120 fractionDigits:2],
                          [[self referenceDecimalFormatterWithFractionDigits:2] stringFromNumber:@120]);
}

- (void)testDecimalStringRoundsToTheRequestedFractionDigits {
    XCTAssertEqualObjects([_formatters decimalString:44.16 fractionDigits:1],
                          [[self referenceDecimalFormatterWithFractionDigits:1] stringFromNumber:@44.16]);
    XCTAssertEqualObjects([_formatters decimalString:127.6 fractionDigits:0],
                          [[self referenceDecimalFormatterWithFractionDigits:0] stringFromNumber:@127.6]);
}

- (void)testDecimalStringUsesTheLocaleDecimalSeparator {
    // The point of routing through Formatters at all: "44.1" in en, "44,1"
    // in de, so assert the current locale's separator appears rather than ".".
    NSString *separator = [self referenceDecimalFormatterWithFractionDigits:1].decimalSeparator;
    XCTAssertTrue([[_formatters decimalString:44.1 fractionDigits:1] containsString:separator],
                  @"got %@", [_formatters decimalString:44.1 fractionDigits:1]);
}

- (void)testDecimalStringNeverGroups {
    // Small readouts (kHz, BPM): 44100 must not render "44,100" in en, which
    // would collide with de's decimal comma.
    NSNumberFormatter *grouped = [[NSNumberFormatter alloc] init];
    grouped.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *rendered = [_formatters decimalString:44100 fractionDigits:0];
    XCTAssertFalse([rendered containsString:grouped.groupingSeparator], @"got %@", rendered);
}

- (void)testDecimalStringNaNRendersAsZero {
    XCTAssertEqualObjects([_formatters decimalString:NAN fractionDigits:1],
                          [[self referenceDecimalFormatterWithFractionDigits:1] stringFromNumber:@0]);
}

#pragma mark signedPercentString:

- (void)testPositivePitchGetsAnExplicitPlus {
    // The pitch readout always shows direction: "+3.2%", never bare "3.2%".
    XCTAssertTrue([[_formatters signedPercentString:3.2] hasPrefix:@"+"],
                  @"got %@", [_formatters signedPercentString:3.2]);
}

- (void)testNegativePitchUsesTheTypographicMinus {
    // U+2212, matching the fader's printed scale; never the ASCII hyphen.
    NSString *rendered = [_formatters signedPercentString:-3.2];
    XCTAssertTrue([rendered containsString:@"−"], @"got %@", rendered);
    XCTAssertFalse([rendered containsString:@"-"], @"got %@", rendered);
    XCTAssertFalse([rendered containsString:@"+"], @"got %@", rendered);
}

- (void)testZeroPitchIsTheUnsignedNeutralState {
    NSString *rendered = [_formatters signedPercentString:0];
    XCTAssertFalse([rendered containsString:@"+"], @"got %@", rendered);
    XCTAssertFalse([rendered containsString:@"−"], @"got %@", rendered);
}

- (void)testNaNPitchRendersAsTheNeutralZero {
    XCTAssertEqualObjects([_formatters signedPercentString:NAN],
                          [_formatters signedPercentString:0]);
}

- (void)testPitchAlwaysShowsOneFractionDigit {
    // "+3.0%", not "+3%": the readout width stays stable while dragging.
    NSNumberFormatter *percent = [[NSNumberFormatter alloc] init];
    percent.numberStyle = NSNumberFormatterPercentStyle;
    NSString *separator = percent.decimalSeparator;
    NSString *rendered = [_formatters signedPercentString:3];
    NSString *expected = [NSString stringWithFormat:@"3%@0", separator];
    XCTAssertTrue([rendered containsString:expected], @"got %@", rendered);
}

@end
