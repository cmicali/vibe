//
//  PlaylistFileCUETests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaylistFileTestCase.h"
#import "PlaylistFile.h"
#import "AudioTrack.h"
#import "PlaylistEntry.h"
#import "AudioFixtures.h"

// Each name at /cue/<name>, and a track before any FILE line at /cue/image.
// The rows are made from the reader's entries, as the app makes them.
static NSArray<AudioTrack *> *CueRows(NSString *text) {
    NSArray<PlaylistEntry *> *entries =
            [PlaylistFile cueEntriesInText:text sheetURL:[NSURL fileURLWithPath:@"/cue/sheet.cue"]
                             resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        return [NSURL fileURLWithPath:[@"/cue" stringByAppendingPathComponent:name ?: @"image"] isDirectory:NO];
    }];
    return [AudioTrack rowsForEntries:entries];
}

// A row as "file start-end title/performer #number", one string to compare.
static NSString *CueRowSummary(AudioTrack *row) {
    return [NSString stringWithFormat:@"%@ %lu-%lu %@/%@ #%ld", row.url.lastPathComponent,
            (unsigned long)row.cueStart, (unsigned long)row.cueEnd,
            row.cueTitle ?: @"-", row.cuePerformer ?: @"-", (long)row.cueTrackNumber];
}

static NSArray<NSString *> *CueRowSummaries(NSString *text) {
    NSMutableArray<NSString *> *summaries = [NSMutableArray new];
    for (AudioTrack *row in CueRows(text)) {
        [summaries addObject:CueRowSummary(row)];
    }
    return summaries;
}

@interface PlaylistFileCUETests : PlaylistFileTestCase
@end

@implementation PlaylistFileCUETests

#pragma mark - fileNamesInCueText:

- (void)testCueQuotedEntriesInSheetOrder {
    NSString *text = @"REM GENRE Electronica\n"
                      "PERFORMER \"Some Artist\"\n"
                      "FILE \"01 - First Track.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n"
                      "    INDEX 01 00:00:00\n"
                      "FILE \"02 - Second Track.flac\" WAVE\n"
                      "  TRACK 02 AUDIO\n";
    NSArray *entries = [PlaylistFile fileNamesInCueText:text];
    NSArray *expected = @[@"01 - First Track.flac", @"02 - Second Track.flac"];
    XCTAssertEqualObjects(entries, expected);
}

- (void)testCueUnquotedEntryWithTypeKeyword {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE track.mp3 MP3\n"], @[@"track.mp3"]);
}

- (void)testCueUnquotedEntryWithSpacesAndTypeKeyword {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE 01 My Track.mp3 MP3\n"], @[@"01 My Track.mp3"]);
}

- (void)testCueUnquotedEntryWithoutTypeKeyword {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE track.wav\n"], @[@"track.wav"]);
}

- (void)testCueIndentedAndLowercaseFileKeyword {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"   file \"a.flac\" wave\n"], @[@"a.flac"]);
}

- (void)testCueQuotedNameKeepsTrailingKeywordLookalike {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \"WAVE\" WAVE\n"], @[@"WAVE"]);
}

- (void)testCueUnterminatedQuoteTakesRestOfLine {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \"broken.flac\n"], @[@"broken.flac"]);
}

- (void)testCueBackslashPathNormalizesToSlashes {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \"disc\\track.wav\" WAVE\n"],
                          @[@"disc/track.wav"]);
}

- (void)testCueConsecutiveDuplicatesCollapse {
    NSString *text = @"FILE \"image.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n"
                      "FILE \"image.flac\" WAVE\n"
                      "  TRACK 02 AUDIO\n"
                      "FILE \"IMAGE.FLAC\" WAVE\n"
                      "  TRACK 03 AUDIO\n";
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:text], @[@"image.flac"]);
}

- (void)testCueNonConsecutiveDuplicatesAreKept {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "FILE \"b.flac\" WAVE\n"
                      "FILE \"a.flac\" WAVE\n";
    NSArray *expected = @[@"a.flac", @"b.flac", @"a.flac"];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:text], expected);
}

- (void)testCueNonFileLinesIgnored {
    NSString *text = @"TITLE \"An Album\"\nREM FILE \"not-this.flac\"\nFILENAME nope\n";
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:text], @[]);
}

- (void)testCueCarriageReturnLineEndings {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \"a.flac\" WAVE\r\nFILE \"b.flac\" WAVE\r\n"],
                          (@[@"a.flac", @"b.flac"]));
}

