//
//  PlaylistFileTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaylistFile.h"

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

// The match is case-SENSITIVE, and every caller lowercases before asking. Were
// it folded here, a call site that forgot to would keep working on this path
// and fail on the ones that compare the extension themselves.
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

#pragma mark - cueFileEntriesInText:

- (void)testCueQuotedEntriesInSheetOrder {
    NSString *text = @"REM GENRE Electronica\n"
                      "PERFORMER \"Some Artist\"\n"
                      "FILE \"01 - First Track.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n"
                      "    INDEX 01 00:00:00\n"
                      "FILE \"02 - Second Track.flac\" WAVE\n"
                      "  TRACK 02 AUDIO\n";
    NSArray *entries = [PlaylistFile cueFileEntriesInText:text];
    NSArray *expected = @[@"01 - First Track.flac", @"02 - Second Track.flac"];
    XCTAssertEqualObjects(entries, expected);
}

- (void)testCueUnquotedEntryWithTypeKeyword {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE track.mp3 MP3\n"], @[@"track.mp3"]);
}

- (void)testCueUnquotedEntryWithSpacesAndTypeKeyword {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE 01 My Track.mp3 MP3\n"], @[@"01 My Track.mp3"]);
}

- (void)testCueUnquotedEntryWithoutTypeKeyword {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE track.wav\n"], @[@"track.wav"]);
}

- (void)testCueIndentedAndLowercaseFileKeyword {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"   file \"a.flac\" wave\n"], @[@"a.flac"]);
}

- (void)testCueQuotedNameKeepsTrailingKeywordLookalike {
    // Only unquoted names get the type-keyword strip; quoted names are exact.
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \"WAVE\" WAVE\n"], @[@"WAVE"]);
}

- (void)testCueUnterminatedQuoteTakesRestOfLine {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \"broken.flac\n"], @[@"broken.flac"]);
}

- (void)testCueBackslashPathNormalizesToSlashes {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \"disc\\track.wav\" WAVE\n"],
                          @[@"disc/track.wav"]);
}

- (void)testCueConsecutiveDuplicatesCollapse {
    NSString *text = @"FILE \"image.flac\" WAVE\n"
                      "  TRACK 01 AUDIO\n"
                      "FILE \"image.flac\" WAVE\n"
                      "  TRACK 02 AUDIO\n"
                      "FILE \"IMAGE.FLAC\" WAVE\n"
                      "  TRACK 03 AUDIO\n";
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text], @[@"image.flac"]);
}

- (void)testCueNonConsecutiveDuplicatesAreKept {
    NSString *text = @"FILE \"a.flac\" WAVE\n"
                      "FILE \"b.flac\" WAVE\n"
                      "FILE \"a.flac\" WAVE\n";
    NSArray *expected = @[@"a.flac", @"b.flac", @"a.flac"];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text], expected);
}

- (void)testCueNonFileLinesIgnored {
    NSString *text = @"TITLE \"An Album\"\nREM FILE \"not-this.flac\"\nFILENAME nope\n";
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text], @[]);
}

- (void)testCueCarriageReturnLineEndings {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \"a.flac\" WAVE\r\nFILE \"b.flac\" WAVE\r\n"],
                          (@[@"a.flac", @"b.flac"]));
}

- (void)testCueEveryTypeKeywordIsStripped {
    for (NSString *keyword in @[@"WAVE", @"MP3", @"AIFF", @"BINARY", @"MOTOROLA", @"FLAC"]) {
        NSString *line = [NSString stringWithFormat:@"FILE track.wav %@\n", keyword];
        XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:line], @[@"track.wav"], @"%@", keyword);
    }
}

- (void)testCueTypeKeywordStripIsCaseInsensitive {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE track.mp3 mp3\n"], @[@"track.mp3"]);
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE track.wav Wave\n"], @[@"track.wav"]);
}

// Only the six known keywords are stripped, so an unknown trailing token is
// part of the name — a file really called "track.mp3 OGG" is likelier than a
// writer inventing a type.
- (void)testCueUnknownTrailingTokenStaysInTheName {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE track.mp3 OGG\n"], @[@"track.mp3 OGG"]);
}

- (void)testCueBareKeywordIsTakenAsTheName {
    // Nothing else on the line to be the name, so "WAVE" is it. Absurd input,
    // but it must produce an entry rather than an empty one.
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE WAVE\n"], @[@"WAVE"]);
}

- (void)testCueEmptyAndWhitespaceOnlyNamesAreDropped {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \"\" WAVE\n"], @[]);
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \n"], @[]);
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE\n"], @[]);
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE\"\"\n"], @[]);
}

