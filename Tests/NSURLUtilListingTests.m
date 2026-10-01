#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "NSURLUtil.h"

@interface NSURLUtilListingTests : XCTestCase
@end

@implementation NSURLUtilListingTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    NSString *name = [NSString stringWithFormat:@"NSURLUtilListingTests-%@", NSUUID.UUID.UUIDString];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]
                      isDirectory:YES];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:_dir
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:&error],
                  @"%@", error);
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

- (NSURL *)makeFile:(NSString *)name {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    const unsigned char byte = 1;
    XCTAssertTrue([[NSData dataWithBytes:&byte length:sizeof(byte)] writeToURL:url atomically:YES]);
    return url;
}

// Set by hand: a whole listing is written inside one timestamp tick, and every
// newest-first assertion would be decided by the name tiebreak.
- (NSURL *)makeFile:(NSString *)name modifiedSecondsAgo:(NSTimeInterval)secondsAgo {
    NSURL *url = [self makeFile:name];
    NSDate *modified = [NSDate dateWithTimeIntervalSinceNow:-secondsAgo];
    XCTAssertTrue([[NSFileManager defaultManager]
            setAttributes:@{NSFileModificationDate: modified} ofItemAtPath:url.path error:NULL]);
    return url;
}

- (NSURL *)makeEmptyFile:(NSString *)name {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue([[NSData data] writeToURL:url atomically:YES]);
    return url;
}

- (NSArray<NSString *> *)listedNamesSortedBy:(VibeFolderOpenSort)sort {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (AudioTrack *row in [NSURLUtil rowsInDirectory:_dir sortedBy:sort]) {
        [names addObject:[row keyByAppendingWindowTo:row.url.lastPathComponent]];
    }
    return names;
}

- (void)testFiltersToSupportedExtensionsCaseInsensitively {
    [self makeFile:@"a.mp3"];
    [self makeFile:@"b.FLAC"];
    [self makeFile:@"notes.txt"];
    [self makeFile:@"cover.jpg"];
    [self makeFile:@"noextension"];
    NSArray *names = [self listedNamesSortedBy:VibeFolderOpenSortName];
    XCTAssertEqualObjects(names, (@[@"a.mp3", @"b.FLAC"]));
}

- (void)testSkipsHiddenAndAppleDoubleFiles {
    [self makeFile:@"song.mp3"];
    [self makeFile:@"._song.mp3"];
    [self makeFile:@".hidden.flac"];
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName], @[@"song.mp3"]);
}

- (void)testSortsNumericallyByFilename {
    [self makeFile:@"10 - ten.mp3"];
    [self makeFile:@"2 - two.mp3"];
    [self makeFile:@"1 - one.mp3"];
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName],
                          (@[@"1 - one.mp3", @"2 - two.mp3", @"10 - ten.mp3"]));
}

- (void)testNewestFirstOrdersByModificationDateDescending {
    [self makeFile:@"oldest.mp3" modifiedSecondsAgo:300];
    [self makeFile:@"newest.mp3" modifiedSecondsAgo:10];
    [self makeFile:@"middle.mp3" modifiedSecondsAgo:100];
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortNewestFirst],
                          (@[@"newest.mp3", @"middle.mp3", @"oldest.mp3"]));
}

// A folder copied in one go shares one mtime: the common case.
- (void)testNewestFirstBreaksEqualDatesByName {
    [self makeFile:@"10 - ten.mp3" modifiedSecondsAgo:60];
    [self makeFile:@"2 - two.mp3" modifiedSecondsAgo:60];
    [self makeFile:@"1 - one.mp3" modifiedSecondsAgo:60];
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortNewestFirst],
                          (@[@"1 - one.mp3", @"2 - two.mp3", @"10 - ten.mp3"]));
}

- (void)testEveryOrderListsTheSameFiles {
    [self makeFile:@"b.mp3" modifiedSecondsAgo:10];
    [self makeFile:@"a.flac" modifiedSecondsAgo:60];
    [self makeFile:@"notes.txt"];
    [self makeFile:@"._b.mp3"];
    [self makeEmptyFile:@"empty.mp3"];
    NSSet *expected = [NSSet setWithArray:@[@"a.flac", @"b.mp3"]];
    for (VibeFolderOpenSort sort = VibeFolderOpenSortName;
         sort <= VibeFolderOpenSortAsReceived; sort++) {
        XCTAssertEqualObjects([NSSet setWithArray:[self listedNamesSortedBy:sort]], expected,
                              @"sort %ld", (long)sort);
    }
}