- (void)testCueEveryTypeKeywordIsStripped {
    for (NSString *keyword in @[@"WAVE", @"MP3", @"AIFF", @"BINARY", @"MOTOROLA", @"FLAC"]) {
        NSString *line = [NSString stringWithFormat:@"FILE track.wav %@\n", keyword];
        XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:line], @[@"track.wav"], @"%@", keyword);
    }
}

- (void)testCueTypeKeywordStripIsCaseInsensitive {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE track.mp3 mp3\n"], @[@"track.mp3"]);
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE track.wav Wave\n"], @[@"track.wav"]);
}

// Only the six known keywords are stripped: a file really called
// "track.mp3 OGG" is likelier than a writer inventing a type.
- (void)testCueUnknownTrailingTokenStaysInTheName {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE track.mp3 OGG\n"], @[@"track.mp3 OGG"]);
}

- (void)testCueBareKeywordIsTakenAsTheName {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE WAVE\n"], @[@"WAVE"]);
}

- (void)testCueEmptyAndWhitespaceOnlyNamesAreDropped {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \"\" WAVE\n"], @[]);
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \n"], @[]);
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE\n"], @[]);
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE\"\"\n"], @[]);
}

// CUE has no escape syntax.
- (void)testCueQuotedNameEndsAtTheNextQuote {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \"a\"b.flac\" WAVE\n"], @[@"a"]);
}

- (void)testCueQuotedNameKeepsItsSurroundingSpaces {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE \" spaced .flac \" WAVE\n"],
                          @[@" spaced .flac "]);
}

- (void)testCueUnquotedBackslashPathNormalizes {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE C:\\Rips\\track.wav WAVE\n"],
                          @[@"C:/Rips/track.wav"]);
}

- (void)testCueTabAfterTheKeywordIsAccepted {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE\t\"a.flac\"\tWAVE\n"],
                          @[@"a.flac"]);
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE\ttrack.mp3\tMP3\n"],
                          @[@"track.mp3"]);
}

- (void)testCueExtraSpacesAroundTheNameAreAbsorbed {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"   FILE    \"a.flac\"    WAVE   \n"],
                          @[@"a.flac"]);
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@"FILE   track.mp3    MP3\n"], @[@"track.mp3"]);
}

- (void)testCueNonASCIINamesSurviveIntact {
    NSString *text = @"FILE \"Björk — Jóga.flac\" WAVE\nFILE \"01 🎧 mix.flac\" WAVE\n";
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:text],
                          (@[@"Björk — Jóga.flac", @"01 🎧 mix.flac"]));
}

- (void)testCueEmptyTextYieldsNoEntries {
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:@""], @[]);
}

- (void)testCueDuplicatesSeparatedByIgnoredLinesStillCollapse {
    NSString *text = @"FILE \"image.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nFILE \"image.flac\" WAVE\n";
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:text], @[@"image.flac"]);
}

#pragma mark - cueEntriesInText: times and INDEX rules

- (void)testCueTimesAreCDFrames {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 01:02:03\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 120:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4653 -/- #1",
                                                     @"a.flac 4653-540000 -/- #2",
                                                     @"a.flac 540000-0 -/- #3"]));
}

- (void)testCueFramesAndTheMinutesSecondsForm {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 00:00:74\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 01:02\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-74 -/- #1", @"a.flac 74-4650 -/- #2",
                                                     @"a.flac 4650-0 -/- #3"]));
}

// A junk INDEX is ignored rather than read as a zero start, and a run of digits
// integerValue would saturate is junk.
- (void)testCueUnparseableTimesDropTheirTrack {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 aa:bb:cc\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 1234567:00:00\n"
                      "  TRACK 04 AUDIO\n    INDEX 01 1:2:3:4\n"
                      "  TRACK 05 AUDIO\n    INDEX 01 ::\n"
                      "  TRACK 06 AUDIO\n    INDEX 01 -5:00:00\n"
                      "  TRACK 07 AUDIO\n    INDEX 01 00:10:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-750 -/- #1", @"a.flac 750-0 -/- #7"]));
}

- (void)testCueIndex01BeatsIndex00InEitherOrder {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 00 01:00:00\n    INDEX 01 01:02:00\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 03:00:00\n    INDEX 00 02:58:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4650 -/- #1", @"a.flac 4650-13500 -/- #2",
                                                     @"a.flac 13500-0 -/- #3"]));
}

