//
//  PlaylistFileFuzzTests.m
//
//  Playlists arrive from other people's software and other people's disks, so
//  the readers have to survive anything: half-written files, wrong encodings,
//  truncated multi-byte sequences, megabyte-long lines, bytes that are not
//  text at all. Two shapes of fuzzing here.
//
//  Generated-and-known: build a random but well-formed sheet whose entries are
//  known up front, and demand exactly those back. This is the half that can
//  catch a reader that drops or reorders entries — invariants alone cannot,
//  since returning nothing satisfies every one of them.
//
//  Generated-and-corrupted: mutate bytes and assert only what must hold for
//  ANY input. No crash, no exception, and the output contract the callers rely
//  on — every entry non-empty, single-line, separator-normalized.
//
//  The generator is a seeded PRNG, so a failure reproduces exactly: the seed
//  is in every assertion message, and VIBE_FUZZ_SEED re-runs one.
//

#import <XCTest/XCTest.h>

#import "PlaylistFile.h"

// xorshift64*, chosen for being four lines rather than for its statistics.
typedef struct { uint64_t state; } FuzzRandom;

static uint64_t FuzzNext(FuzzRandom *random) {
    uint64_t x = random->state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    random->state = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static uint32_t FuzzBelow(FuzzRandom *random, uint32_t bound) {
    return bound ? (uint32_t)(FuzzNext(random) % bound) : 0;
}

static BOOL FuzzChance(FuzzRandom *random, uint32_t oneIn) {
    return FuzzBelow(random, oneIn) == 0;
}

@interface PlaylistFileFuzzTests : XCTestCase
@end

@implementation PlaylistFileFuzzTests {
    NSURL *_root;
    uint64_t _baseSeed;
}

- (void)setUp {
    [super setUp];
    NSString *override = NSProcessInfo.processInfo.environment[@"VIBE_FUZZ_SEED"];
    // Fixed by default: a suite that explores new inputs on every run passes
    // and fails at random, which is worse than a narrower suite that does not.
    _baseSeed = override ? (uint64_t)override.longLongValue : 0x5EED1234ABCDEF01ULL;
    _root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"PlaylistFuzz-%@",
                                                                      NSUUID.UUID.UUIDString]]
                       isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_root
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_root error:nil];
    [super tearDown];
}

#pragma mark - Generators

// Characters a filename may plausibly carry, quotes and separators included so
// the readers' own escaping rules get exercised rather than tiptoed around.
static NSString *FuzzName(FuzzRandom *random) {
    static NSArray<NSString *> *atoms;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        atoms = @[@"a", @"B", @"7", @" ", @"-", @"_", @".", @"(", @")", @"[", @"]",
                  @"&", @"'", @"é", @"ü", @"ß", @"日", @"🎧", @"—", @"+", @"#", @"%",
                  @"~", @"!", @",", @";", @"=", @"@", @"$"];
    });
    NSUInteger length = 1 + FuzzBelow(random, 24);
    NSMutableString *name = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [name appendString:atoms[FuzzBelow(random, (uint32_t)atoms.count)]];
    }
    [name appendString:@[@".mp3", @".flac", @".wav", @".aiff", @""][FuzzBelow(random, 5)]];
    return name;
}

// A name safe to put in a CUE sheet unquoted or in an M3U line: no quote, no
// leading or trailing space, and nothing the reader is entitled to reinterpret.
static NSString *FuzzPlainName(FuzzRandom *random) {
    NSString *name = FuzzName(random);
    name = [name stringByReplacingOccurrencesOfString:@"\"" withString:@"q"];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return name.length ? name : @"track.mp3";
}

// Lines a reader must skip. Every one of these has bitten a real playlist.
static NSString *FuzzCueNoiseLine(FuzzRandom *random) {
    static NSArray<NSString *> *lines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lines = @[@"REM GENRE Electronica", @"PERFORMER \"Someone\"", @"TITLE \"An Album\"",
                  @"  TRACK 01 AUDIO", @"    INDEX 01 00:00:00", @"    PREGAP 00:02:00",
                  @"REM FILE \"decoy.flac\"", @"FILENAME nope", @"", @"   ", @"\t",
                  @"CATALOG 1234567890123", @"FLAGS DCP", @"ISRC ABCDE1234567"];
    });
    return lines[FuzzBelow(random, (uint32_t)lines.count)];
}