// A quoted name is delimited by the next quote, full stop — CUE has no escape
// syntax, so there is nothing else it could mean.
- (void)testCueQuotedNameEndsAtTheNextQuote {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \"a\"b.flac\" WAVE\n"], @[@"a"]);
}

- (void)testCueQuotedNameKeepsItsSurroundingSpaces {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE \" spaced .flac \" WAVE\n"],
                          @[@" spaced .flac "]);
}

- (void)testCueUnquotedBackslashPathNormalizes {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE C:\\Rips\\track.wav WAVE\n"],
                          @[@"C:/Rips/track.wav"]);
}

// KNOWN LIMIT, pinned rather than endorsed: the keyword test is "FILE" plus a
// literal space, so a tab-delimited FILE line is not recognized at all. No CUE
// writer in the wild emits one; if one turns up, this is the test to change.
// A tab-delimiting writer's sheet must not parse to zero entries — the
// keyword accepts any whitespace separator.
- (void)testCueTabAfterTheKeywordIsAccepted {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE\t\"a.flac\"\tWAVE\n"],
                          @[@"a.flac"]);
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE\ttrack.mp3\tMP3\n"],
                          @[@"track.mp3"]);
}

- (void)testCueExtraSpacesAroundTheNameAreAbsorbed {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"   FILE    \"a.flac\"    WAVE   \n"],
                          @[@"a.flac"]);
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@"FILE   track.mp3    MP3\n"], @[@"track.mp3"]);
}

- (void)testCueNonASCIINamesSurviveIntact {
    NSString *text = @"FILE \"Björk — Jóga.flac\" WAVE\nFILE \"01 🎧 mix.flac\" WAVE\n";
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text],
                          (@[@"Björk — Jóga.flac", @"01 🎧 mix.flac"]));
}

- (void)testCueEmptyTextYieldsNoEntries {
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:@""], @[]);
}

// The collapse compares against the previous entry only, so a duplicate
// separated by a dropped line still collapses — the dropped line never became
// an entry.
- (void)testCueDuplicatesSeparatedByIgnoredLinesStillCollapse {
    NSString *text = @"FILE \"image.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nFILE \"image.flac\" WAVE\n";
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text], @[@"image.flac"]);
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

// The comment test runs after the trim, so an indented directive is still a
// directive — and a file whose name starts with # is unreachable, which is the
// format's own limitation.
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

// stringByRemovingPercentEncoding answers nil for a malformed escape, and the
// raw remainder is better than dropping the entry: the file may really be
// called that.
- (void)testM3UMalformedPercentEscapeFallsBackToTheRawPath {
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:@"file:///Users/me/100%ZZ done.mp3\n"],
                          @[@"/Users/me/100%ZZ done.mp3"]);
}

- (void)testM3UNonFileSchemesAreDroppedWhereverTheSchemeAppears {
    NSString *text = @"smb://server/share/a.mp3\nrtsp://x/y\nmms://z\nfeed://q\nkeep.mp3\n";
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], @[@"keep.mp3"]);
}

// A Windows drive path has a colon but no "://", so it is a path, not a URL,
// and the separators normalize.
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
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text], @[@"a.flac"]);
}

- (void)testWindows1252Fallback {
    // 0x80 is € in CP1252 and invalid as UTF-8, so this exercises the fallback.
    NSMutableData *data = [[@"FILE \"caf" dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [data appendBytes:"\x80" length:1];
    [data appendData:[@".mp3\" MP3" dataUsingEncoding:NSASCIIStringEncoding]];
    NSString *text = [PlaylistFile textFromData:data];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text], @[@"caf€.mp3"]);
}

- (void)testUTF16LEWithBOM {
    NSData *data = [@"FILE \"a.flac\" WAVE" dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    NSMutableData *bom = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
    [bom appendData:data];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:[PlaylistFile textFromData:bom]], @[@"a.flac"]);
}

- (void)testEmptyDataReturnsNil {
    XCTAssertNil([PlaylistFile textFromData:[NSData data]]);
}

- (void)testUTF16BEWithBOM {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xFE\xFF" length:2];
    [data appendData:[@"FILE \"a.flac\" WAVE" dataUsingEncoding:NSUTF16BigEndianStringEncoding]];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:[PlaylistFile textFromData:data]], @[@"a.flac"]);
}

