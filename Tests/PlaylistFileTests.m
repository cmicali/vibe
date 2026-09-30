//
//  PlaylistFileTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaylistFile.h"
#import "AudioTrack.h"
#import "AudioTrackInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioFixtures.h"

// Named apart from AudioTrackTests' fake: two classes of one name collide at
// link. installMetadataIfUnresolved: consults parsedOK.
@interface PlaylistWriterFakeMetadata : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) BOOL parsedOK;
@end

@implementation PlaylistWriterFakeMetadata
@end

// The FILE names a sheet resolves, in resolution order: the FILE-line lexing,
// read through the one CUE reader. Declared again in PlaylistFileFuzzTests.
@implementation PlaylistFile (CueFileNames)
+ (NSArray<NSString *> *)fileNamesInCueText:(NSString *)text {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    [self cueRowsInText:text sheetURL:nil resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        if (!name) {
            return nil;
        }
        [names addObject:name];
        return [NSURL fileURLWithPath:[@"/cue" stringByAppendingPathComponent:name] isDirectory:NO];
    }];
    return names;
}
@end

// Each name at /cue/<name>, and a track before any FILE line at /cue/image.
static NSArray<AudioTrack *> *CueRows(NSString *text) {
    return [PlaylistFile cueRowsInText:text sheetURL:[NSURL fileURLWithPath:@"/cue/sheet.cue"]
                         resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        return [NSURL fileURLWithPath:[@"/cue" stringByAppendingPathComponent:name ?: @"image"] isDirectory:NO];
    }];
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

@interface PlaylistFileTests : XCTestCase
@end

@implementation PlaylistFileTests

#pragma mark - isPlaylistExtension:

- (void)testPlaylistExtensions {
    XCTAssertTrue([PlaylistFile isPlaylistExtension:@"cue"]);
    XCTAssertTrue([PlaylistFile isPlaylistExtension:@"m3u"]);
    XCTAssertTrue([PlaylistFile isPlaylistExtension:@"m3u8"]);
    XCTAssertFalse([PlaylistFile isPlaylistExtension:@"mp3"]);
    XCTAssertFalse([PlaylistFile isPlaylistExtension:@""]);
}

// Every caller lowercases first. Folding here would hide a call site that
// forgot to, which then fails where the extension is compared directly.
- (void)testPlaylistExtensionMatchingIsCaseSensitive {
    XCTAssertFalse([PlaylistFile isPlaylistExtension:@"CUE"]);
    XCTAssertFalse([PlaylistFile isPlaylistExtension:@"M3U8"]);
    XCTAssertFalse([PlaylistFile isPlaylistExtension:@"Cue"]);
}

- (void)testNearMissExtensionsAreNotPlaylists {
    for (NSString *extension in @[@"cue2", @"m3u9", @"m3", @"pls", @"xspf", @" cue", @"cue "]) {
        XCTAssertFalse([PlaylistFile isPlaylistExtension:extension], @"%@", extension);
    }
}

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

#pragma mark - cueRowsInText: times and INDEX rules

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

// Against the last KEPT start, so one broken track cannot take the rest with it.
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

#pragma mark - cueRowsInText: fields

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

// The sheet's TITLE names the album, which Vibe shows for no file.
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

// Every keyword run together on one line: one FILE line, and no track.
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
    NSDate *start = NSDate.date;
    NSArray<AudioTrack *> *rows = CueRows(text);
    XCTAssertLessThan(-start.timeIntervalSinceNow, 5.0);
    XCTAssertEqual(rows.count, 10000u);
    XCTAssertEqual(rows.lastObject.cueStart, 9999u * 4500u);
    XCTAssertEqual(rows.lastObject.cueEnd, 0u);
}

#pragma mark - cueRowsInText: windows

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

// No audio the sheet names goes missing: a FILE none of whose tracks survived
// plays whole, as every FILE did before sheets had rows.
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
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsInText:@"TRACK 01 AUDIO\n  INDEX 01 00:00:00\n"
                                                               "TRACK 02 AUDIO\n  INDEX 01 01:00:00\n"
                                                     sheetURL:nil
                                                resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        [asked addObject:@[name ?: NSNull.null, @(sole)]];
        return [NSURL fileURLWithPath:@"/cue/Mix.flac"];
    }];
    XCTAssertEqualObjects(asked, (@[@[NSNull.null, @YES]]));
    XCTAssertEqual(rows.count, 2u);
    XCTAssertEqual(rows[1].cueStart, 4500u);
}

- (void)testCueSoleIsYesOnlyForASheetNamingOneFile {
    NSMutableArray<NSNumber *> *soles = [NSMutableArray new];
    NSURL *(^resolve)(NSString *, BOOL) = ^NSURL *(NSString *name, BOOL sole) {
        [soles addObject:@(sole)];
        return [NSURL fileURLWithPath:[@"/cue" stringByAppendingPathComponent:name]];
    };
    [PlaylistFile cueRowsInText:@"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                       sheetURL:nil resolvingFile:resolve];
    [PlaylistFile cueRowsInText:@"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                                 "FILE \"b.flac\" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n"
                       sheetURL:nil resolvingFile:resolve];
    XCTAssertEqualObjects(soles, (@[@YES, @NO, @NO]));
}

- (void)testCueAnUnresolvedFileDropsOnlyItsRows {
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsInText:
            @"FILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
             "FILE \"b.flac\" WAVE\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n"
                                                     sheetURL:nil
                                                resolvingFile:^NSURL *(NSString *name, BOOL sole) {
        return [name isEqualToString:@"b.flac"] ? nil : [NSURL fileURLWithPath:@"/cue/a.flac"];
    }];
    XCTAssertEqual(rows.count, 1u);
    XCTAssertEqual(rows.firstObject.cueTrackNumber, 1);
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

#pragma mark - m3uEntriesInText:

- (void)testM3UEntriesInListOrder {
    NSString *text = @"#EXTM3U\n"
                      "#EXTINF:123, Artist - One\n"
                      "one.mp3\n"
                      "#EXTINF:124, Artist - Two\n"
                      "sub/two.mp3\n"
                      "\n"
                      "/abs/three.flac\n";
    NSArray *expected = @[@"one.mp3", @"sub/two.mp3", @"/abs/three.flac"];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], expected);
}

- (void)testM3UPlainListWithoutDirectives {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"a.mp3\nb.mp3\n"], (@[@"a.mp3", @"b.mp3"]));
}

- (void)testM3UEntryWithSpacesSurvives {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"01 My Track.mp3\n"], @[@"01 My Track.mp3"]);
}

- (void)testM3UDuplicatesAreKept {
    NSArray *expected = @[@"a.mp3", @"a.mp3"];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"a.mp3\na.mp3\n"], expected);
}

- (void)testM3UBackslashPathNormalizesToSlashes {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"disc\\track.wav\n"], @[@"disc/track.wav"]);
}

- (void)testM3UFileURLReducesToPath {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file:///Users/me/Music/a%20b.mp3\n"],
                          @[@"/Users/me/Music/a b.mp3"]);
}

- (void)testM3UFileURLWithRawSpacesSurvives {
    // Sloppy writers skip percent-encoding; NSURL refuses the URL outright.
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file:///Users/me/My Song.mp3\n"],
                          @[@"/Users/me/My Song.mp3"]);
}