static NSString *FuzzM3UNoiseLine(FuzzRandom *random) {
    static NSArray<NSString *> *lines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lines = @[@"#EXTM3U", @"#EXTINF:123,Artist - Title", @"#EXTVLCOPT:no-video",
                  @"#", @"# a comment", @"   #EXTINF:-1,x", @"", @"   ", @"\t",
                  @"http://example.com/stream.mp3", @"https://example.com/radio",
                  @"rtsp://host/path", @"mms://host"];
    });
    return lines[FuzzBelow(random, (uint32_t)lines.count)];
}

static NSString *FuzzLineEnding(FuzzRandom *random) {
    return @[@"\n", @"\r\n", @"\r"][FuzzBelow(random, 3)];
}

#pragma mark - Oracles

// The reader's rule, restated independently: consecutive duplicates collapse,
// case-insensitively.
static NSArray<NSString *> *CollapsingConsecutiveDuplicates(NSArray<NSString *> *names) {
    NSMutableArray<NSString *> *expected = [NSMutableArray array];
    for (NSString *name in names) {
        if (expected.count > 0 && [expected.lastObject caseInsensitiveCompare:name] == NSOrderedSame) {
            continue;
        }
        [expected addObject:name];
    }
    return expected;
}

static NSString *NormalizedSeparators(NSString *name) {
    return [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

#pragma mark - Well-formed sheets, known answers

- (void)testGeneratedCueSheetsYieldExactlyTheirFileEntries {
    for (NSUInteger round = 0; round < 400; round++) {
        @autoreleasepool {
            uint64_t seed = _baseSeed + round;
            FuzzRandom random = {seed};
            NSMutableString *sheet = [NSMutableString string];
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            NSUInteger fileLines = FuzzBelow(&random, 12);
            for (NSUInteger i = 0; i < fileLines; i++) {
                // Sometimes repeat the previous name: the single-image sheet
                // that names its FILE before every TRACK.
                NSString *name = (names.count && FuzzChance(&random, 3))
                        ? names.lastObject
                        : FuzzPlainName(&random);
                [names addObject:name];
                NSUInteger noise = FuzzBelow(&random, 3);
                for (NSUInteger n = 0; n < noise; n++) {
                    [sheet appendFormat:@"%@%@", FuzzCueNoiseLine(&random), FuzzLineEnding(&random)];
                }
                // Quoted, since an unquoted name would meet the type-keyword
                // strip and the oracle would have to model it too.
                NSString *indent = FuzzChance(&random, 3) ? @"  " : @"";
                NSString *keyword = FuzzChance(&random, 2) ? @"" : @[@" WAVE", @" MP3", @" FLAC"][FuzzBelow(&random, 3)];
                NSString *file = FuzzChance(&random, 4) ? @"file" : @"FILE";
                [sheet appendFormat:@"%@%@ \"%@\"%@%@", indent, file, name, keyword, FuzzLineEnding(&random)];
            }

            NSArray<NSString *> *expected = CollapsingConsecutiveDuplicates(names);
            NSArray<NSString *> *entries = [PlaylistFile cueFileEntriesInText:sheet];
            XCTAssertEqualObjects(entries, expected, @"seed %llu", seed);
        }
    }
}

- (void)testGeneratedM3UListsYieldExactlyTheirEntriesInOrder {
    for (NSUInteger round = 0; round < 400; round++) {
        @autoreleasepool {
            uint64_t seed = _baseSeed + 100000 + round;
            FuzzRandom random = {seed};
            NSMutableString *list = [NSMutableString string];
            NSMutableArray<NSString *> *expected = [NSMutableArray array];
            NSUInteger entryLines = FuzzBelow(&random, 14);
            for (NSUInteger i = 0; i < entryLines; i++) {
                NSUInteger noise = FuzzBelow(&random, 3);
                for (NSUInteger n = 0; n < noise; n++) {
                    [list appendFormat:@"%@%@", FuzzM3UNoiseLine(&random), FuzzLineEnding(&random)];
                }
                NSString *name = FuzzPlainName(&random);
                // A '#' only comments a line out at the start, after trimming.
                if ([name hasPrefix:@"#"]) {
                    name = [@"x" stringByAppendingString:name];
                }
                NSString *written = name;
                if (FuzzChance(&random, 4)) {
                    written = [NSString stringWithFormat:@"disc1\\%@", name];
                }
                // Surrounding whitespace is the writer's, not the name's.
                NSString *padded = FuzzChance(&random, 3)
                        ? [NSString stringWithFormat:@"  %@\t", written] : written;
                [expected addObject:NormalizedSeparators(written)];
                [list appendFormat:@"%@%@", padded, FuzzLineEnding(&random)];
            }

            NSArray<NSString *> *entries = [PlaylistFile m3uEntriesInText:list];
            XCTAssertEqualObjects(entries, expected, @"seed %llu", seed);
        }
    }
}

// The same sheets through every encoding the reader claims to accept. A
// playlist's meaning cannot depend on how its bytes were written down.
- (void)testAWellFormedSheetReadsTheSameThroughEveryAcceptedEncoding {
    NSArray<NSNumber *> *encodings = @[@(NSUTF8StringEncoding),
                                       @(NSUTF16StringEncoding),
                                       @(NSUTF16LittleEndianStringEncoding),
                                       @(NSUTF16BigEndianStringEncoding),
                                       @(NSWindowsCP1252StringEncoding),
                                       @(NSISOLatin1StringEncoding)];
    for (NSUInteger round = 0; round < 60; round++) {
        @autoreleasepool {
            uint64_t seed = _baseSeed + 200000 + round;
            FuzzRandom random = {seed};
            NSMutableString *list = [NSMutableString string];
            NSMutableArray<NSString *> *expected = [NSMutableArray array];
            for (NSUInteger i = 0; i < 1 + FuzzBelow(&random, 8); i++) {
                NSString *name = FuzzPlainName(&random);
                if ([name hasPrefix:@"#"]) {
                    name = [@"x" stringByAppendingString:name];
                }
                [expected addObject:name];
                [list appendFormat:@"%@\n", name];
            }

            for (NSNumber *encoding in encodings) {
                NSStringEncoding value = encoding.unsignedIntegerValue;
                NSData *data = [list dataUsingEncoding:value];
                if (!data) {
                    continue; // the single-byte encodings cannot carry 🎧
                }
                if (value == NSUTF8StringEncoding) {
                    NSMutableData *withBOM = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
                    [withBOM appendData:data];
                    data = withBOM;
                }
                NSString *text = [PlaylistFile textFromData:data];
                XCTAssertNotNil(text, @"seed %llu encoding %@", seed, encoding);
                XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], expected,
                                      @"seed %llu encoding %@", seed, encoding);
            }
        }
    }
}

