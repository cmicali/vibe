//
// Musical key: Camelot/name formatting and tag-string parsing.
//

#import <XCTest/XCTest.h>

#import "MusicalKey.h"

@interface MusicalKeyTests : XCTestCase
@end

@implementation MusicalKeyTests

#pragma mark - Representation

- (void)testValidity {
    XCTAssertFalse(VibeMusicalKeyIsValid(VibeMusicalKeyNone));
    XCTAssertFalse(VibeMusicalKeyIsValid(24));
    XCTAssertTrue(VibeMusicalKeyIsValid(0));
    XCTAssertTrue(VibeMusicalKeyIsValid(23));
}

- (void)testMakeAndAccessors {
    VibeMusicalKey am = VibeMusicalKeyMake(9, YES);
    XCTAssertTrue(VibeMusicalKeyIsMinor(am));
    XCTAssertEqual(VibeMusicalKeyPitchClass(am), 9);
    VibeMusicalKey c = VibeMusicalKeyMake(0, NO);
    XCTAssertFalse(VibeMusicalKeyIsMinor(c));
    XCTAssertEqual(VibeMusicalKeyPitchClass(c), 0);
    XCTAssertEqual(VibeMusicalKeyMake(12, NO), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyMake(-1, YES), VibeMusicalKeyNone);
}

#pragma mark - Camelot wheel

- (void)testCamelotWheelKnownPositions {
    XCTAssertEqualObjects(VibeMusicalKeyCamelotName(VibeMusicalKeyMake(9, YES)), @"8A");  // Am
    XCTAssertEqualObjects(VibeMusicalKeyCamelotName(VibeMusicalKeyMake(0, NO)), @"8B");   // C
    XCTAssertEqualObjects(VibeMusicalKeyCamelotName(VibeMusicalKeyMake(8, YES)), @"1A");  // Abm
    XCTAssertEqualObjects(VibeMusicalKeyCamelotName(VibeMusicalKeyMake(11, NO)), @"1B");  // B
    XCTAssertEqualObjects(VibeMusicalKeyCamelotName(VibeMusicalKeyMake(6, YES)), @"11A"); // F#m
    XCTAssertEqualObjects(VibeMusicalKeyCamelotName(VibeMusicalKeyMake(4, NO)), @"12B");  // E
    XCTAssertEqualObjects(VibeMusicalKeyCamelotName(VibeMusicalKeyNone), @"");
}

- (void)testCamelotNeighborsAreFifths {
    // Adjacent numbers on a ring are a perfect fifth (7 semitones) apart —
    // the property harmonic mixing relies on. Verify around both rings.
    for (NSInteger pc = 0; pc < 12; pc++) {
        for (int minor = 0; minor <= 1; minor++) {
            VibeMusicalKey key = VibeMusicalKeyMake(pc, minor);
            VibeMusicalKey fifth = VibeMusicalKeyMake((pc + 7) % 12, minor);
            NSInteger n = VibeMusicalKeyCamelotNumber(key);
            NSInteger next = VibeMusicalKeyCamelotNumber(fifth);
            XCTAssertEqual(next, n % 12 + 1, @"pc %ld minor %d", (long)pc, minor);
        }
    }
}

- (void)testRelativeKeysShareCamelotNumber {
    // Am is the relative minor of C: same wheel number, different ring.
    XCTAssertEqual(VibeMusicalKeyCamelotNumber(VibeMusicalKeyMake(9, YES)),
                   VibeMusicalKeyCamelotNumber(VibeMusicalKeyMake(0, NO)));
    XCTAssertEqual(VibeMusicalKeyCamelotNumber(VibeMusicalKeyMake(6, YES)),
                   VibeMusicalKeyCamelotNumber(VibeMusicalKeyMake(9, NO)));
}

#pragma mark - Musical names

- (void)testMusicalNames {
    XCTAssertEqualObjects(VibeMusicalKeyMusicalName(VibeMusicalKeyMake(9, YES)), @"Am");
    XCTAssertEqualObjects(VibeMusicalKeyMusicalName(VibeMusicalKeyMake(0, NO)), @"C");
    XCTAssertEqualObjects(VibeMusicalKeyMusicalName(VibeMusicalKeyMake(1, NO)), @"Db");
    XCTAssertEqualObjects(VibeMusicalKeyMusicalName(VibeMusicalKeyMake(1, YES)), @"C#m");
    XCTAssertEqualObjects(VibeMusicalKeyMusicalName(VibeMusicalKeyMake(10, YES)), @"Bbm");
    XCTAssertEqualObjects(VibeMusicalKeyMusicalName(VibeMusicalKeyNone), @"");
}