- (void)testCueIndex00IsUsedWhenItIsTheOnlyOne {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 00 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 -/- #1", @"a.flac 4500-0 -/- #2"]));
}

- (void)testCueOtherIndexNumbersAreIgnored {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n    INDEX 02 01:30:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 -/- #1", @"a.flac 4500-0 -/- #2"]));
}

- (void)testCueTheLastIndex01OfATrackWins {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n    INDEX 01 02:00:00\n    INDEX 00 00:30:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-9000 -/- #1", @"a.flac 9000-0 -/- #2"]));
}

- (void)testCueTrackWithoutAnIndexIsDroppedAndNeighboursSurvive {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    TITLE \"Gone\"\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 -/- #1", @"a.flac 4500-0 -/- #3"]));
}

- (void)testCueAnIndexBeforeAnyTrackIsIgnored {
    NSString *text = @"INDEX 01 05:00:00\nFILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-0 -/- #1"]));
}

// A marker list must be ordered to be navigable. The first row still starts at
// the file's first frame, whatever its INDEX says.
- (void)testCueBackwardsStartIsDropped {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 10:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 05:00:00\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 20:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-90000 -/- #1", @"a.flac 90000-0 -/- #3"]));
}

- (void)testCueBackwardsDropIsMeasuredAgainstTheLastKeptStart {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 10:00:00\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 05:00:00\n"
                      "  TRACK 04 AUDIO\n    INDEX 01 07:00:00\n"
                      "  TRACK 05 AUDIO\n    INDEX 01 12:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-45000 -/- #1", @"a.flac 45000-54000 -/- #2",
                                                     @"a.flac 54000-0 -/- #5"]));
}

// Two tracks at one marker leave the first an empty window, which cannot play.
- (void)testCueEqualStartsKeepTheLaterTrack {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 -/- #1", @"a.flac 4500-0 -/- #3"]));
}

// A next start of 0 is a marker, not "to the file's end".
- (void)testCueEqualStartsAtZeroLeaveOneWholeFileRow {
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < 5000; i++) {
        [text appendString:@"FILE \"image.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"];
    }
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"image.flac 0-0 -/- #1"]));
}

#pragma mark - cueEntriesInText: fields

- (void)testCueTrackNumbersTitlesAndPerformers {
    NSString *text = @"PERFORMER \"VA\"\n"
                      "FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE \"One\"\n    PERFORMER \"P1\"\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    TITLE \"Two\"\n    INDEX 01 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 One/P1 #1", @"a.flac 4500-0 Two/VA #2"]));
}

- (void)testCuePerTrackFieldsDoNotBleedIntoTheNextTrack {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE \"One\"\n    PERFORMER \"P1\"\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 One/P1 #1", @"a.flac 4500-0 -/- #2"]));
}

- (void)testCueTheSheetTitleNamesNoRow {
    NSString *text = @"TITLE \"The Album\"\nFILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-0 -/- #1"]));
}

- (void)testCueNonAudioTrackIsIgnoredAndItsFieldsDoNotLeak {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 MODE1/2352\n    TITLE \"Data\"\n    PERFORMER \"X\"\n    INDEX 01 05:00:00\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 10:00:00\n"
                      "  TRACK 04\n    INDEX 01 15:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-45000 One/- #1", @"a.flac 45000-0 -/- #3"]));
}

- (void)testCueLowercaseAndIndentedKeywords {
    NSString *text = @"\tfile \"a.flac\" wave\n"
                      "\t\ttrack 01 audio\n\t\t\ttitle \"One\"\n\t\t\tindex 01 00:00:00\n"
                      "  track 02 AUDIO\n    index 01 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 One/- #1", @"a.flac 4500-0 -/- #2"]));
}

- (void)testCueIgnoredCommandsChangeNothing {
    NSString *text = @"REM GENRE House\nREM DATE 1999\nCATALOG 0000000000000\n"
                      "FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    FLAGS DCP\n    ISRC USABC9900001\n    SONGWRITER \"W\"\n"
                      "    PREGAP 00:02:00\n    INDEX 01 00:00:00\n    POSTGAP 00:01:00\n"
                      "  TRACK 02 AUDIO\n    REM TITLE \"Not a title\"\n    INDEX 01 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 -/- #1", @"a.flac 4500-0 -/- #2"]));
}