#pragma mark - Corrupted bytes

// Bytes no writer would produce: random noise, plausible prefixes with garbage
// behind them, truncated multi-byte sequences, NUL runs, and a real playlist
// with its bytes chewed up.
static NSData *FuzzCorruptData(FuzzRandom *random) {
    NSMutableData *data = [NSMutableData data];
    switch (FuzzBelow(random, 8)) {
        case 0: { // pure noise
            NSUInteger length = FuzzBelow(random, 512);
            for (NSUInteger i = 0; i < length; i++) {
                uint8_t byte = (uint8_t)FuzzBelow(random, 256);
                [data appendBytes:&byte length:1];
            }
            break;
        }
        case 1: { // a BOM over noise
            static const char *boms[] = {"\xEF\xBB\xBF", "\xFF\xFE", "\xFE\xFF"};
            NSUInteger which = FuzzBelow(random, 3);
            [data appendBytes:boms[which] length:which == 0 ? 3 : 2];
            NSUInteger length = FuzzBelow(random, 256);
            for (NSUInteger i = 0; i < length; i++) {
                uint8_t byte = (uint8_t)FuzzBelow(random, 256);
                [data appendBytes:&byte length:1];
            }
            break;
        }
        case 2: { // truncated UTF-16: an odd trailing byte
            NSString *text = @"FILE \"a.flac\" WAVE\nb.mp3\n";
            [data appendData:[text dataUsingEncoding:NSUTF16LittleEndianStringEncoding]];
            uint8_t byte = (uint8_t)FuzzBelow(random, 256);
            [data appendBytes:&byte length:1];
            break;
        }
        case 3: { // NUL runs through otherwise sane text
            [data appendData:[@"FILE \"a.flac\" WAVE\n" dataUsingEncoding:NSUTF8StringEncoding]];
            NSUInteger nuls = 1 + FuzzBelow(random, 32);
            for (NSUInteger i = 0; i < nuls; i++) {
                [data appendBytes:"\x00" length:1];
            }
            [data appendData:[@"b.mp3\n" dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case 4: { // one enormous line, no terminator
            NSMutableString *line = [NSMutableString string];
            for (NSUInteger i = 0; i < 4000; i++) {
                [line appendString:@"FILE \"x"];
            }
            [data appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        case 5: { // truncated multi-byte UTF-8 sequences
            [data appendData:[@"FILE \"caf" dataUsingEncoding:NSUTF8StringEncoding]];
            [data appendBytes:"\xC3" length:1];              // é, cut in half
            [data appendData:[@".mp3\" MP3\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [data appendBytes:"\xE2\x82" length:2];          // € minus its last byte
            [data appendBytes:"\xF0\x9F\x8E" length:3];      // 🎧 minus its last byte
            break;
        }
        case 6: { // quote and separator soup
            NSMutableString *soup = [NSMutableString string];
            static NSArray<NSString *> *atoms;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                atoms = @[@"FILE", @"file", @"\"", @"\\", @"/", @" ", @"\t", @"\n", @"\r",
                          @"#", @"://", @"file://", @"WAVE", @"%", @"%ZZ", @" ", @" ",
                          @"..", @".", @"~", @"﻿", @"🎧"];
            });
            for (NSUInteger i = 0; i < 200; i++) {
                [soup appendString:atoms[FuzzBelow(random, (uint32_t)atoms.count)]];
            }
            [data appendData:[soup dataUsingEncoding:NSUTF8StringEncoding]];
            break;
        }
        default: { // a real playlist, chewed
            NSString *text = @"#EXTM3U\n#EXTINF:1,x\none.mp3\nsub/two.flac\n"
                              "FILE \"three.wav\" WAVE\nfile:///Users/me/four%20.mp3\n";
            NSMutableData *chewed = [[text dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            NSUInteger edits = 1 + FuzzBelow(random, 12);
            for (NSUInteger i = 0; i < edits && chewed.length > 1; i++) {
                NSUInteger at = FuzzBelow(random, (uint32_t)chewed.length);
                switch (FuzzBelow(random, 4)) {
                    case 0: { // flip a bit
                        uint8_t byte = ((uint8_t *)chewed.mutableBytes)[at];
                        byte ^= (uint8_t)(1u << FuzzBelow(random, 8));
                        ((uint8_t *)chewed.mutableBytes)[at] = byte;
                        break;
                    }
                    case 1: { // splice a byte in
                        uint8_t byte = (uint8_t)FuzzBelow(random, 256);
                        [chewed replaceBytesInRange:NSMakeRange(at, 0) withBytes:&byte length:1];
                        break;
                    }
                    case 2: // cut a byte out
                        [chewed replaceBytesInRange:NSMakeRange(at, 1) withBytes:NULL length:0];
                        break;
                    default: // truncate
                        [chewed setLength:at];
                        break;
                }
            }
            data = chewed;
            break;
        }
    }
    return data;
}

// What must hold for any input at all. Anything weaker than this and a reader
// that returned garbage would still pass; anything stronger and the reader
// would have to understand the corruption.
- (void)assertEntriesAreWellFormed:(NSArray<NSString *> *)entries
                              kind:(NSString *)kind
                              seed:(uint64_t)seed {
    for (NSString *entry in entries) {
        XCTAssertTrue([entry isKindOfClass:NSString.class], @"%@ seed %llu", kind, seed);
        // An empty entry resolves to the playlist's own folder, which the
        // caller would then try to play.
        XCTAssertGreaterThan(entry.length, 0u, @"%@ seed %llu", kind, seed);
        // Separators are normalized on the way out, so nothing downstream has
        // to know a Windows path when it sees one.
        XCTAssertFalse([entry containsString:@"\\"], @"%@ seed %llu: %@", kind, seed, entry);
        // One entry is one line. A name carrying a line break would split a
        // path across two rows downstream; NSString counts U+2028 and U+2029
        // as line breaks too, so a filename holding one arrives already split.
        for (NSString *breaker in @[@"\n", @"\r", @" ", @" "]) {
            XCTAssertFalse([entry containsString:breaker], @"%@ seed %llu: %@", kind, seed, entry);
        }
    }
    // Deliberately NOT asserted for m3u: that no entry begins with '#' or with
    // whitespace. Both hold of a plain path line, but an entry lifted out of a
    // file:// URL is that URL's path verbatim, and "file:// #x.mp3" yields one
    // of each. Neither resolves to anything, and trimming the path would be
    // the real bug — a filename is allowed to end in a space.
    if ([kind isEqualToString:@"cue"]) {
        for (NSUInteger i = 1; i < entries.count; i++) {
            XCTAssertNotEqual([entries[i - 1] caseInsensitiveCompare:entries[i]], NSOrderedSame,
                              @"cue seed %llu: %@ repeated", seed, entries[i]);
        }
    }
}

- (void)testCorruptedBytesNeverBreakTheReaders {
    for (NSUInteger round = 0; round < 1200; round++) {
        @autoreleasepool {
            uint64_t seed = _baseSeed + 300000 + round;
            FuzzRandom random = {seed};
            NSData *data = FuzzCorruptData(&random);

            NSString *text = [PlaylistFile textFromData:data];
            // The Latin-1 rung maps every byte, so anything non-empty decodes
            // to something. A nil here would drop a whole playlist on the
            // floor for one bad byte.
            if (data.length > 0) {
                XCTAssertNotNil(text, @"seed %llu", seed);
            }
            if (!text) {
                continue;
            }
            NSArray<NSString *> *cue = [PlaylistFile cueFileEntriesInText:text];
            NSArray<NSString *> *m3u = [PlaylistFile m3uEntriesInText:text];
            [self assertEntriesAreWellFormed:cue kind:@"cue" seed:seed];
            [self assertEntriesAreWellFormed:m3u kind:@"m3u" seed:seed];
            // Parsing is a pure function of the text: same bytes, same answer,
            // every time. A reader with static state would show up here.
            XCTAssertEqualObjects([PlaylistFile cueFileEntriesInText:text], cue, @"seed %llu", seed);
            XCTAssertEqualObjects([PlaylistFile m3uEntriesInText:text], m3u, @"seed %llu", seed);
        }
    }
}

// Every prefix of a valid playlist — what a reader sees when a writer is
// killed mid-save, or a copy is interrupted.
- (void)testEveryTruncationOfAValidPlaylistIsSurvivable {
    NSString *sheet = @"﻿REM GENRE Electronica\nFILE \"01 — café 🎧.flac\" WAVE\n"
                       "  TRACK 01 AUDIO\nFILE \"02 disc\\two.flac\" WAVE\n";
    NSData *full = [sheet dataUsingEncoding:NSUTF8StringEncoding];
    for (NSUInteger length = 0; length <= full.length; length++) {
        @autoreleasepool {
            NSData *prefix = [full subdataWithRange:NSMakeRange(0, length)];
            NSString *text = [PlaylistFile textFromData:prefix];
            if (length > 0) {
                XCTAssertNotNil(text, @"truncated to %lu", (unsigned long)length);
            }
            if (!text) {
                continue;
            }
            [self assertEntriesAreWellFormed:[PlaylistFile cueFileEntriesInText:text]
                                        kind:@"cue" seed:length];
            [self assertEntriesAreWellFormed:[PlaylistFile m3uEntriesInText:text]
                                        kind:@"m3u" seed:length];
        }
    }
}

#pragma mark - Corrupted files on disk

// The same corruption through the whole path, which adds the file read, the
// extension dispatch and the resolution rungs — and resolution touches the
// file system with whatever the parsers produced.
- (void)testCorruptedFilesOnDiskResolveWithoutBreaking {
    NSURL *neighbor = [_root URLByAppendingPathComponent:@"one.mp3"];
    [[NSData data] writeToURL:neighbor atomically:YES];

    for (NSUInteger round = 0; round < 250; round++) {
        @autoreleasepool {
            uint64_t seed = _baseSeed + 400000 + round;
            FuzzRandom random = {seed};
            NSData *data = FuzzCorruptData(&random);
            NSString *extension = @[@"cue", @"m3u", @"m3u8"][FuzzBelow(&random, 3)];
            NSURL *playlist = [_root URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"corrupt.%@", extension]];
            XCTAssertTrue([data writeToURL:playlist atomically:YES], @"seed %llu", seed);

            NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:playlist];

            // One URL per entry, in order, whatever the entries turned out to
            // be: the caller pairs them with the playlist's rows.
            NSString *text = [PlaylistFile textFromData:data];
            NSArray<NSString *> *entries = text
                    ? ([extension isEqualToString:@"cue"]
                            ? [PlaylistFile cueFileEntriesInText:text]
                            : [PlaylistFile m3uEntriesInText:text])
                    : @[];
            XCTAssertEqual(urls.count, entries.count, @"seed %llu", seed);
            for (NSURL *url in urls) {
                XCTAssertTrue(url.isFileURL, @"seed %llu", seed);
                XCTAssertGreaterThan(url.path.length, 0u, @"seed %llu", seed);
                // Absolute, so the caller never resolves it against a working
                // directory it does not control.
                XCTAssertTrue([url.path hasPrefix:@"/"], @"seed %llu: %@", seed, url.path);
            }
        }
    }
}

// A generated sheet naming files that really exist, so resolution has to hit
// every rung rather than falling through to the primary each time.
- (void)testGeneratedSheetsResolveToTheFilesTheyName {
    for (NSUInteger round = 0; round < 60; round++) {
        @autoreleasepool {
            uint64_t seed = _baseSeed + 500000 + round;
            FuzzRandom random = {seed};
            NSURL *dir = [_root URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"round%lu", (unsigned long)round] isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

            NSMutableArray<NSString *> *written = [NSMutableArray array];
            NSMutableString *list = [NSMutableString string];
            NSUInteger count = 1 + FuzzBelow(&random, 8);
            for (NSUInteger i = 0; i < count; i++) {
                NSString *stem = [NSString stringWithFormat:@"t%lu-%@", (unsigned long)i,
                                                            FuzzPlainName(&random).lastPathComponent];
                stem = [stem stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
                // Name it as .wav in the sheet but write it as .flac half the
                // time: the alternate-extension rung then has to carry it.
                BOOL transcoded = FuzzChance(&random, 2);
                NSString *named = [stem stringByAppendingPathExtension:@"wav"];
                NSString *actual = transcoded ? [stem stringByAppendingPathExtension:@"flac"] : named;
                [[NSData data] writeToURL:[dir URLByAppendingPathComponent:actual] atomically:YES];
                [written addObject:actual];
                [list appendFormat:@"%@\n", named];
            }
            NSURL *playlist = [dir URLByAppendingPathComponent:@"mix.m3u"];
            [[list dataUsingEncoding:NSUTF8StringEncoding] writeToURL:playlist atomically:YES];

            NSArray<NSURL *> *urls = [PlaylistFile resolvedFileURLsForPlaylistAtURL:playlist];
            XCTAssertEqual(urls.count, written.count, @"seed %llu", seed);
            for (NSUInteger i = 0; i < urls.count && i < written.count; i++) {
                // Compared precomposed. The volume stores names decomposed, so
                // an é the playlist spells as one code point comes back as two
                // — the file is the same file, and the readability check below
                // is the part that proves the resolution landed.
                XCTAssertEqualObjects(urls[i].lastPathComponent.precomposedStringWithCanonicalMapping,
                                      written[i].precomposedStringWithCanonicalMapping,
                                      @"seed %llu", seed);
                XCTAssertTrue([NSFileManager.defaultManager isReadableFileAtPath:urls[i].path],
                              @"seed %llu: %@", seed, urls[i].path);
            }
        }
    }
}

@end
