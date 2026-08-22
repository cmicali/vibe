//
// The directory-as-playlist listing rule (audioFilesInDirectory:sortedBy:):
// extension filtering, hidden-file skipping, the non-recursive contract, and
// all three folder-open orders.
//

#import <XCTest/XCTest.h>

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

// Modification dates are set by hand rather than by write order: a whole
// listing is written inside one filesystem timestamp tick otherwise, and every
// newest-first assertion would then be decided by the name tiebreak.
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
    for (NSURL *url in [NSURLUtil audioFilesInDirectory:_dir sortedBy:sort]) {
        [names addObject:url.lastPathComponent];
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

// A folder copied in one go shares one mtime, which is the common case and
// the whole reason the tiebreak exists.
- (void)testNewestFirstBreaksEqualDatesByName {
    [self makeFile:@"10 - ten.mp3" modifiedSecondsAgo:60];
    [self makeFile:@"2 - two.mp3" modifiedSecondsAgo:60];
    [self makeFile:@"1 - one.mp3" modifiedSecondsAgo:60];
    XCTAssertEqualObjects([self listedNamesSortedBy:VibeFolderOpenSortNewestFirst],
                          (@[@"1 - one.mp3", @"2 - two.mp3", @"10 - ten.mp3"]));
}

// The order is the only thing the choice changes: filtering, hidden files and
// the non-recursive contract are the listing rule and hold under all three.
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

- (void)testMissingDirectoryReturnsEmpty {
    NSURL *gone = [_dir URLByAppendingPathComponent:@"missing" isDirectory:YES];
    XCTAssertEqualObjects([NSURLUtil audioFilesInDirectory:gone sortedBy:VibeFolderOpenSortName],
                          @[]);
}

@end