- (void)testCueFieldQuoting {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE Unquoted Words\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    TITLE \"Rock & Roll, Pt. 2 (Live)\"\n    INDEX 01 01:00:00\n"
                      "  TRACK 03 AUDIO\n    TITLE \"Never closed\n    PERFORMER \"\"\n    INDEX 01 02:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 Unquoted Words/- #1",
                                                     @"a.flac 4500-9000 Rock & Roll, Pt. 2 (Live)/- #2",
                                                     @"a.flac 9000-0 Never closed/- #3"]));
}

- (void)testCueEveryLineEndingStyle {
    for (NSString *eol in @[@"\n", @"\r\n", @"\r", @" ", @" "]) {
        NSString *text = [@[@"FILE \"a.flac\" WAVE", @"  TRACK 01 AUDIO", @"    INDEX 01 00:00:00",
                            @"  TRACK 02 AUDIO", @"    INDEX 01 00:02:00", @""] componentsJoinedByString:eol];
        XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-150 -/- #1", @"a.flac 150-0 -/- #2"]),
                              @"U+%04X", [eol characterAtIndex:eol.length - 1]);
    }
}

- (void)testCueEmptyAndCommandlessTextYieldNoRows {
    XCTAssertEqualObjects(CueRows(@""), @[]);
    XCTAssertEqualObjects(CueRows(@"\n  \t \r\n"), @[]);
    XCTAssertEqualObjects(CueRows(@"hello\nworld\n"), @[]);
    XCTAssertEqualObjects(CueRows(@"FILE\nTRACK\nINDEX\nTITLE\nPERFORMER\nREM\n"), @[]);
}

- (void)testCueNoLineBreaksAtAll {
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < 200; i++) {
        [text appendString:@"FILE \"a.flac\" WAVE TRACK 01 AUDIO INDEX 01 00:00:00 "];
    }
    XCTAssertEqual(CueRows(text).count, 1u);
    XCTAssertFalse(CueRows(text).firstObject.isWindowed);
}

// A NUL is dropped from the FILE name, which NSURL could not hold; titles keep
// what they carry.
- (void)testCueUnicodeAndControlCharactersSurvive {
    NSString *text = [NSString stringWithFormat:@"PERFORMER \"Björk\"\n"
                                                 "FILE \"日本語%C.flac\" WAVE\n"
                                                 "  TRACK 01 AUDIO\n    TITLE \"🎧 مرحبا — Ωμέγα\x01\"\n"
                                                 "    INDEX 01 00:00:00\n", (unichar)0];
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"日本語.flac 0-0 🎧 مرحبا — Ωμέγα\x01/Björk #1"]));
}

- (void)testCueVeryLongFieldsAreKeptWhole {
    NSString *name = [@"" stringByPaddingToLength:200000 withString:@"A" startingAtIndex:0];
    NSString *text = [NSString stringWithFormat:
            @"FILE \"x.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"%@\"\n    INDEX 01 00:00:00\n", name];
    XCTAssertEqual(CueRows(text).firstObject.cueTitle.length, name.length);
}

- (void)testCueTenThousandTracks {
    NSMutableString *text = [NSMutableString stringWithString:@"FILE \"a.flac\" WAVE\n"];
    for (NSUInteger i = 0; i < 10000; i++) {
        [text appendFormat:@"  TRACK %lu AUDIO\n    TITLE \"T%lu\"\n    INDEX 01 %lu:00:00\n",
                           (unsigned long)i + 1, (unsigned long)i, (unsigned long)i];
    }
    NSArray<AudioTrack *> *rows = CueRows(text);
    XCTAssertEqual(rows.count, 10000u);
    XCTAssertEqual(rows.lastObject.cueStart, 9999u * 4500u);
    XCTAssertEqual(rows.lastObject.cueEnd, 0u);
}

#pragma mark - cueEntriesInText: windows

- (void)testCueRowsTileTheirFile {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 03:00:00\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 07:30:00\n";
    NSArray<AudioTrack *> *rows = CueRows(text);
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-13500 -/- #1", @"a.flac 13500-33750 -/- #2",
                                                     @"a.flac 33750-0 -/- #3"]));
    XCTAssertTrue(rows[0].isWindowed);
    XCTAssertTrue(rows[2].isWindowed);
    XCTAssertEqualObjects(rows[0].cueSheetURL.path, @"/cue/sheet.cue");
}

// Audio before track 1's INDEX 01 — a pregap, or a hidden track — is its row's.
- (void)testCueAFilesFirstRowStartsAtItsFirstFrame {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 00 00:00:00\n    INDEX 01 00:32:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 04:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-18000 -/- #1", @"a.flac 18000-0 -/- #2"]));
}

