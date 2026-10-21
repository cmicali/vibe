//
//  PlaylistFileTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>
#import "PlaylistFileTestCase.h"
#import "PlaylistFile.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "FakeTrackMetadata.h"

@interface PlaylistFileTests : PlaylistFileTestCase
@end

@implementation PlaylistFileTests

#pragma mark - isPlaylistExtension:

- (void)testPlaylistExtensions {
    XCTAssertTrue([PlaylistFile isPlaylistExtension:@"cue"]);
    XCTAssertTrue([PlaylistFile isPlaylistExtension:@"m3u"]);
    XCTAssertTrue([PlaylistFile isPlaylistExtension:@"m3u8"]);
    XCTAssertFalse([PlaylistFile isPlaylistExtension:@"mp3"]);
    XCTAssertTrue([PlaylistFile isM3UExtension:@"m3u8"]);
    XCTAssertFalse([PlaylistFile isM3UExtension:@"cue"]);
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
    // Accept paths from writers that omit percent-encoding.
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

- (void)testAnApeBesideTheEntryIsNotAFallback {
    NSURL *dir = [self makeTempDirWithFiles:@[@"track.ape"]
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
    FakeTrackMetadata *metadata = [FakeTrackMetadata new];
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

@end
