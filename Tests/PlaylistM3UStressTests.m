//
//  PlaylistM3UStressTests.m
//  VibeTests
//
//  Pathological M3U playlists: corrupt structure, hostile URLs, absurd scale.
//  The contract under all of it — never crash, never hang, and never emit an
//  entry the resolver cannot treat as a path.
//

#import <XCTest/XCTest.h>
#import "PlaylistFile.h"

@interface PlaylistM3UStressTests : XCTestCase
@end

@implementation PlaylistM3UStressTests

// What every survivor must satisfy, whatever went in: something to resolve,
// not a directive, and no Windows separator left for the resolver to trip on.
- (void)assertResolvable:(NSArray<NSString *> *)entries from:(NSString *)what {
    for (NSString *entry in entries) {
        XCTAssertGreaterThan(entry.length, 0u, @"empty entry from %@", what);
        // No blanket rule against a leading '#': it marks a comment only on a
        // raw line, and a file:// URL reduces to a path that may legitimately
        // start with one, since #track.mp3 is a filename. The directive tests
        // pin that rule on the inputs where it applies.
        XCTAssertEqual([entry rangeOfString:@"\\"].location, (NSUInteger)NSNotFound,
                       @"backslash survived from %@: %@", what, entry);
        // Only a scheme separator makes a line a URL. Corruption that removes
        // it leaves a nonsense relative path, which resolution discards — the
        // rule here is the parser's, not "no line may start with http".
        if ([entry rangeOfString:@"://"].location != NSNotFound) {
            for (NSString *scheme in @[@"http:", @"https:", @"rtsp:", @"mms:", @"ftp:"]) {
                XCTAssertFalse([entry.lowercaseString hasPrefix:scheme],
                               @"stream URL survived from %@: %@", what, entry);
            }
        }
    }
}

- (NSArray<NSString *> *)parse:(NSString *)text {
    NSArray<NSString *> *entries = [PlaylistFile m3uEntriesInText:text];
    XCTAssertNotNil(entries);
    [self assertResolvable:entries from:[text substringToIndex:MIN((NSUInteger)40, text.length)]];
    return entries;
}

#pragma mark - Structure and directives

- (void)testEmptyAndWhitespaceOnly {
    XCTAssertEqual([self parse:@""].count, 0u);
    XCTAssertEqual([self parse:@"\n\n\n"].count, 0u);
    XCTAssertEqual([self parse:@"  \t \r\n \t "].count, 0u);
}

- (void)testDirectivesOnly {
    XCTAssertEqual([self parse:
            @"#EXTM3U\n#EXTINF:123,Artist - Title\n#EXTALB:Album\n#\n#####\n"].count, 0u);
}

- (void)testExtinfDoesNotLeakIntoEntries {
    NSArray<NSString *> *entries = [self parse:
            @"#EXTM3U\n#EXTINF:123,Artist - Title\na.mp3\n#EXTINF:-1,Another\nb.mp3\n"];
    XCTAssertEqualObjects(entries, (@[@"a.mp3", @"b.mp3"]));
}

- (void)testCommentAfterIndentationIsStillADirective {
    XCTAssertEqual([self parse:@"   \t #EXTINF:1,x\n"].count, 0u);
}

- (void)testDuplicatesArePreserved {
    NSArray<NSString *> *entries = [self parse:@"a.mp3\na.mp3\na.mp3\n"];
    XCTAssertEqual(entries.count, 3u, @"repeating a track is a playlist's prerogative");
}

- (void)testEveryLineEndingStyle {
    for (NSString *eol in @[@"\n", @"\r\n", @"\r", @"\u2028", @"\u2029"]) {
        NSString *text = [NSString stringWithFormat:@"a.mp3%@b.mp3%@", eol, eol];
        XCTAssertEqual([self parse:text].count, 2u, @"line ending %@ lost an entry", @(eol.UTF8String));
    }
}

- (void)testNoTrailingNewline {
    XCTAssertEqual([self parse:@"a.mp3\nb.mp3"].count, 2u);
}

#pragma mark - URLs

- (void)testFileURLsReduceToPaths {
    NSArray<NSString *> *entries = [self parse:
            @"file:///Music/a.mp3\n"
             "file://localhost/Music/b.mp3\n"
             "file:///Music/with%20space.mp3\n"];
    XCTAssertEqualObjects(entries, (@[@"/Music/a.mp3", @"/Music/b.mp3", @"/Music/with space.mp3"]));
}

- (void)testFileURLWithRawSpacesWhichNSURLRefuses {
    NSArray<NSString *> *entries = [self parse:@"file:///Music/raw space.mp3\n"];
    XCTAssertEqualObjects(entries.firstObject, @"/Music/raw space.mp3");
}

- (void)testStreamSchemesAreDropped {
    XCTAssertEqual([self parse:
            @"http://example.com/a.mp3\n"
             "https://example.com/b.mp3\n"
             "rtsp://example.com/c\n"
             "mms://example.com/d\n"
             "ftp://example.com/e.mp3\n"
             "HTTP://EXAMPLE.COM/F.MP3\n"].count, 0u);
}