// No BOM, so the NUL heuristic decides: the zeros sit on the high half of each
// code unit, and which side they land on is the byte order. Without it the
// CP1252 backstop renders the whole sheet as NUL-riddled mojibake.
- (void)testBOMlessUTF16LittleEndianIsDetected {
    NSData *data = [@"FILE \"a.flac\" WAVE\nFILE \"b.flac\" WAVE\n"
            dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:[PlaylistFile textFromData:data]],
                          (@[@"a.flac", @"b.flac"]));
}

- (void)testBOMlessUTF16BigEndianIsDetected {
    NSData *data = [@"FILE \"a.flac\" WAVE\nFILE \"b.flac\" WAVE\n"
            dataUsingEncoding:NSUTF16BigEndianStringEncoding];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:[PlaylistFile textFromData:data]],
                          (@[@"a.flac", @"b.flac"]));
}

// The five bytes CP1252 leaves undefined. Latin-1 maps every byte, so the last
// rung cannot fail and the playlist is never dropped outright — mojibake in
// one odd filename costs one entry, a nil text costs all of them.
- (void)testLatin1BackstopTakesBytesCP1252Rejects {
    NSMutableData *data = [[@"FILE \"x" dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [data appendBytes:"\x81\x8D\x8F\x90\x9D" length:5];
    [data appendData:[@".mp3\" MP3" dataUsingEncoding:NSASCIIStringEncoding]];
    NSString *text = [PlaylistFile textFromData:data];
    XCTAssertNotNil(text);
    NSArray<NSString *> *entries = [PlaylistFile cueFileEntriesInText:text];
    XCTAssertEqual(entries.count, 1u);
    XCTAssertTrue([entries.firstObject hasPrefix:@"x"]);
    XCTAssertTrue([entries.firstObject hasSuffix:@".mp3"]);
}

// The UTF-16 pre-check demands a NUL on the same side of every code unit and
// none at all on the other. One corrupt byte in an otherwise UTF-8 file must
// not flip the whole thing to UTF-16 and turn every name into mojibake.
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

// A NUL or an unpaired surrogate in a name made NSURL answer nil for the
// candidate, and the nil went straight into an array — an exception on a
// background expansion worker, which is a crash on opening a corrupted
// playlist. Both are dropped from the name now.
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
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:sheet], @[@"xy.flac"]);
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
    // é as UTF-8 is C3 A9, which CP1252 would render "Ã©" — decoding order is
    // what keeps a modern playlist from being mangled by the legacy rungs.
    NSData *data = [@"FILE \"café.mp3\" MP3" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:[PlaylistFile textFromData:data]],
                          @[@"café.mp3"]);
}

- (void)testTruncatedUTF16StillDecodesToSomething {
    // An odd byte count cannot be UTF-16; the text must still come back rather
    // than taking the playlist down with it.
    NSMutableData *data = [NSMutableData dataWithBytes:"\xFF\xFE" length:2];
    [data appendData:[@"FILE \"a.flac\"" dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
    [data appendBytes:"\x41" length:1];
    XCTAssertNotNil([PlaylistFile textFromData:data]);
}

- (void)testABOMOnlyFileDecodesToNoEntries {
    NSData *utf8 = [NSData dataWithBytes:"\xEF\xBB\xBF" length:3];
    XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:[PlaylistFile textFromData:utf8]], @[]);
    NSData *utf16 = [NSData dataWithBytes:"\xFF\xFE" length:2];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:[PlaylistFile textFromData:utf16]], @[]);
}

// Writers that prepend a BOM to a file that already had one do exist, and two
// are absorbed: the UTF-8 decoder eats the first, the explicit strip takes the
// second. A surviving U+FEFF would ride along in the first entry's name and
// make it resolve to nothing.
- (void)testADoubleLeadingBOMLeavesNothingInTheName {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xEF\xBB\xBF\xEF\xBB\xBF" length:6];
    [data appendData:[@"a.mp3" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:[PlaylistFile textFromData:data]], @[@"a.mp3"]);
}

#pragma mark - resolvedFileURLsForPlaylistAtURL:

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
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]];
    NSArray *names = [urls valueForKeyPath:@"lastPathComponent"];
    XCTAssertEqualObjects(names, (@[@"one.mp3", @"two.mp3"]));
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.path, dir.path);
}

- (void)testM3UResolvesRelativeEntriesAgainstItsFolder {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3", @"two.mp3"]
                               playlistName:@"mix.m3u8"
                                       text:@"#EXTM3U\none.mp3\ntwo.mp3\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"mix.m3u8"]];
    NSArray *names = [urls valueForKeyPath:@"lastPathComponent"];
    XCTAssertEqualObjects(names, (@[@"one.mp3", @"two.mp3"]));
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.path, dir.path);
}