- (void)testM3UFileURLWithLocalhostAuthority {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file://localhost/Users/me/My Song.mp3\n"],
                          @[@"/Users/me/My Song.mp3"]);
}

- (void)testM3UStreamURLsAreDropped {
    NSString *text = @"http://example.com/stream.mp3\nhttps://example.com/radio\na.mp3\n";
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], @[@"a.mp3"]);
}

- (void)testM3UCarriageReturnLineEndings {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"a.mp3\r\nb.mp3\r\n"], (@[@"a.mp3", @"b.mp3"]));
}

- (void)testM3UWhitespaceIsTrimmedAndBlankLinesDropped {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"  \t a.mp3 \t \n\n   \n\t\nb.mp3\n"],
                          (@[@"a.mp3", @"b.mp3"]));
}

// The comment test runs after the trim. A bare entry starting with # is
// unreachable, which is why the writer spells one as a URL.
- (void)testM3UIndentedDirectivesAreStillComments {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"   #EXTM3U\n\t# comment\n#a.mp3\nb.mp3\n"],
                          @[@"b.mp3"]);
}

- (void)testM3UFileSchemeIsCaseInsensitive {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"FILE:///Users/me/a.mp3\n"], @[@"/Users/me/a.mp3"]);
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"File://localhost/Users/me/a.mp3\n"],
                          @[@"/Users/me/a.mp3"]);
}

- (void)testM3UEmptyFileURLIsDropped {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file://\nfile://localhost/\na.mp3\n"].lastObject,
                          @"a.mp3");
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file://\n"], @[]);
}

// stringByRemovingPercentEncoding answers nil for a malformed escape; the file
// may really be called that.
- (void)testM3UMalformedPercentEscapeFallsBackToTheRawPath {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file:///Users/me/100%ZZ done.mp3\n"],
                          @[@"/Users/me/100%ZZ done.mp3"]);
}

- (void)testM3UNonFileSchemesAreDroppedWhereverTheSchemeAppears {
    NSString *text = @"smb://server/share/a.mp3\nrtsp://x/y\nmms://z\nfeed://q\nkeep.mp3\n";
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], @[@"keep.mp3"]);
}

- (void)testM3UWindowsDrivePathIsAPathNotAURL {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"C:\\Music\\a.mp3\n"], @[@"C:/Music/a.mp3"]);
}

- (void)testM3UNonASCIIEntriesSurviveIntact {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"Björk — Jóga.flac\n01 🎧 mix.flac\n"],
                          (@[@"Björk — Jóga.flac", @"01 🎧 mix.flac"]));
}

- (void)testM3UEmptyTextYieldsNoEntries {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@""], @[]);
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"\n\n\n"], @[]);
}

- (void)testM3UFinalLineWithoutANewlineIsStillAnEntry {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"a.mp3\nb.mp3"], (@[@"a.mp3", @"b.mp3"]));
}

#pragma mark - textFromData:

- (void)testUTF8BOMIsStripped {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [data appendData:[@"FILE \"a.flac\" WAVE" dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *text = [PlaylistFile textFromData:data];
    XCTAssertTrue([text hasPrefix:@"FILE"]);
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:text], @[@"a.flac"]);
}

- (void)testWindows1252Fallback {
    // 0x80 is € in CP1252 and invalid as UTF-8, so this exercises the fallback.
    NSMutableData *data = [[@"FILE \"caf" dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [data appendBytes:"\x80" length:1];
    [data appendData:[@".mp3\" MP3" dataUsingEncoding:NSASCIIStringEncoding]];
    NSString *text = [PlaylistFile textFromData:data];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:text], @[@"caf€.mp3"]);
}

- (void)testUTF16LEWithBOM {
    NSData *data = [@"FILE \"a.flac\" WAVE" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    NSMutableData *bom = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
    [bom appendData:data];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:[PlaylistFile textFromData:bom]], @[@"a.flac"]);
}

- (void)testEmptyDataReturnsNil {
    XCTAssertNil([PlaylistFile textFromData:[NSData data]]);
}

- (void)testUTF16BEWithBOM {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xFE\xFF" length:2];
    [data appendData:[@"FILE \"a.flac\" WAVE" dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:[PlaylistFile textFromData:data]], @[@"a.flac"]);
}

// No BOM: the side of each code unit the NULs sit on is the byte order.
// Without it the CP1252 backstop renders NUL-riddled mojibake.
- (void)testBOMlessUTF16LittleEndianIsDetected {
    NSData *data = [@"FILE \"a.flac\" WAVE\nFILE \"b.flac\" WAVE\n"
            dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:[PlaylistFile textFromData:data]],
                          (@[@"a.flac", @"b.flac"]));
}

- (void)testBOMlessUTF16BigEndianIsDetected {
    NSData *data = [@"FILE \"a.flac\" WAVE\nFILE \"b.flac\" WAVE\n"
            dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:[PlaylistFile textFromData:data]],
                          (@[@"a.flac", @"b.flac"]));
}

// The five bytes CP1252 leaves undefined. Latin-1 maps every byte, so mojibake
// costs one entry where a nil text would cost all of them.
- (void)testLatin1BackstopTakesBytesCP1252Rejects {
    NSMutableData *data = [[@"FILE \"x" dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [data appendBytes:"\x81\x8D\x8F\x90\x9D" length:5];
    [data appendData:[@".mp3\" MP3" dataUsingEncoding:NSASCIIStringEncoding]];
    NSString *text = [PlaylistFile textFromData:data];
    XCTAssertNotNil(text);
    NSArray<NSString *> *entries = [PlaylistFile fileNamesInCueText:text];
    XCTAssertEqual(entries.count, 1u);
    XCTAssertTrue([entries.firstObject hasPrefix:@"x"]);
    XCTAssertTrue([entries.firstObject hasSuffix:@".mp3"]);
}

// The UTF-16 pre-check demands NULs on one side and none on the other, so one
// corrupt byte cannot flip a UTF-8 file to UTF-16.
- (void)testAStrayNULInUTF8TextIsNotMistakenForUTF16 {
    NSMutableData *data = [[@"a.mp3\nbb.mp3\nccc" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [data appendBytes:"\x00" length:1];
    [data appendData:[@".mp3\n" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqual(data.length % 2, 0u); // so the pre-check really runs

    NSArray<NSString *> *entries = [PlaylistFile m3uEntriesInText:[PlaylistFile textFromData:data]];
    XCTAssertEqual(entries.count, 3u);
    XCTAssertEqualObjects(entries[0], @"a.mp3");
    XCTAssertEqualObjects(entries[1], @"bb.mp3");
    XCTAssertTrue([entries[2] hasPrefix:@"ccc"]);
}

// A NUL or an unpaired surrogate makes NSURL answer nil, and a nil inserted
// into an array crashes the background expansion worker.
- (void)testANULInsideANameIsDroppedRatherThanCarried {
    NSMutableData *data = [[@"a" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [data appendBytes:"\x00" length:1];
    [data appendData:[@"b.mp3\nplain.mp3\n" dataUsingEncoding:NSUTF8StringEncoding]];

    NSArray<NSString *> *entries = [PlaylistFile m3uEntriesInText:[PlaylistFile textFromData:data]];
    XCTAssertEqualObjects(entries, (@[@"ab.mp3", @"plain.mp3"]));
}

- (void)testAnUnpairedSurrogateIsDroppedRatherThanCarried {
    NSString *lone = [NSString stringWithFormat:@"a%Cb.mp3", (unichar)0xD800];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:lone], @[@"ab.mp3"]);
    NSString *sheet = [NSString stringWithFormat:@"FILE \"x%Cy.flac\" WAVE\n", (unichar)0xDC00];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:sheet], @[@"xy.flac"]);
}

- (void)testAValidSurrogatePairIsNotMistakenForCorruption {
    // The strip walks pairs, so an emoji filename survives whole.
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"01 🎧 mix.mp3\n"], @[@"01 🎧 mix.mp3"]);
}

- (void)testANameOfNothingButUnpathableCharactersIsDropped {
    unichar lone[] = {0xD800, 0xD801};
    NSString *text = [NSString stringWithFormat:@"%@\nkeep.mp3\n",
                                                [NSString stringWithCharacters:lone length:2]];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], @[@"keep.mp3"]);
}