- (void)testDegenerateFileURLs {
    // Each of these has reduced to nothing; none may crash or emit an empty
    // entry.
    [self parse:@"file://\n"];
    [self parse:@"file:///\n"];
    [self parse:@"file://localhost/\n"];
    [self parse:@"file://:\n"];
    [self parse:@"://\n"];
    [self parse:@"file://%\n"];
    [self parse:@"file://%ZZ%%%2\n"];
    [self parse:@"file:///%00\n"];
}

- (void)testMalformedPercentEncodingDoesNotCrash {
    NSArray<NSString *> *entries = [self parse:
            @"file:///Music/%.mp3\n"
             "file:///Music/%A.mp3\n"
             "file:///Music/%ZZ.mp3\n"
             "file:///Music/%%%%.mp3\n"];
    [self assertResolvable:entries from:@"malformed percent encodings"];
}

- (void)testWindowsPathsAreNormalized {
    NSArray<NSString *> *entries = [self parse:
            @"C:\\Music\\a.mp3\n"
             "\\\\server\\share\\b.mp3\n"
             "..\\relative\\c.mp3\n"];
    XCTAssertEqualObjects(entries, (@[@"C:/Music/a.mp3", @"//server/share/b.mp3", @"../relative/c.mp3"]));
}

- (void)testPathContainingSchemeSeparator {
    // Not a URL anyone meant, but it reads as one; dropping it is fine, and
    // crashing or emitting a half-parsed path is not.
    [self parse:@"/Music/weird :// name.mp3\n"];
    [self parse:@"a://b\n"];
}

#pragma mark - Hostile characters

- (void)testControlCharactersAndNULs {
    NSArray<NSString *> *entries = [self parse:@"a\x01\x02.mp3\nb\0c.mp3\n\x7f.mp3\n"];
    [self assertResolvable:entries from:@"control characters"];
}

- (void)testUnicodePathsSurviveIntact {
    NSArray<NSString *> *entries = [self parse:@"日本語/曲.mp3\nBjörk – Jóga.mp3\n🎧/track.mp3\n"];
    XCTAssertEqualObjects(entries.firstObject, @"日本語/曲.mp3");
    XCTAssertEqualObjects(entries[1], @"Björk – Jóga.mp3");
    XCTAssertEqualObjects(entries[2], @"🎧/track.mp3");
}

- (void)testVeryLongEntry {
    NSString *long1 = [@"" stringByPaddingToLength:200000 withString:@"A" startingAtIndex:0];
    NSArray<NSString *> *entries = [self parse:[NSString stringWithFormat:@"%@.mp3\n", long1]];
    XCTAssertEqual(entries.count, 1u);
    XCTAssertEqual(entries.firstObject.length, long1.length + 4);
}

- (void)testOneEnormousLineWithNoBreaks {
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0; i < 5000; i++) {
        [text appendString:@"a.mp3 "];
    }
    XCTAssertEqual([self parse:text].count, 1u, @"one line is one entry, however long");
}

#pragma mark - Byte-level decoding

- (void)testArbitraryBytesNeverThrow {
    uint32_t seed = 0xB16B00B5;
    for (NSUInteger round = 0; round < 300; round++) {
        NSMutableData *data = [NSMutableData dataWithLength:1 + (round * 11) % 512];
        uint8_t *bytes = data.mutableBytes;
        for (NSUInteger i = 0; i < data.length; i++) {
            seed = seed * 1664525u + 1013904223u;
            bytes[i] = (uint8_t)(seed >> 24);
        }
        NSString *text = [PlaylistFile textFromData:data];
        if (text) {
            [self parse:text];
        }
    }
}

- (void)testDecodesEveryEncodingIncludingBomlessUTF16 {
    NSString *source = @"#EXTM3U\n#EXTINF:1,x\nMusic/a.mp3\nMusic/b.mp3\n";
    NSArray<NSNumber *> *encodings = @[@(NSUTF8StringEncoding), @(NSUTF16LittleEndianStringEncoding),
                                       @(NSUTF16BigEndianStringEncoding), @(NSUTF16StringEncoding),
                                       @(NSWindowsCP1252StringEncoding), @(NSISOLatin1StringEncoding)];
    for (NSNumber *encoding in encodings) {
        NSData *data = [source dataUsingEncoding:encoding.unsignedIntegerValue];
        if (!data) {
            continue;
        }
        NSString *text = [PlaylistFile textFromData:data];
        XCTAssertNotNil(text, @"encoding %@ failed to decode", encoding);
        XCTAssertEqual([self parse:text].count, 2u, @"encoding %@ lost entries", encoding);
    }
}

#pragma mark - Scale