- (void)testWindowsAbsolutePathFallsBackToBasenameBesidePlaylist {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.wav"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"C:\\Rips\\track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.wav");
    XCTAssertTrue([NSFileManager.defaultManager isReadableFileAtPath:urls.firstObject.path]);
}

- (void)testAlternateExtensionBesidePlaylist {
    // The cue was written for the .wav rip; the files are .flac now.
    NSURL *dir = [self makeTempDirWithFiles:@[@"track01.flac", @"track02.flac"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"track01.wav\" WAVE\nFILE \"track02.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]];
    NSArray *names = [urls valueForKeyPath:@"lastPathComponent"];
    XCTAssertEqualObjects(names, (@[@"track01.flac", @"track02.flac"]));
}

- (void)testAlternateExtensionInSubdirectory {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"mix.m3u" text:@"disc1/track.wav\n"];
    NSURL *sub = [dir URLByAppendingPathComponent:@"disc1"];
    [NSFileManager.defaultManager createDirectoryAtURL:sub withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToURL:[sub URLByAppendingPathComponent:@"track.mp3"] atomically:YES];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"mix.m3u"]];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.mp3");
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.lastPathComponent, @"disc1");
}

- (void)testExactNameBeatsAlternateExtension {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.wav", @"track.flac"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.wav");
}

- (void)testWindowsPathWithAlternateExtension {
    // Both rescues at once: strip the foreign path AND swap the extension.
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.aiff"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"C:\\Rips\\track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"album.cue"]];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.aiff");
}

- (void)testMissingEntryStillYieldsPrimaryCandidate {
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"mix.m3u" text:@"gone.mp3\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:[dir URLByAppendingPathComponent:@"mix.m3u"]];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"gone.mp3");
}

- (void)testUnreadablePlaylistReturnsEmpty {
    NSURL *missing = [NSURL fileURLWithPath:@"/nonexistent/album.cue"];
    XCTAssertEqualObjects([PlaylistFile resolvedFileURLsForPlaylistAtURL:missing], @[]);
}

- (void)testAnEmptyPlaylistFileReturnsEmpty {
    NSURL *dir = [self makeTempDirWithFiles:@[@"a.mp3"] playlistName:@"mix.m3u" text:@""];
    XCTAssertEqualObjects([PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]], @[]);
}

// Which parser runs is decided by the extension, folded — a sheet from a
// Windows tool is as likely to be ALBUM.CUE as album.cue, and parsing it as
// M3U would read every FILE line as a filename.
- (void)testAnUppercaseCueExtensionStillParsesAsCue {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"]
                               playlistName:@"ALBUM.CUE"
                                       text:@"FILE \"one.mp3\" MP3\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"ALBUM.CUE"]];
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"], @[@"one.mp3"]);
}

// Everything that is not a cue takes the M3U reader, .m3u8 and anything else
// alike; the caller only ever hands over extensions isPlaylistExtension:
// admitted, so this is the else branch, not a guess.
- (void)testANonCueExtensionTakesTheM3UReader {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"]
                               playlistName:@"list.m3u8"
                                       text:@"#EXTM3U\none.mp3\n"];
    XCTAssertEqualObjects([[PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"list.m3u8"]] valueForKeyPath:@"lastPathComponent"],
                          @[@"one.mp3"]);
}

- (void)testAnAbsoluteEntryThatExistsResolvesToItself {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"] playlistName:@"mix.m3u" text:@""];
    NSURL *absolute = [dir URLByAppendingPathComponent:@"one.mp3"];
    NSURL *playlist = [dir URLByAppendingPathComponent:@"mix.m3u"];
    [[[NSString stringWithFormat:@"%@\n", absolute.path] dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:playlist atomically:YES];

    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:playlist];
    XCTAssertEqualObjects([urls.firstObject.path stringByStandardizingPath],
                          [absolute.path stringByStandardizingPath]);
}

- (void)testEveryEntryProducesExactlyOneURLInOrder {
    NSURL *dir = [self makeTempDirWithFiles:@[@"b.mp3"]
                               playlistName:@"mix.m3u"
                                       text:@"gone.mp3\nb.mp3\ngone.mp3\nb.mp3\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]];
    // Duplicates are the playlist's prerogative, and a missing entry still
    // occupies its slot: the caller decides what to do with each, so the
    // arrays must line up one for one with the entries.
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"],
                          (@[@"gone.mp3", @"b.mp3", @"gone.mp3", @"b.mp3"]));
}