- (void)testAPercentEncodedNULInAFileURLIsDropped {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file:///Users/me/a%00b.mp3\n"],
                          @[@"/Users/me/ab.mp3"]);
}

- (void)testUTF8IsPreferredOverTheSingleByteFallbacks {
    // CP1252 would render UTF-8 é (C3 A9) as "Ã©".
    NSData *data = [@"FILE \"café.mp3\" MP3" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:[PlaylistFile textFromData:data]],
                          @[@"café.mp3"]);
}

- (void)testTruncatedUTF16StillDecodesToSomething {
    // An odd byte count cannot be UTF-16; the text must still come back.
    NSMutableData *data = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
    [data appendData:[@"FILE \"a.flac\"" dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
    [data appendBytes:"\x41" length:1];
    XCTAssertNotNil([PlaylistFile textFromData:data]);
}

- (void)testABOMOnlyFileDecodesToNoEntries {
    NSData *utf8 = [NSData dataWithBytes:"\xEF\xBB\xBF" length:3];
    XCTAssertEqualObjects([PlaylistFile fileNamesInCueText:[PlaylistFile textFromData:utf8]], @[]);
    NSData *utf16 = [NSData dataWithBytes:"\xFF\xFE" length:2];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:[PlaylistFile textFromData:utf16]], @[]);
}

// Some writers prepend a BOM to a file that already has one. The decoder eats
// the first and the explicit strip the second; a surviving U+FEFF would make
// the first entry resolve to nothing.
- (void)testADoubleLeadingBOMLeavesNothingInTheName {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xEF\xBB\xBF\xEF\xBB\xBF" length:6];
    [data appendData:[@"a.mp3" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:[PlaylistFile textFromData:data]], @[@"a.mp3"]);
}

#pragma mark - rowsForPlaylistAtURL:

- (NSURL *)makeTempDirWithFiles:(NSArray<NSString *> *)names
                   playlistName:(NSString *)playlistName
                           text:(NSString *)text {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"PlaylistFileTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in names) {
        [[NSData data] writeToURL:[dir URLByAppendingPathComponent:name] atomically:YES];
    }
    [[text dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:[dir URLByAppendingPathComponent:playlistName] atomically:YES];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    }];
    return dir;
}

- (void)testCueResolvesRelativeEntriesAgainstItsFolder {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3", @"two.mp3"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"one.mp3\" MP3\nFILE \"two.mp3\" MP3\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    NSArray *names = [urls valueForKeyPath:@"lastPathComponent"];
    XCTAssertEqualObjects(names, (@[@"one.mp3", @"two.mp3"]));
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.path, dir.path);
}

- (void)testM3UResolvesRelativeEntriesAgainstItsFolder {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3", @"two.mp3"]
                               playlistName:@"mix.m3u8"
                                       text:@"#EXTM3U\none.mp3\ntwo.mp3\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"mix.m3u8"]] valueForKey:@"url"];
    NSArray *names = [urls valueForKeyPath:@"lastPathComponent"];
    XCTAssertEqualObjects(names, (@[@"one.mp3", @"two.mp3"]));
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.path, dir.path);
}

#pragma mark - cueRowsForSheetAtURL:

- (NSArray<NSString *> *)rowFilesForSheet:(NSString *)sheet inDir:(NSURL *)dir {
    return [[PlaylistFile cueRowsForSheetAtURL:[dir URLByAppendingPathComponent:sheet]]
            valueForKeyPath:@"url.lastPathComponent"];
}

- (void)testCueRowsResolveTheirImageAndCarryTheSheet {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Mix.flac"] playlistName:@"Mix.cue"
                                       text:@"FILE \"Mix.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                                             "  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n"];
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsForSheetAtURL:[dir URLByAppendingPathComponent:@"Mix.cue"]];
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

// Readable nowhere still yields the primary, so the caller can tell a sandbox
// denial from a missing file.
- (void)testCueAnUnreadableImageStillYieldsThePrimaryCandidate {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"Mix.cue"
                                       text:@"FILE \"missing.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], @[@"missing.wav"]);
}

- (void)testCueAMissingSheetHasNoRows {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Mix.flac"] playlistName:@"Other.cue" text:@""];
    XCTAssertEqualObjects([self rowFilesForSheet:@"Mix.cue" inDir:dir], @[]);
}

// A FILE naming something NSURL cannot hold leaves no row with a nil URL.
- (void)testCueEntryWithNULsResolvesWithoutCrashing {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"placeholder.txt" text:@""];
    NSMutableData *data = [NSMutableData data];
    [data appendBytes:"FILE \"a\0b.flac\" WAVE\n" length:21];
    [data appendBytes:"  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n" length:38];
    NSURL *sheet = [dir URLByAppendingPathComponent:@"nul.cue"];
    [data writeToURL:sheet atomically:YES];
    for (AudioTrack *row in [PlaylistFile cueRowsForSheetAtURL:sheet]) {
        XCTAssertNotNil(row.url);
    }
    for (NSURL *url in [[PlaylistFile rowsForPlaylistAtURL:sheet] valueForKey:@"url"]) {
        XCTAssertNotNil(url);
    }
}

- (void)testWindowsAbsolutePathFallsBackToBasenameBesidePlaylist {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.wav"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"C:\\Rips\\track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.wav");
    XCTAssertTrue([NSFileManager.defaultManager isReadableFileAtPath:urls.firstObject.path]);
}

- (void)testAlternateExtensionBesidePlaylist {
    // The cue was written for the .wav rip; the files are .flac now.
    NSURL *dir = [self makeTempDirWithFiles:@[@"track01.flac", @"track02.flac"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"track01.wav\" WAVE\nFILE \"track02.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    NSArray *names = [urls valueForKeyPath:@"lastPathComponent"];
    XCTAssertEqualObjects(names, (@[@"track01.flac", @"track02.flac"]));
}

- (void)testAlternateExtensionInSubdirectory {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"mix.m3u" text:@"disc1/track.wav\n"];
    NSURL *sub = [dir URLByAppendingPathComponent:@"disc1"];
    [NSFileManager.defaultManager createDirectoryAtURL:sub withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToURL:[sub URLByAppendingPathComponent:@"track.mp3"] atomically:YES];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.mp3");
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.lastPathComponent, @"disc1");
}