#pragma mark - Parsing musical names

- (void)testParsePlainNames {
    XCTAssertEqual(VibeMusicalKeyFromString(@"Am"), VibeMusicalKeyMake(9, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"C"), VibeMusicalKeyMake(0, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"F#m"), VibeMusicalKeyMake(6, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"Bb"), VibeMusicalKeyMake(10, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"Ebm"), VibeMusicalKeyMake(3, YES));
}

- (void)testParseVerboseAndSpacedNames {
    XCTAssertEqual(VibeMusicalKeyFromString(@"A minor"), VibeMusicalKeyMake(9, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"A Major"), VibeMusicalKeyMake(9, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"Cmaj"), VibeMusicalKeyMake(0, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"F# min"), VibeMusicalKeyMake(6, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"  Gm  "), VibeMusicalKeyMake(7, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"d-moll"), VibeMusicalKeyMake(2, YES));
}

- (void)testParseUnicodeAccidentalsAndGermanH {
    XCTAssertEqual(VibeMusicalKeyFromString(@"F♯m"), VibeMusicalKeyMake(6, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"B♭"), VibeMusicalKeyMake(10, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"H"), VibeMusicalKeyMake(11, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"Hm"), VibeMusicalKeyMake(11, YES));
}

- (void)testParseEnharmonicSpellingsAgree {
    XCTAssertEqual(VibeMusicalKeyFromString(@"C#m"), VibeMusicalKeyFromString(@"Dbm"));
    XCTAssertEqual(VibeMusicalKeyFromString(@"G#m"), VibeMusicalKeyFromString(@"Abm"));
    XCTAssertEqual(VibeMusicalKeyFromString(@"F#"), VibeMusicalKeyFromString(@"Gb"));
}

#pragma mark - Parsing Camelot and Open Key

- (void)testParseCamelot {
    XCTAssertEqual(VibeMusicalKeyFromString(@"8A"), VibeMusicalKeyMake(9, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"8B"), VibeMusicalKeyMake(0, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"08a"), VibeMusicalKeyMake(9, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"12A"), VibeMusicalKeyMake(1, YES));
    XCTAssertEqual(VibeMusicalKeyFromString(@"1B"), VibeMusicalKeyMake(11, NO));
    XCTAssertEqual(VibeMusicalKeyFromString(@"13A"), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"0A"), VibeMusicalKeyNone);
}

- (void)testParseOpenKey {
    XCTAssertEqual(VibeMusicalKeyFromString(@"1d"), VibeMusicalKeyMake(0, NO));  // C
    XCTAssertEqual(VibeMusicalKeyFromString(@"1m"), VibeMusicalKeyMake(9, YES)); // Am
    XCTAssertEqual(VibeMusicalKeyFromString(@"7d"), VibeMusicalKeyMake(6, NO));  // F#
    XCTAssertEqual(VibeMusicalKeyFromString(@"10m"), VibeMusicalKeyMake(0, YES)); // Cm
}

- (void)testParseCamelotRoundTripsThroughFormatter {
    for (VibeMusicalKey key = 0; key < 24; key++) {
        XCTAssertEqual(VibeMusicalKeyFromString(VibeMusicalKeyCamelotName(key)), key,
                       @"key %ld", (long)key);
        XCTAssertEqual(VibeMusicalKeyFromString(VibeMusicalKeyMusicalName(key)), key,
                       @"key %ld", (long)key);
    }
}

#pragma mark - Rejects

- (void)testParseRejectsGarbage {
    XCTAssertEqual(VibeMusicalKeyFromString(@""), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"   "), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"128"), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"unknown"), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"X#m"), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"Amz"), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"Q"), VibeMusicalKeyNone);
    XCTAssertEqual(VibeMusicalKeyFromString(@"A minor with words"), VibeMusicalKeyNone);
}

@end