// As on a CD: played through, a pregap belongs to the row before it.
- (void)testCueAPregapPlaysAtTheEndOfTheRowBeforeIt {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 00 03:58:00\n    INDEX 01 04:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-18000 -/- #1", @"a.flac 18000-0 -/- #2"]));
}

- (void)testCueASingleTrackSheetIsNotWindowed {
    AudioTrack *row = CueRows(@"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"T\"\n    INDEX 01 00:00:00\n")
            .firstObject;
    XCTAssertFalse(row.isWindowed);
    XCTAssertEqualObjects(row.cueTitle, @"T");
}

- (void)testCueEachFileOfAMultiFileSheetGetsItsOwnRows {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    INDEX 01 02:00:00\n"
                      "FILE \"b.flac\" WAVE\n"
                      "  TRACK 03 AUDIO\n    INDEX 01 00:00:00\n"
                      "  TRACK 04 AUDIO\n    INDEX 01 03:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-9000 -/- #1", @"a.flac 9000-0 -/- #2",
                                                     @"b.flac 0-13500 -/- #3", @"b.flac 13500-0 -/- #4"]));
}

// EAC's one-file-per-track layout puts a track's INDEX 00 at the end of the
// previous file: each track is its own file, whole.
- (void)testCueOneFilePerTrackLayout {
    NSString *text = @"FILE \"01.wav\" WAVE\n"
                      "  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n"
                      "  TRACK 02 AUDIO\n    TITLE \"Two\"\n    INDEX 00 04:10:50\n"
                      "FILE \"02.wav\" WAVE\n    INDEX 01 00:00:00\n"
                      "  TRACK 03 AUDIO\n    TITLE \"Three\"\n    INDEX 00 03:20:00\n"
                      "FILE \"03.wav\" WAVE\n    INDEX 01 00:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"01.wav 0-0 One/- #1", @"02.wav 0-0 Two/- #2",
                                                     @"03.wav 0-0 Three/- #3"]));
}

- (void)testCueRepeatedFileLinesAreOneFile {
    NSString *text = @"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "FILE \"A.FLAC\" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n";
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-4500 -/- #1", @"a.flac 4500-0 -/- #2"]));
}

// A FILE with no surviving windows still plays whole.
- (void)testCueAFileWhoseTracksAllDropPlaysWhole {
    NSString *text = @"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                      "FILE \"b.flac\" WAVE\n  TRACK 02 AUDIO\n    TITLE \"No index\"\n"
                      "FILE \"c.flac\" WAVE\n";
    NSArray<AudioTrack *> *rows = CueRows(text);
    XCTAssertEqualObjects(CueRowSummaries(text), (@[@"a.flac 0-0 -/- #1", @"b.flac 0-0 -/- #0",
                                                     @"c.flac 0-0 -/- #0"]));
    XCTAssertNil(rows[1].cueSheetURL);
}

- (void)testCueTracksBeforeAnyFileLineAskForTheImplicitImage {
    NSMutableArray *asked = [NSMutableArray new];
    NSArray<PlaylistEntry *> *entries = [PlaylistFile cueEntriesInText:@"TRACK 01 AUDIO\n  INDEX 01 00:00:00\n"
                                                                     "TRACK 02 AUDIO\n  INDEX 01 01:00:00\n"
                                                           sheetURL:nil
                                                      resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        [asked addObject:@[name ?: NSNull.null, @(sole)]];
        return [NSURL fileURLWithPath:@"/cue/Mix.flac"];
    }];
    XCTAssertEqualObjects(asked, (@[@[NSNull.null, @YES]]));
    XCTAssertEqual(entries.count, 2u);
    XCTAssertEqual(entries[1].cueStart, 4500u);
}