- (void)testExactNameBeatsAlternateExtension {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.wav", @"track.flac"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.wav");
}

- (void)testWindowsPathWithAlternateExtension {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.aiff"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"C:\\Rips\\track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.aiff");
}

- (void)testMissingEntryStillYieldsPrimaryCandidate {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"mix.m3u" text:@"gone.mp3\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"gone.mp3");
}

- (void)testUnreadablePlaylistReturnsEmpty {
    NSURL *missing = [NSURL fileURLWithPath:@"/nonexistent/album.cue"];
    XCTAssertEqualObjects([[PlaylistFile rowsForPlaylistAtURL:missing] valueForKey:@"url"], @[]);
}

- (void)testAnEmptyPlaylistFileReturnsEmpty {
    NSURL *dir = [self makeTempDirWithFiles:@[@"a.mp3"] playlistName:@"mix.m3u" text:@""];
    XCTAssertEqualObjects([[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"], @[]);
}

// Parsed as M3U, every FILE line would read as a filename.
- (void)testAnUppercaseCueExtensionStillParsesAsCue {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"]
                               playlistName:@"ALBUM.CUE"
                                       text:@"FILE \"one.mp3\" MP3\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"ALBUM.CUE"]] valueForKey:@"url"];
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"], @[@"one.mp3"]);
}

// Callers pass only extensions isPlaylistExtension: admitted, so non-cue is m3u.
- (void)testANonCueExtensionTakesTheM3UReader {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"]
                               playlistName:@"list.m3u8"
                                       text:@"#EXTM3U\none.mp3\n"];
    XCTAssertEqualObjects([[[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"list.m3u8"]] valueForKey:@"url"] valueForKeyPath:@"lastPathComponent"],
                          @[@"one.mp3"]);
}

- (void)testAnAbsoluteEntryThatExistsResolvesToItself {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"] playlistName:@"mix.m3u" text:@""];
    NSURL *absolute = [dir URLByAppendingPathComponent:@"one.mp3"];
    NSURL *playlist = [dir URLByAppendingPathComponent:@"mix.m3u"];
    [[[NSString stringWithFormat:@"%@\n", absolute.path] dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:playlist atomically:YES];

    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:playlist] valueForKey:@"url"];
    XCTAssertEqualObjects([urls.firstObject.path stringByStandardizingPath],
                          [absolute.path stringByStandardizingPath]);
}

- (void)testEveryEntryProducesExactlyOneURLInOrder {
    NSURL *dir = [self makeTempDirWithFiles:@[@"b.mp3"]
                               playlistName:@"mix.m3u"
                                       text:@"gone.mp3\nb.mp3\ngone.mp3\nb.mp3\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    // The caller decides what to do with each entry, so the result lines up one
    // for one with them, duplicates and missing files included.
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"],
                          (@[@"gone.mp3", @"b.mp3", @"gone.mp3", @"b.mp3"]));
}

- (void)testAnEntryNamingADirectoryResolvesToIt {
    // isReadableFileAtPath: is true of a directory. The open funnel's extension
    // filter drops it; pinned so a change there cannot open folders as tracks.
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"mix.m3u" text:@"disc1\n"];
    [NSFileManager.defaultManager createDirectoryAtURL:[dir URLByAppendingPathComponent:@"disc1"]
                           withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"], @[@"disc1"]);
}

- (void)testTheBesideRungWinsWhenTheNamedSubfolderIsMissing {
    // A flattened rip: the basename beside the playlist, under an alternate
    // extension.
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.flac"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"disc2/track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.flac");
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.path, dir.path);
}

// Under each alternate extension the primary is tried before the beside
// candidate, so a subfolder hit beats a flattened one.
- (void)testThePrimaryFolderBeatsTheBesideRungForTheSameAlternate {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.flac"] playlistName:@"mix.m3u" text:@"disc1/track.wav\n"];
    NSURL *sub = [dir URLByAppendingPathComponent:@"disc1"];
    [NSFileManager.defaultManager createDirectoryAtURL:sub withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToURL:[sub URLByAppendingPathComponent:@"track.flac"] atomically:YES];

    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.lastPathComponent, @"disc1");
}

- (void)testTheAlternateExtensionsAreTriedInDeclaredOrder {
    // The first spelling that exists wins, so seeding two pins the order
    // rather than just the membership: aif is lossless, mp3 is not.
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.mp3", @"track.aif"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.aif");
}

// Every playable extension is a fallback: a sheet naming the pre-transcode
// file finds the m4a.
- (void)testAWavEntryRecoversToAnM4ABesideIt {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.m4a"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"album.cue"]] valueForKey:@"url"];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.m4a");
}

- (void)testTheWavAliasesAreFallbackCandidates {
    for (NSString *name in (@[@"track.wave", @"track.bwf"])) {
        NSURL *dir = [self makeTempDirWithFiles:@[name]
                                   playlistName:@"mix.m3u"
                                           text:@"track.wav\n"];
        NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
                [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
        XCTAssertEqualObjects(urls.firstObject.lastPathComponent, name);
    }
}

// OGG is not playable, so the entry resolves to the primary it named.
- (void)testAnOggBesideTheEntryIsNotAFallback {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.ogg"]
                               playlistName:@"mix.m3u"
                                       text:@"track.wav\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.wav");
}

// The beside candidate is the primary's own path, and must not be tried twice.
- (void)testTheNamedPathIsNotDuplicatedByItsOwnSpelling {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.flac"]
                               playlistName:@"mix.m3u"
                                       text:@"track.flac\ntrack.flac\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"],
                          (@[@"track.flac", @"track.flac"]));
}

- (void)testAnExtensionlessEntryStillTriesTheAlternates {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.flac"]
                               playlistName:@"mix.m3u"
                                       text:@"track\n"];
    XCTAssertEqualObjects([[[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"] valueForKeyPath:@"lastPathComponent"],
                          @[@"track.flac"]);
}

- (void)testARelativeEntryWithDotSegmentsIsStandardized {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"]
                               playlistName:@"mix.m3u"
                                       text:@"./one.mp3\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"one.mp3");
    XCTAssertFalse([urls.firstObject.path containsString:@"/./"]);
}

// UTF-16 of ASCII is valid UTF-8, so without the byte-order heuristic a
// Windows-authored sheet reads as an empty playlist.
- (void)testABOMlessUTF16SheetOnDiskResolvesItsEntries {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3", @"two.mp3"] playlistName:@"seed.cue" text:@""];
    NSURL *playlist = [dir URLByAppendingPathComponent:@"album.cue"];
    NSString *sheet = @"FILE \"one.mp3\" MP3\n  TRACK 01 AUDIO\nFILE \"two.mp3\" MP3\n";
    for (NSNumber *encoding in @[@(NSUTF16LittleEndianStringEncoding), @(NSUTF16BigEndianStringEncoding)]) {
        [[sheet dataUsingEncoding:encoding.unsignedIntegerValue] writeToURL:playlist atomically:YES];
        XCTAssertEqualObjects([[[PlaylistFile rowsForPlaylistAtURL:playlist] valueForKey:@"url"]
                                      valueForKeyPath:@"lastPathComponent"],
                              (@[@"one.mp3", @"two.mp3"]), @"encoding %@", encoding);
    }
}

- (void)testANonASCIIEntryResolvesToItsFileOnDisk {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Jóga 🎧.mp3"]
                               playlistName:@"mix.m3u"
                                       text:@"Jóga 🎧.mp3\n"];
    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKey:@"url"];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertTrue([NSFileManager.defaultManager isReadableFileAtPath:urls.firstObject.path]);
}