- (void)testFiftyThousandEntries {
    NSMutableString *text = [NSMutableString stringWithString:@"#EXTM3U\n"];
    for (NSUInteger i = 0; i < 50000; i++) {
        [text appendFormat:@"#EXTINF:%lu,T%lu\nMusic/track%lu.mp3\n",
                           (unsigned long)i, (unsigned long)i, (unsigned long)i];
    }
    NSDate *start = NSDate.date;
    NSArray<NSString *> *entries = [PlaylistFile m3uEntriesInText:text];
    NSTimeInterval elapsed = -start.timeIntervalSinceNow;
    XCTAssertEqual(entries.count, 50000u);
    XCTAssertLessThan(elapsed, 5.0, @"50k entries took %.2fs", elapsed);
}

#pragma mark - Fuzz

// Seeded mutations of a valid playlist: corrupt bytes, split lines, inject the
// comment marker and the scheme separator, which are the two characters that
// change how a line is read.
- (void)testFuzzedMutationsOfAValidPlaylist {
    NSString *valid =
            @"#EXTM3U\n"
             "#EXTINF:123,Artist - One\n"
             "Music/one.mp3\n"
             "#EXTINF:456,Artist - Two\n"
             "file:///Music/two%20beta.mp3\n"
             "..\\windows\\three.mp3\n"
             "http://example.com/stream\n";
    NSData *validData = [valid dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t seed = 0xFEEDFACE;
    for (NSUInteger round = 0; round < 2000; round++) {
        NSMutableData *data = [validData mutableCopy];
        uint8_t *bytes = data.mutableBytes;
        seed = seed * 1664525u + 1013904223u;
        NSUInteger edits = 1 + (seed >> 28);
        for (NSUInteger e = 0; e < edits; e++) {
            seed = seed * 1664525u + 1013904223u;
            NSUInteger at = (seed >> 8) % data.length;
            seed = seed * 1664525u + 1013904223u;
            switch ((seed >> 16) % 5) {
                case 0: bytes[at] = (uint8_t)(seed >> 24); break; // corrupt
                case 1: bytes[at] = '\n'; break;                  // split a line
                case 2: bytes[at] = '#'; break;                   // make it a directive
                case 3: bytes[at] = ':'; break;                   // forge a scheme
                case 4: bytes[at] = '%'; break;                   // break an escape
            }
        }
        NSString *text = [PlaylistFile textFromData:data];
        if (!text) {
            continue;
        }
        NSArray<NSString *> *entries = [PlaylistFile m3uEntriesInText:text];
        XCTAssertNotNil(entries);
        [self assertResolvable:entries
                          from:[NSString stringWithFormat:@"fuzz round %lu", (unsigned long)round]];
    }
}


#pragma mark - Resolution

// The parser's output is not the end of the line: resolvedFileURLsForPlaylistAtURL:
// turns every entry into a URL, and an entry that is not a usable path
// component must be dropped there rather than reaching NSURL and coming back
// nil.
- (NSURL *)writePlaylist:(NSData *)data named:(NSString *)name {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"M3UStress-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    }];
    NSURL *url = [dir URLByAppendingPathComponent:name];
    [data writeToURL:url atomically:YES];
    return url;
}

- (void)testEntriesWithNULsResolveWithoutCrashing {
    NSMutableData *data = [NSMutableData data];
    [data appendBytes:"good.mp3\n" length:9];
    [data appendBytes:"a\0b.mp3\n" length:8];   // NUL inside a path component
    [data appendBytes:"\0\0\0\n" length:4];     // nothing but NULs
    NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
            [self writePlaylist:data named:@"nuls.m3u"]];
    XCTAssertNotNil(urls);
    for (NSURL *url in urls) {
        XCTAssertNotNil(url, @"a nil URL would crash the array it goes into");
    }
}

- (void)testRandomBytePlaylistsResolveWithoutCrashing {
    uint32_t seed = 0xDEADBEEF;
    for (NSUInteger round = 0; round < 60; round++) {
        NSMutableData *data = [NSMutableData dataWithLength:512];
        uint8_t *bytes = data.mutableBytes;
        for (NSUInteger i = 0; i < data.length; i++) {
            seed = seed * 1664525u + 1013904223u;
            bytes[i] = (uint8_t)(seed >> 24);
        }
        NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:
                [self writePlaylist:data named:@"junk.m3u"]];
        for (NSURL *url in urls) {
            XCTAssertNotNil(url, @"round %lu produced a nil URL", (unsigned long)round);
        }
    }
}


- (void)testBomlessUTF16WithFewNULsStillDecodes {
    // Long CJK filenames carry NULs on about a fifth of their code units — far
    // under the density test — so the catch after a failed UTF-8 decode is the
    // only thing standing between them and Latin-1 mojibake.
    NSString *source = @"日本語のとても長いファイル名前です第一曲.mp3\n日本語のとても長いファイル名前です第二曲.mp3\n";
    NSData *data = [source dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    NSString *text = [PlaylistFile textFromData:data];

    XCTAssertEqualObjects(text, source, @"decoded as something other than UTF-16");
    XCTAssertEqual([self parse:text].count, 2u);
}

@end
