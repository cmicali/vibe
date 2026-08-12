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

@end