#pragma mark - m3uTextForTracks:relativeToDirectory:

static AudioTrack *TrackAt(NSString *path) {
    return [AudioTrack withURL:[NSURL fileURLWithPath:path]];
}

static AudioTrack *TaggedTrackAt(NSString *path, NSString *artist, NSString *title, NSTimeInterval duration) {
    AudioTrack *track = TrackAt(path);
    PlaylistWriterFakeMetadata *metadata = [PlaylistWriterFakeMetadata new];
    metadata.artist = artist;
    metadata.title = title;
    metadata.duration = duration;
    metadata.parsedOK = YES;
    [track installMetadataIfUnresolved:(AudioTrackMetadata *)metadata];
    return track;
}

static NSURL *Directory(NSString *path) {
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

- (void)testM3UTextForNoTracksIsAValidEmptyPlaylist {
    XCTAssertEqualObjects([PlaylistFile m3uTextForTracks:@[] relativeToDirectory:nil], @"#EXTM3U\n");
}

- (void)testM3UInfoLineCarriesArtistAndTitleAndRoundedSeconds {
    AudioTrack *track = TaggedTrackAt(@"/Music/A/x.mp3", @"Björk", @"Jóga", 305.4);
    NSString *text = [PlaylistFile m3uTextForTracks:@[track] relativeToDirectory:nil];
    XCTAssertEqualObjects(text, @"#EXTM3U\n#EXTINF:305,Björk - Jóga\n/Music/A/x.mp3\n");
}

// No tags: the filename-derived single line, underscores read as spaces, the
// same rule the rows and the header draw by.
- (void)testM3UInfoLineFallsBackToTheFilenameTitleAndUnknownDuration {
    NSString *text = [PlaylistFile m3uTextForTracks:@[TrackAt(@"/Music/A/01_My_Track.mp3")]
                                relativeToDirectory:nil];
    XCTAssertEqualObjects(text, @"#EXTM3U\n#EXTINF:-1,01 My Track\n/Music/A/01_My_Track.mp3\n");
}

- (void)testM3UInfoLineDurationRounds {
    AudioTrack *track = TrackAt(@"/Music/A/x.mp3");
    [track setDuration:200.6];
    XCTAssertTrue([[PlaylistFile m3uTextForTracks:@[track] relativeToDirectory:nil]
            containsString:@"#EXTINF:201,x\n"]);
}

- (void)testM3UPathsUnderTheDirectoryAreRelativeIncludingSubfolders {
    NSString *text = [PlaylistFile m3uTextForTracks:@[TrackAt(@"/Music/A/x.mp3"), TrackAt(@"/Music/A/disc2/y.mp3")]
                                relativeToDirectory:Directory(@"/Music/A")];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], (@[@"x.mp3", @"disc2/y.mp3"]));
}

// The prefix test carries a trailing slash, or /Music/Album would claim
// /Music/Album2's files and write them as "2/x.mp3".
- (void)testM3UPathsOutsideTheDirectoryAreAbsolute {
    NSString *text = [PlaylistFile m3uTextForTracks:@[TrackAt(@"/Music/Album2/x.mp3"), TrackAt(@"/Volumes/USB/y.mp3")]
                                relativeToDirectory:Directory(@"/Music/Album")];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text],
                          (@[@"/Music/Album2/x.mp3", @"/Volumes/USB/y.mp3"]));
}

- (void)testM3URelativePrefixIsCaseSensitive {
    NSString *text = [PlaylistFile m3uTextForTracks:@[TrackAt(@"/Music/a/x.mp3")]
                                relativeToDirectory:Directory(@"/Music/A")];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], @[@"/Music/a/x.mp3"]);
}

- (void)testM3UARelativeNameStartingWithHashIsNotWrittenAsAComment {
    NSString *text = [PlaylistFile m3uTextForTracks:@[TrackAt(@"/Music/A/#1 hit.mp3")]
                                relativeToDirectory:Directory(@"/Music/A")];
    XCTAssertTrue([text containsString:@"\nfile:///Music/A/%231%20hit.mp3\n"]);
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], @[@"/Music/A/#1 hit.mp3"]);
}

// The reader splits at every newline character, not just LF.
- (void)testM3UANameWithANewlineIsWrittenAsAFileURL {
    NSString *text = [PlaylistFile m3uTextForTracks:@[TrackAt(@"/Music/A/a\nb.mp3"), TrackAt(@"/Music/A/c d.mp3")]
                                relativeToDirectory:Directory(@"/Music/A")];
    XCTAssertTrue([text containsString:@"\nfile:///Music/A/a%0Ab.mp3\n"]);
    XCTAssertTrue([text containsString:@"\nfile:///Music/A/c%E2%80%A8d.mp3\n"]);
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], (@[@"/Music/A/a\nb.mp3", @"/Music/A/c d.mp3"]));
}

// The reader trims each line.
- (void)testM3UANameWithEdgeWhitespaceIsWrittenAsAFileURL {
    NSString *text = [PlaylistFile m3uTextForTracks:@[TrackAt(@"/Music/A/ x.mp3"), TrackAt(@"/Music/A/y.mp3\t")]
                                relativeToDirectory:Directory(@"/Music/A")];
    XCTAssertTrue([text containsString:@"\nfile:///Music/A/%20x.mp3\n"]);
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], (@[@"/Music/A/ x.mp3", @"/Music/A/y.mp3\t"]));
}

- (void)testM3UANewlineInATitleCannotBreakTheInfoLine {
    AudioTrack *track = TaggedTrackAt(@"/Music/A/x.mp3", @"A", @"Line\nTwo", 10);
    NSString *text = [PlaylistFile m3uTextForTracks:@[track] relativeToDirectory:nil];
    XCTAssertTrue([text containsString:@"#EXTINF:10,A - Line Two\n"]);
    XCTAssertEqual([PlaylistFile m3uEntriesInText:text].count, 1u);
}

- (void)testM3UTextRoundTripsMixedEntriesInOrder {
    NSArray<AudioTrack *> *tracks = @[TrackAt(@"/Music/A/x.mp3"), TrackAt(@"/Volumes/USB/y.flac"),
                                      TrackAt(@"/Music/A/x.mp3"), TrackAt(@"/Music/A/sub/z.wav")];
    NSString *text = [PlaylistFile m3uTextForTracks:tracks relativeToDirectory:Directory(@"/Music/A")];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text],
                          (@[@"x.mp3", @"/Volumes/USB/y.flac", @"x.mp3", @"sub/z.wav"]));
}