- (void)testCueSoleIsYesOnlyForASheetNamingOneFile {
    NSMutableArray<NSNumber *> *soles = [NSMutableArray new];
    NSURL *(^resolve)(NSString *, BOOL) = ^NSURL *(NSString *name, BOOL sole) {
        [soles addObject:@(sole)];
        return [NSURL fileURLWithPath:[@"/cue" stringByAppendingPathComponent:name]];
    };
    [PlaylistFile cueEntriesInText:@"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                          sheetURL:nil resolvingFile:resolve];
    [PlaylistFile cueEntriesInText:@"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                                    "FILE \"b.flac\" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n"
                          sheetURL:nil resolvingFile:resolve];
    XCTAssertEqualObjects(soles, (@[@YES, @NO, @NO]));
}

- (void)testCueAnUnresolvedFileDropsOnlyItsRows {
    NSArray<PlaylistEntry *> *entries = [PlaylistFile cueEntriesInText:
            @"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
             "FILE \"b.flac\" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n"
                                                           sheetURL:nil
                                                      resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        return [name isEqualToString:@"b.flac"] ? nil : [NSURL fileURLWithPath:@"/cue/a.flac"];
    }];
    XCTAssertEqual(entries.count, 1u);
    XCTAssertEqual(entries.firstObject.cueTrackNumber, 1);
}

// Mutates a well-formed sheet at random: whatever comes back must still play —
// windows that are empty nowhere, and starts that only grow within a file,
// each file's first at its first frame. The seed is fixed, so a failure
// reproduces.
- (void)testCueFuzzedMutationsKeepRowsPlayable {
    NSString *valid =
            @"REM GENRE House\nPERFORMER \"VA\"\nTITLE \"A Mix\"\n"
             "FILE \"image.flac\" WAVE\n"
             "  TRACK 01 AUDIO\n    TITLE \"One\"\n    PERFORMER \"P1\"\n    INDEX 01 00:00:00\n"
             "  TRACK 02 AUDIO\n    TITLE \"Two\"\n    INDEX 00 03:00:00\n    INDEX 01 03:07:30\n"
             "FILE \"two.flac\" WAVE\n"
             "  TRACK 03 AUDIO\n    TITLE \"Three\"\n    INDEX 01 00:42:21\n"
             "  TRACK 04 AUDIO\n    TITLE \"Four\"\n    INDEX 01 08:42:21\n";
    NSData *validData = [valid dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t seed = 0xC0FFEE;
    for (NSUInteger round = 0; round < 2000; round++) {
        NSMutableData *data = [validData mutableCopy];
        uint8_t *bytes = data.mutableBytes;
        seed = seed * 1664525u + 1013904223u;
        NSUInteger edits = 1 + (seed >> 28);
        for (NSUInteger e = 0; e < edits; e++) {
            seed = seed * 1664525u + 1013904223u;
            NSUInteger at = (seed >> 8) % data.length;
            seed = seed * 1664525u + 1013904223u;
            switch ((seed >> 16) % 3) {
                case 0: bytes[at] = (uint8_t)(seed >> 24); break;
                case 1: bytes[at] = '\n'; break;
                case 2: bytes[at] = '"'; break;
            }
        }
        NSString *text = [PlaylistFile textFromData:data];
        if (!text) {
            continue;
        }
        NSMutableDictionary<NSString *, NSNumber *> *lastStart = [NSMutableDictionary new];
        for (AudioTrack *row in CueRows(text)) {
            NSString *file = row.url.path;
            XCTAssertTrue(row.cueEnd == 0 || row.cueEnd > row.cueStart, @"round %lu", (unsigned long)round);
            if (lastStart[file]) {
                XCTAssertGreaterThan(row.cueStart, lastStart[file].unsignedIntegerValue, @"round %lu",
                                     (unsigned long)round);
            }
            else {
                XCTAssertEqual(row.cueStart, 0u, @"round %lu", (unsigned long)round);
            }
            lastStart[file] = @(row.cueStart);
        }
    }
}

#pragma mark - cueEntriesForSheetAtURL:

- (NSArray<NSString *> *)rowFilesForSheet:(NSString *)sheet inDir:(NSURL *)dir {
    return [[PlaylistFile cueEntriesForSheetAtURL:[dir URLByAppendingPathComponent:sheet] knownFiles:nil]
            valueForKeyPath:@"url.lastPathComponent"];
}

- (void)testCueRowsResolveTheirImageAndCarryTheSheet {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Mix.flac"] playlistName:@"Mix.cue"
                                       text:@"FILE \"Mix.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                                             "  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n"];
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:
            [PlaylistFile cueEntriesForSheetAtURL:[dir URLByAppendingPathComponent:@"Mix.cue"] knownFiles:nil]];
    XCTAssertEqual(rows.count, 2u);
    XCTAssertEqualObjects(rows[1].url.URLByDeletingLastPathComponent.path, dir.path);
    XCTAssertEqualObjects(rows[1].cueSheetURL.lastPathComponent, @"Mix.cue");
    XCTAssertEqual(rows[1].cueStart, 4500u);
}