- (void)testAnEntryNamingADirectoryResolvesToIt {
    // isReadableFileAtPath: is true of a directory, so the rungs can land on
    // one. Harmless in the app — the open funnel's extension filter drops it
    // — but pinned so a change in that filter does not quietly start opening
    // folders as tracks.
    NSURL *dir = [self makeTempDirWithFiles:@[] playlistName:@"mix.m3u" text:@"disc1\n"];
    [NSFileManager.defaultManager createDirectoryAtURL:[dir URLByAppendingPathComponent:@"disc1"]
                           withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]];
    XCTAssertEqualObjects([urls valueForKeyPath:@"lastPathComponent"], @[@"disc1"]);
}

- (void)testTheBesideRungWinsWhenTheNamedSubfolderIsMissing {
    // The sheet says disc2/track.wav, the rip was flattened: the basename
    // beside the playlist is the rescue, and the alternate extension applies
    // to it as well.
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.flac"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"disc2/track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"album.cue"]];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.flac");
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.path, dir.path);
}

// The primary is tried under every alternate extension before the beside
// candidates' alternates, so a subfolder hit beats a flattened one.
- (void)testThePrimaryFolderBeatsTheBesideRungForTheSameAlternate {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.flac"] playlistName:@"mix.m3u" text:@"disc1/track.wav\n"];
    NSURL *sub = [dir URLByAppendingPathComponent:@"disc1"];
    [NSFileManager.defaultManager createDirectoryAtURL:sub withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData data] writeToURL:[sub URLByAppendingPathComponent:@"track.flac"] atomically:YES];

    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]];
    XCTAssertEqualObjects(urls.firstObject.URLByDeletingLastPathComponent.lastPathComponent, @"disc1");
}

- (void)testTheAlternateExtensionsAreTriedInDeclaredOrder {
    // wav, aif, aiff, flac, mp3 — the first that exists wins, so seeding two
    // pins the order rather than just the membership.
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.mp3", @"track.aif"]
                               playlistName:@"album.cue"
                                       text:@"FILE \"track.wav\" WAVE\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"album.cue"]];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"track.aif");
}

- (void)testAnExtensionlessEntryStillTriesTheAlternates {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.flac"]
                               playlistName:@"mix.m3u"
                                       text:@"track\n"];
    XCTAssertEqualObjects([[PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]] valueForKeyPath:@"lastPathComponent"],
                          @[@"track.flac"]);
}

- (void)testARelativeEntryWithDotSegmentsIsStandardized {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3"]
                               playlistName:@"mix.m3u"
                                       text:@"./one.mp3\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]];
    XCTAssertEqualObjects(urls.firstObject.lastPathComponent, @"one.mp3");
    XCTAssertFalse([urls.firstObject.path containsString:@"/./"]);
}

// End to end for the encoding trap: a Windows-authored UTF-16 sheet of plain
// ASCII filenames used to read as an empty playlist, because UTF-16 ASCII is
// valid UTF-8 and so never reached the byte-order heuristic.
- (void)testABOMlessUTF16SheetOnDiskResolvesItsEntries {
    NSURL *dir = [self makeTempDirWithFiles:@[@"one.mp3", @"two.mp3"] playlistName:@"seed.cue" text:@""];
    NSURL *playlist = [dir URLByAppendingPathComponent:@"album.cue"];
    NSString *sheet = @"FILE \"one.mp3\" MP3\n  TRACK 01 AUDIO\nFILE \"two.mp3\" MP3\n";
    for (NSNumber *encoding in @[@(NSUTF16LittleEndianStringEncoding), @(NSUTF16BigEndianStringEncoding)]) {
        [[sheet dataUsingEncoding:encoding.unsignedIntegerValue] writeToURL:playlist atomically:YES];
        XCTAssertEqualObjects([[PlaylistFile resolvedFileURLsForPlaylistAtURL:playlist]
                                      valueForKeyPath:@"lastPathComponent"],
                              (@[@"one.mp3", @"two.mp3"]), @"encoding %@", encoding);
    }
}

- (void)testANonASCIIEntryResolvesToItsFileOnDisk {
    NSURL *dir = [self makeTempDirWithFiles:@[@"Jóga 🎧.mp3"]
                               playlistName:@"mix.m3u"
                                       text:@"Jóga 🎧.mp3\n"];
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [dir URLByAppendingPathComponent:@"mix.m3u"]];
    XCTAssertEqual(urls.count, 1u);
    XCTAssertTrue([NSFileManager.defaultManager isReadableFileAtPath:urls.firstObject.path]);
}

@end