- (void)testDoesNotDescendIntoSubdirectories {
    [self makeFile:@"top.mp3"];
    NSURL *sub = [_dir URLByAppendingPathComponent:@"album" isDirectory:YES];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:sub
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:NULL]);
    XCTAssertTrue([[NSData data] writeToURL:[sub URLByAppendingPathComponent:@"nested.mp3"]
                                 atomically:YES]);
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName], @[@"top.mp3"]);
}

- (void)testDirectoryNamedLikeAudioFileIsNotListed {
    [self makeFile:@"real.mp3"];
    NSURL *impostor = [_dir URLByAppendingPathComponent:@"fake.mp3" isDirectory:YES];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:impostor
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:NULL]);
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName], @[@"real.mp3"]);
}

- (void)testZeroByteAudioFileIsNotListed {
    [self makeFile:@"real.mp3"];
    [self makeEmptyFile:@"empty.mp3"];
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName], @[@"real.mp3"]);
}

// The listing's sizes are a link's own, so a link is judged by its target.
- (void)testALinkIsListedByItsTarget {
    NSURL *real = [self makeFile:@"real.mp3"];
    NSURL *empty = [self makeEmptyFile:@"empty.mp3"];
    NSURL *folder = [_dir URLByAppendingPathComponent:@"folder" isDirectory:YES];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:folder
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:NULL]);
    NSDictionary<NSString *, NSURL *> *links = @{@"link.mp3": real, @"empty-link.mp3": empty,
                                                 @"folder-link.mp3": folder};
    for (NSString *name in links) {
        XCTAssertTrue([[NSFileManager defaultManager] createSymbolicLinkAtURL:[_dir URLByAppendingPathComponent:name]
                                                           withDestinationURL:links[name]
                                                                        error:NULL], @"%@", name);
    }
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName],
                          (@[@"link.mp3", @"real.mp3"]));
}

- (void)testMissingDirectoryReturnsEmpty {
    NSURL *gone = [_dir URLByAppendingPathComponent:@"missing" isDirectory:YES];
    XCTAssertEqualObjects([NSURLUtil rowsInDirectory:gone sortedBy:VibeFolderOpenSortName],
                          @[]);
}

// The iOS listing takes a sheet as the walk does: its rows in its place, its
// file claimed.
- (void)testASheetInTheListingStandsInForItsFile {
    [self makeFile:@"a.mp3"];
    [self makeFile:@"mix.flac"];
    NSURL *sheet = [_dir URLByAppendingPathComponent:@"mix.cue"];
    XCTAssertTrue([[@"FILE \"mix.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n"
                     "  TRACK 02 AUDIO\n    INDEX 01 01:00:00\n" dataUsingEncoding:NSUTF8StringEncoding]
                    writeToURL:sheet atomically:YES]);
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName],
                          (@[@"a.mp3", @"mix.flac#0-4500", @"mix.flac#4500-0"]));
}

- (void)testASheetCannotAddUnsupportedEmptyOrDirectoryEntries {
    [self makeFile:@"real.mp3"];
    [self makeFile:@"data.bin"];
    [self makeEmptyFile:@"empty.flac"];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:[_dir URLByAppendingPathComponent:@"folder.wav"]
                                       withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSURL *sheet = [_dir URLByAppendingPathComponent:@"invalid.cue"];
    XCTAssertTrue([[@"FILE \"data.bin\" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n"
                     "FILE \"empty.flac\" WAVE\n TRACK 02 AUDIO\n INDEX 01 00:00:00\n"
                     "FILE \"folder.wav\" WAVE\n TRACK 03 AUDIO\n INDEX 01 00:00:00\n"
                     dataUsingEncoding:NSUTF8StringEncoding] writeToURL:sheet atomically:YES]);

    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortName], @[@"real.mp3"]);
}

@end