// A sheet still naming a long-gone CDImage.wav finds the image renamed to match it.
- (void)testCueBasenameRescuesAMissingImage {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Mix.flac"] playlistName:@"Mix.cue"
                                       text:@"FILE \"CDImage.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], @[@"Mix.flac"]);
}

- (void)testCueSheetWithNoFileLineRescuesFromItsOwnBasename {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Mix.aif"] playlistName:@"Mix.cue"
                                       text:@"TRACK 01 AUDIO\n  INDEX 01 00:00:00\nTRACK 02 AUDIO\n  INDEX 01 01:00:00\n"];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], (@[@"Mix.aif", @"Mix.aif"]));
}

- (void)testCueSheetWithNoFileLineAndNoSiblingHasNoRows {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Other.flac"] playlistName:@"Mix.cue"
                                       text:@"TRACK 01 AUDIO\n  INDEX 01 00:00:00\n"];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], @[]);
}

- (void)testCueTheNamedImageBeatsTheBasenameRescue {
    NSURL *dir = [self makeTempDirWithFiles:@[@"CDImage.wav", @"Mix.flac"] playlistName:@"Mix.cue"
                                       text:@"FILE \"CDImage.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], @[@"CDImage.wav"]);
}

// Two missing images cannot both be the one audio file named like the sheet.
- (void)testCueAMultiFileSheetTakesNoBasenameRescue {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Mix.flac"] playlistName:@"Mix.cue"
                                       text:@"FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                                             "FILE \"b.wav\" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n"];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], (@[@"a.wav", @"b.wav"]));
}

- (void)testCueAnUnreadableImageStillYieldsThePrimaryCandidate {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"Mix.cue"
                                       text:@"FILE \"missing.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], @[@"missing.wav"]);
}

- (void)testCueAMissingSheetHasNoRows {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Mix.flac"] playlistName:@"Other.cue" text:@""];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], @[]);
}

- (void)testCueEntryWithNULsResolvesWithoutCrashing {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"placeholder.txt" text:@""];
    NSMutableData *data = [NSMutableData data];
    [data appendBytes:"FILE \"a\0b.flac\" WAVE\n" length:21];
    [data appendBytes:"  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n" length:38];
    NSURL *sheet = [dir URLByAppendingPathComponent:@"nul.cue"];
    [data writeToURL:sheet atomically:YES];
    for (AudioTrack *row in [AudioTrack rowsForEntries:[PlaylistFile cueEntriesForSheetAtURL:sheet knownFiles:nil]]) {
        XCTAssertNotNil(row.url);
    }
    for (NSURL *url in [[PlaylistFile entriesForPlaylistAtURL:sheet] valueForKey:@"url"]) {
        XCTAssertNotNil(url);
    }
}

#pragma mark - A FLAC's own sheet

static NSString *const kEmbeddedSheet =
        @"PERFORMER \"DJ\"\nFILE \"Album.wav\" WAVE\n"
         "  TRACK 01 AUDIO\n    TITLE \"One\"\n    INDEX 01 00:00:00\n"
         "  TRACK 02 AUDIO\n    TITLE \"Two\"\n    INDEX 01 00:30:00\n"
         "  TRACK 03 AUDIO\n    TITLE \"Three\"\n    INDEX 01 01:00:00\n";

- (NSURL *)embeddedFLACWithText:(NSString *)text block:(NSData *)block rate:(uint32_t)rate id3:(BOOL)id3 {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:[@"EmbeddedCue-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    }];
    NSURL *url = VibeWriteFLACHeader([dir URLByAppendingPathComponent:@"Album.flac"], rate, text, block, id3, 0);
    XCTAssertNotNil(url);
    return url;
}

static NSArray<NSString *> *Windows(NSArray<AudioTrack *> *rows) {
    NSMutableArray<NSString *> *windows = [NSMutableArray array];
    for (AudioTrack *row in rows) {
        [windows addObject:[NSString stringWithFormat:@"%lu-%lu", (unsigned long)row.cueStart, (unsigned long)row.cueEnd]];
    }
    return windows;
}

// The sheet's FILE names the rip's WAV; the audio is the FLAC itself.
- (void)testAnEmbeddedTagSheetCutsTheFileIntoItsTracks {
    NSURL *flac = [self embeddedFLACWithText:kEmbeddedSheet block:nil rate:44100 id3:NO];
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:flac]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-2250", @"2250-4500", @"4500-0"]));
    XCTAssertEqualObjects([rows valueForKey:@"cueTitle"], (@[@"One", @"Two", @"Three"]));
    for (AudioTrack *row in rows) {
        XCTAssertEqualObjects(row.url, flac);
        XCTAssertEqualObjects(row.cueSheetURL, flac);
        XCTAssertEqualObjects(row.cuePerformer, @"DJ");
    }
}