// The one place the relative rule meets a real temp-dir path and its two
// spellings.
- (void)testM3UTextWrittenBesideItsFilesResolvesEveryEntry {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3", @"#three.mp3"] playlistName:@"seed.m3u" text:@""];
    NSURL *sub = [dir URLByAppendingPathComponent:@"sub" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:sub withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToURL:[sub URLByAppendingPathComponent:@"two.mp3"] atomically:YES];
    NSURL *far = [self makeTempDirWithFiles:@[@"far.mp3"] playlistName:@"seed.m3u" text:@""];
    NSArray<AudioTrack *> *tracks = @[[AudioTrack withURL:[dir URLByAppendingPathComponent:@"one.mp3"]],
                                      [AudioTrack withURL:[sub URLByAppendingPathComponent:@"two.mp3"]],
                                      [AudioTrack withURL:[dir URLByAppendingPathComponent:@"#three.mp3"]],
                                      [AudioTrack withURL:[far URLByAppendingPathComponent:@"far.mp3"]]];
    NSString *text = [PlaylistFile m3uTextForTracks:tracks relativeToDirectory:dir];
    XCTAssertTrue([text containsString:@"\none.mp3\n"]);
    XCTAssertTrue([text containsString:@"\nsub/two.mp3\n"]);
    XCTAssertTrue([text containsString:@"/%23three.mp3\n"]);
    XCTAssertTrue([text containsString:@"\n/"]);   // far.mp3, absolute
    NSURL *playlist = [dir URLByAppendingPathComponent:@"mix.m3u"];
    XCTAssertTrue([PlaylistFile writeM3UForTracks:tracks relativeToDirectory:dir toURL:playlist error:NULL]);

    NSArray<NSURL *> *urls = [[PlaylistFile rowsForPlaylistAtURL:playlist] valueForKey:@"url"];
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"],
                          (@[@"one.mp3", @"two.mp3", @"#three.mp3", @"far.mp3"]));
    for (NSURL *url in urls) {
        XCTAssertTrue([NSFileManager.defaultManager isReadableFileAtPath:url.path], @"%@", url);
    }
}

#pragma mark - rowsInM3UData:

// The session mirror's read: nothing is stat'd.
- (void)testM3UDataWrittenAbsoluteReadsBackThroughRowsInM3UData {
    NSArray<NSString *> *paths = @[@"/Music/A/x.mp3", @"/Music/A/disc2/y.flac", @"/Music/A/#1 hit.mp3",
                                   @"/Music/A/ z.wav", @"/Music/A/a\nb.mp3", @"/Música/Jóga 🎧.mp3"];
    NSMutableArray<AudioTrack *> *tracks = [NSMutableArray new];
    for (NSString *path in paths) {
        [tracks addObject:TrackAt(path)];
    }
    NSData *data = [[PlaylistFile m3uTextForTracks:tracks relativeToDirectory:nil]
            dataUsingEncoding:NSUTF8StringEncoding];
    // Against the tracks' own paths: NSURL answers decomposed Unicode.
    XCTAssertEqualObjects([[[PlaylistFile rowsInM3UData:data] valueForKey:@"url"] valueForKeyPath:@"path"],
                          [tracks valueForKeyPath:@"url.path"]);
}

- (void)testRowsInM3UDataSkipsRelativeAndDirectiveLines {
    NSData *data = [@"#EXTM3U\n#EXTINF:1,x\nrelative.mp3\nfile:///Music/u.mp3\n/Music/a.mp3\n"
            dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects([[[PlaylistFile rowsInM3UData:data] valueForKey:@"url"] valueForKeyPath:@"path"],
                          (@[@"/Music/u.mp3", @"/Music/a.mp3"]));
}

- (void)testRowsInM3UDataOfNoDataIsEmpty {
    XCTAssertEqualObjects([[PlaylistFile rowsInM3UData:nil] valueForKey:@"url"], @[]);
    XCTAssertEqualObjects([[PlaylistFile rowsInM3UData:[NSData data]] valueForKey:@"url"], @[]);
}

#pragma mark - Cue rows in M3U

static AudioTrack *CueRowAt(NSString *path, NSUInteger start, NSUInteger end, NSString *title,
                            NSString *performer, NSString *sheet, NSInteger number) {
    return [[AudioTrack alloc] initWithURL:[NSURL fileURLWithPath:path] cueStart:start cueEnd:end
                                     title:title performer:performer
                                     sheet:sheet ? [NSURL fileURLWithPath:sheet] : nil trackNumber:number];
}

static void AssertSameRow(AudioTrack *restored, AudioTrack *saved) {
    XCTAssertEqualObjects(restored.url.path, saved.url.path);
    XCTAssertEqual(restored.cueStart, saved.cueStart);
    XCTAssertEqual(restored.cueEnd, saved.cueEnd);
    XCTAssertEqualObjects(restored.cueTitle, saved.cueTitle);
    XCTAssertEqualObjects(restored.cuePerformer, saved.cuePerformer);
    XCTAssertEqualObjects(restored.cueSheetURL.path, saved.cueSheetURL.path);
    XCTAssertEqual(restored.cueTrackNumber, saved.cueTrackNumber);
}

// VLC's window for other players, then Vibe's own line, before the path.
- (void)testACueRowIsWrittenWithItsWindowAndItsVibeLine {
    AudioTrack *row = CueRowAt(@"/Music/mix.flac", 4500, 9000, @"Two", @"DJ", @"/Music/mix.cue", 2);
    NSString *text = [PlaylistFile m3uTextForTracks:@[row] relativeToDirectory:nil];
    XCTAssertEqualObjects(text, @"#EXTM3U\n"
                                 "#EXTINF:60,DJ - Two\n"
                                 "#EXTVLCOPT:start-time=60.000\n"
                                 "#EXTVLCOPT:stop-time=120.000\n"
                                 "#VIBE-CUE:2,4500,9000,Two,DJ,file:///Music/mix.cue\n"
                                 "/Music/mix.flac\n");
}

// A row running to its file's end has no stop time; one starting at the
// file's first frame, no start time.
- (void)testAnUnsetWindowSideIsNotWritten {
    NSString *last = [PlaylistFile m3uTextForTracks:@[CueRowAt(@"/M/mix.flac", 4500, 0, @"B", nil, @"/M/mix.cue", 2)]
                                relativeToDirectory:nil];
    XCTAssertTrue([last containsString:@"start-time=60.000"]);
    XCTAssertFalse([last containsString:@"stop-time"]);
    NSString *first = [PlaylistFile m3uTextForTracks:@[CueRowAt(@"/M/mix.flac", 0, 4500, @"A", nil, @"/M/mix.cue", 1)]
                                 relativeToDirectory:nil];
    XCTAssertFalse([first containsString:@"start-time"]);
    XCTAssertTrue([first containsString:@"stop-time=60.000"]);
}

// The session keeps every field of a cue row exactly — names holding the
// separator, a percent sign or a newline, a sheet path holding commas — and
// restores it reading nothing but the mirror: the sheet is not there.
- (void)testSessionRoundTripRestoresCueRowsExactly {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    NSString *sheet = @"/nonexistent-vibe-session/Mix, Vol. 1.cue";
    NSArray<AudioTrack *> *tracks = @[
        [AudioTrack withURL:[NSURL fileURLWithPath:@"/nonexistent-vibe-session/a.mp3"]],
        CueRowAt(@"/nonexistent-vibe-session/mix.flac", 0, 4500, @"One, the first", @"DJ 100% & co", sheet, 1),
        CueRowAt(@"/nonexistent-vibe-session/mix.flac", 4500, 0, @"Two\nlines", nil, sheet, 2),
        CueRowAt(@"/nonexistent-vibe-session/single.flac", 0, 0, @"Whole", @"Band", sheet, 7),
    ];
    XCTAssertTrue([PlaylistFile saveSessionTracks:tracks currentIndex:2 enabled:YES toURL:url defaults:defaults
                                            write:nil error:nil]);
    __block NSArray<AudioTrack *> *restored = nil;
    XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults
                                               load:^(NSArray<AudioTrack *> *rows, NSUInteger index, BOOL paused) {
        restored = rows;
        XCTAssertEqual(index, 2u);
    }]);
    XCTAssertEqual(restored.count, tracks.count);
    for (NSUInteger i = 0; i < MIN(restored.count, tracks.count); i++) {
        AssertSameRow(restored[i], tracks[i]);
    }
    XCTAssertFalse(restored[0].isWindowed);
    XCTAssertNil(restored[0].cueSheetURL);
}