// A pregap is INDEX 00, so the row starts at INDEX 01, and the pregap plays at
// the end of the row before, as with a sheet on disk.
- (void)testABinaryBlockCutsTheFileAtItsIndexOnes {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(28 * 44100), @(2 * 44100), @NO],
                                            @[@3, @(60 * 44100), @0, @NO]], 90 * 44100);
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:block rate:44100 id3:NO]]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-2250", @"2250-4500", @"4500-0"]));
    XCTAssertEqualObjects([rows valueForKey:@"cueTrackNumber"], (@[@1, @2, @3]));
    XCTAssertNil(rows.firstObject.cueTitle);
}

// Offsets off the CD's 588-sample grid round to the nearest CD frame.
- (void)testABinaryBlockAtAnotherRateRoundsToCDFrames {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(30 * 48000 + 100), @0, @NO]], 60 * 48000);
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:block rate:48000 id3:NO]]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-2250", @"2250-0"]));
}

- (void)testTheTagSheetWinsOverTheBlockForItsTitles {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(10 * 44100), @0, @NO]], 90 * 44100);
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:kEmbeddedSheet block:block rate:44100 id3:NO]]];
    XCTAssertEqualObjects([rows valueForKey:@"cueTitle"], (@[@"One", @"Two", @"Three"]));
}

- (void)testALeadingID3TagAndAPictureAreSkippedToTheSheet {
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:kEmbeddedSheet block:nil rate:44100 id3:YES]]];
    XCTAssertEqual(rows.count, 3u);
}

- (void)testADataTrackIsNoRow {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(30 * 44100), @0, @YES],
                                            @[@3, @(60 * 44100), @0, @NO]], 90 * 44100);
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:block rate:44100 id3:NO]]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-4500", @"4500-0"]));
    XCTAssertEqualObjects([rows valueForKey:@"cueTrackNumber"], (@[@1, @3]));
}

// A second FILE would lay its windows over the same audio.
- (void)testOnlyTheFirstFileOfAnEmbeddedSheetIsCut {
    NSString *two = @"FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                     "  TRACK 02 AUDIO\n    INDEX 01 00:30:00\n"
                     "FILE \"b.wav\" WAVE\n  TRACK 03 AUDIO\n    INDEX 01 00:00:00\n";
    NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:two block:nil rate:44100 id3:NO]]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-2250", @"2250-0"]));
}

// A single track is the file itself: nothing to cut.
- (void)testNoSheetASingleTrackOrNotAFLACGivesNoRows {
    NSString *one = @"FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Only\"\n    INDEX 01 00:00:00\n";
    XCTAssertEqualObjects([PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:one block:nil rate:44100 id3:NO]], @[]);
    XCTAssertEqualObjects([PlaylistFile cueEntriesEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:nil rate:44100 id3:NO]], @[]);
    NSURL *junk = [[self embeddedFLACWithText:nil block:nil rate:44100 id3:NO]
            URLByDeletingLastPathComponent];
    junk = [junk URLByAppendingPathComponent:@"junk.flac"];
    XCTAssertTrue([[@"not a flac at all" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:junk atomically:YES]);
    XCTAssertEqualObjects([PlaylistFile cueEntriesEmbeddedInFLACAtURL:junk], @[]);
    XCTAssertEqualObjects([PlaylistFile cueEntriesEmbeddedInFLACAtURL:[junk URLByAppendingPathExtension:@"gone"]], @[]);
}

- (void)testATruncatedBlockReadsNoFurtherThanItHolds {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(30 * 44100), @0, @NO],
                                            @[@3, @(60 * 44100), @0, @NO]], 90 * 44100);
    for (NSUInteger cut = 0; cut < block.length; cut += 7) {
        NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:[PlaylistFile cueEntriesEmbeddedInFLACAtURL:
                [self embeddedFLACWithText:nil block:[block subdataWithRange:NSMakeRange(0, cut)] rate:44100 id3:NO]]];
        XCTAssertTrue(rows.count == 0 || rows.count >= 2, @"cut at %lu", (unsigned long)cut);
    }
}

@end