// The line describes the next entry and no other, even when that entry is a
// stream the reader drops.
- (void)testAVibeCueLineBelongsToTheNextEntryOnly {
    NSData *data = [@"#VIBE-CUE:1,0,4500,A,,file:///M/mix.cue\n/M/mix.flac\n/M/b.flac\n"
                     "#VIBE-CUE:2,4500,0,B,,file:///M/mix.cue\nhttps://example.com/live\n/M/c.flac\n"
            dataUsingEncoding:NSUTF8StringEncoding];
    NSArray<AudioTrack *> *rows = [PlaylistFile rowsInM3UData:data];
    XCTAssertEqual(rows.count, 3u);
    XCTAssertEqual(rows[0].cueEnd, 4500u);
    XCTAssertEqualObjects(rows[0].cueTitle, @"A");
    XCTAssertFalse(rows[1].isWindowed);
    XCTAssertNil(rows[1].cueTitle);
    XCTAssertFalse(rows[2].isWindowed);
    XCTAssertNil(rows[2].cueTitle);
}

- (void)testAMalformedVibeCueLineReadsAsAPlainRow {
    for (NSString *line in @[@"#VIBE-CUE:1,9000,4500,A,,", @"#VIBE-CUE:1,2", @"#VIBE-CUE:1,-5,0,A,,", @"#VIBE-CUE:"]) {
        NSData *data = [[line stringByAppendingString:@"\n/M/mix.flac\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray<AudioTrack *> *rows = [PlaylistFile rowsInM3UData:data];
        XCTAssertEqual(rows.count, 1u, @"%@", line);
        XCTAssertFalse(rows.firstObject.isWindowed, @"%@", line);
        XCTAssertNil(rows.firstObject.cueTitle, @"%@", line);
    }
}

// A saved playlist opened later resolves its entries as ever and keeps each
// cue row's window.
- (void)testASavedPlaylistOpensWithItsCueRows {
    NSURL *dir = [self makeTempDirWithFiles:@[@"mix.flac"] playlistName:@"set.m3u"
                                       text:@"#EXTM3U\n#VIBE-CUE:2,4500,0,Two,DJ,file:///elsewhere/mix.cue\nmix.flac\n"];
    NSArray<AudioTrack *> *rows = [PlaylistFile rowsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"set.m3u"]];
    XCTAssertEqual(rows.count, 1u);
    XCTAssertEqualObjects(rows.firstObject.url.lastPathComponent, @"mix.flac");
    XCTAssertEqual(rows.firstObject.cueStart, 4500u);
    XCTAssertEqualObjects(rows.firstObject.cueTitle, @"Two");
    XCTAssertEqualObjects(rows.firstObject.cueSheetURL.path, @"/elsewhere/mix.cue");
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
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:flac];
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
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:block rate:44100 id3:NO]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-2250", @"2250-4500", @"4500-0"]));
    XCTAssertEqualObjects([rows valueForKey:@"cueTrackNumber"], (@[@1, @2, @3]));
    XCTAssertNil(rows.firstObject.cueTitle);
}

// Offsets off the CD's 588-sample grid round to the nearest CD frame.
- (void)testABinaryBlockAtAnotherRateRoundsToCDFrames {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(30 * 48000 + 100), @0, @NO]], 60 * 48000);
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:block rate:48000 id3:NO]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-2250", @"2250-0"]));
}

- (void)testTheTagSheetWinsOverTheBlockForItsTitles {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(10 * 44100), @0, @NO]], 90 * 44100);
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:kEmbeddedSheet block:block rate:44100 id3:NO]];
    XCTAssertEqualObjects([rows valueForKey:@"cueTitle"], (@[@"One", @"Two", @"Three"]));
}

- (void)testALeadingID3TagAndAPictureAreSkippedToTheSheet {
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:kEmbeddedSheet block:nil rate:44100 id3:YES]];
    XCTAssertEqual(rows.count, 3u);
}

- (void)testADataTrackIsNoRow {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(30 * 44100), @0, @YES],
                                            @[@3, @(60 * 44100), @0, @NO]], 90 * 44100);
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:block rate:44100 id3:NO]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-4500", @"4500-0"]));
    XCTAssertEqualObjects([rows valueForKey:@"cueTrackNumber"], (@[@1, @3]));
}

// A second FILE would lay its windows over the same audio.
- (void)testOnlyTheFirstFileOfAnEmbeddedSheetIsCut {
    NSString *two = @"FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                     "  TRACK 02 AUDIO\n    INDEX 01 00:30:00\n"
                     "FILE \"b.wav\" WAVE\n  TRACK 03 AUDIO\n    INDEX 01 00:00:00\n";
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:two block:nil rate:44100 id3:NO]];
    XCTAssertEqualObjects(Windows(rows), (@[@"0-2250", @"2250-0"]));
}

// A single track is the file itself: nothing to cut.
- (void)testNoSheetASingleTrackOrNotAFLACGivesNoRows {
    NSString *one = @"FILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Only\"\n    INDEX 01 00:00:00\n";
    XCTAssertEqualObjects([PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:one block:nil rate:44100 id3:NO]], @[]);
    XCTAssertEqualObjects([PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [self embeddedFLACWithText:nil block:nil rate:44100 id3:NO]], @[]);
    NSURL *junk = [[self embeddedFLACWithText:nil block:nil rate:44100 id3:NO]
            URLByDeletingLastPathComponent];
    junk = [junk URLByAppendingPathComponent:@"junk.flac"];
    XCTAssertTrue([[@"not a flac at all" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:junk atomically:YES]);
    XCTAssertEqualObjects([PlaylistFile cueRowsEmbeddedInFLACAtURL:junk], @[]);
    XCTAssertEqualObjects([PlaylistFile cueRowsEmbeddedInFLACAtURL:[junk URLByAppendingPathExtension:@"gone"]], @[]);
}

// A block cut short still yields what it holds whole, and never reads past it.
- (void)testATruncatedBlockReadsNoFurtherThanItHolds {
    NSData *block = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(30 * 44100), @0, @NO],
                                            @[@3, @(60 * 44100), @0, @NO]], 90 * 44100);
    for (NSUInteger cut = 0; cut < block.length; cut += 7) {
        NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
                [self embeddedFLACWithText:nil block:[block subdataWithRange:NSMakeRange(0, cut)] rate:44100 id3:NO]];
        XCTAssertTrue(rows.count == 0 || rows.count >= 2, @"cut at %lu", (unsigned long)cut);
    }
}

#pragma mark - commonDirectoryForTracks:

- (void)testCommonDirectoryOfOneTrackIsItsFolder {
    XCTAssertEqualObjects([PlaylistFile commonDirectoryForTracks:@[TrackAt(@"/Music/A/x.mp3")]].path, @"/Music/A");
}

// Shortened at component boundaries, so /M/Album and /M/Album2 share /M, not
// "/M/Album".
- (void)testCommonDirectoryIsTheDeepestSharedFolder {
    NSArray *tracks = @[TrackAt(@"/M/A/x.mp3"), TrackAt(@"/M/A/s/y.mp3"), TrackAt(@"/M/B/z.mp3")];
    XCTAssertEqualObjects([PlaylistFile commonDirectoryForTracks:tracks].path, @"/M");
    NSArray *siblings = @[TrackAt(@"/M/Album/x.mp3"), TrackAt(@"/M/Album2/y.mp3")];
    XCTAssertEqualObjects([PlaylistFile commonDirectoryForTracks:siblings].path, @"/M");
}

- (void)testCommonDirectoryOfUnrelatedVolumesIsNil {
    NSArray *tracks = @[TrackAt(@"/Users/me/x.mp3"), TrackAt(@"/Volumes/USB/y.mp3")];
    XCTAssertNil([PlaylistFile commonDirectoryForTracks:tracks]);
}

- (void)testCommonDirectoryOfNoTracksIsNil {
    XCTAssertNil([PlaylistFile commonDirectoryForTracks:@[]]);
}

#pragma mark - Private session mirror

- (NSURL *)sessionURLWithDefaults:(NSUserDefaults **)defaults {
    NSString *suite = [@"vibe-session-tests-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:suite] isDirectory:YES];
    NSUserDefaults *store = [[NSUserDefaults alloc] initWithSuiteName:suite];
    *defaults = store;
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        [store removePersistentDomainForName:suite];
    }];
    return [root URLByAppendingPathComponent:@"nested/session.m3u"];
}

- (NSArray<AudioTrack *> *)sessionTracks {
    // These paths deliberately do not exist: restoring the mirror never probes audio files.
    AudioTrack *a = [AudioTrack withURL:[NSURL fileURLWithPath:@"/nonexistent-vibe-session/a.mp3"]];
    AudioTrack *b = [AudioTrack withURL:[NSURL fileURLWithPath:@"/nonexistent-vibe-session/b.flac"]];
    return @[a, b, a];
}

- (void)testSessionRoundTripPreservesOrderDuplicatesCursorAndPausedIntent {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    NSArray *tracks = self.sessionTracks;
    NSError *error = nil;
    XCTAssertTrue([PlaylistFile saveSessionTracks:tracks currentIndex:1 enabled:YES toURL:url defaults:defaults write:nil error:&error]);
    XCTAssertNil(error);
    __block NSUInteger loads = 0;
    XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray<AudioTrack *> *rows, NSUInteger index, BOOL paused) {
        loads++;
        XCTAssertEqualObjects([rows valueForKey:@"url"], [tracks valueForKey:@"url"]);
        XCTAssertEqual(index, 1u);
        XCTAssertTrue(paused);
    }]);
    XCTAssertEqual(loads, 1u);
}

- (void)testSessionCursorClampsCorruptAndOutOfRangeValues {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:NSNotFound enabled:YES toURL:url defaults:defaults write:nil error:nil]);
    XCTAssertEqual([defaults integerForKey:kVibeLastPlaylistCurrentIndexKey], 2);
    for (NSArray<NSNumber *> *row in @[@[@(-4), @0], @[@0, @0], @[@1, @1], @[@(NSIntegerMax), @2]]) {
        [defaults setObject:row[0] forKey:kVibeLastPlaylistCurrentIndexKey];
        XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray *urls, NSUInteger index, BOOL paused) {
            XCTAssertEqual(index, row[1].unsignedIntegerValue);
        }]);
    }
    [defaults removeObjectForKey:kVibeLastPlaylistCurrentIndexKey];
    XCTAssertTrue([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray *urls, NSUInteger index, BOOL paused) {
        XCTAssertEqual(index, 0u);
    }]);
}

- (void)testFailedSaveRemovesOldMirrorAndCursor {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:1 enabled:YES toURL:url defaults:defaults write:nil error:nil]);
    NSError *failure = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:nil];
    NSError *error = nil;
    XCTAssertFalse([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:2 enabled:YES toURL:url defaults:defaults write:^BOOL(NSError **outError) {
        if (outError) *outError = failure;
        return NO;
    } error:&error]);
    XCTAssertEqualObjects(error, failure);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:url.path]);
    XCTAssertNil([defaults objectForKey:kVibeLastPlaylistCurrentIndexKey]);
    XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:^(NSArray *urls, NSUInteger index, BOOL paused) {
        XCTFail(@"Must not revive an old playlist after failed save");
    }]);
}

- (void)testDisabledOrEmptySaveDeletesSessionWithoutCallingWriter {
    for (NSNumber *enabled in @[@NO, @YES]) {
        NSUserDefaults *defaults;
        NSURL *url = [self sessionURLWithDefaults:&defaults];
        XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:1 enabled:YES toURL:url defaults:defaults write:nil error:nil]);
        NSArray *tracks = enabled.boolValue ? @[] : self.sessionTracks;
        XCTAssertTrue([PlaylistFile saveSessionTracks:tracks currentIndex:0 enabled:enabled.boolValue toURL:url defaults:defaults write:^BOOL(NSError **error) {
            XCTFail(@"No session should be written"); return YES;
        } error:nil]);
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:url.path]);
        XCTAssertNil([defaults objectForKey:kVibeLastPlaylistCurrentIndexKey]);
    }
}

- (void)testDisabledOrUnusableMirrorNeverLoads {
    NSUserDefaults *defaults;
    NSURL *url = [self sessionURLWithDefaults:&defaults];
    void (^unexpectedLoad)(NSArray *, NSUInteger, BOOL) = ^(NSArray *urls, NSUInteger index, BOOL paused) { XCTFail(@"No restorable session"); };
    XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:unexpectedLoad]);
    XCTAssertTrue([PlaylistFile saveSessionTracks:self.sessionTracks currentIndex:0 enabled:YES toURL:url defaults:defaults write:nil error:nil]);
    XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:NO defaults:defaults load:unexpectedLoad]);
    for (NSString *text in @[@"", @"#EXTM3U\n# comment\n", @"relative.mp3\nhttps://example.com/a.mp3\n"]) {
        XCTAssertTrue([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        XCTAssertFalse([PlaylistFile restoreSessionAtURL:url enabled:YES defaults:defaults load:unexpectedLoad]);
    }
}

@end
