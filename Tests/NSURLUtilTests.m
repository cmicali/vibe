//
// The directory-as-playlist listing rule (audioFilesInDirectory:): extension
// filtering, hidden-file skipping, Finder-style numeric filename sort, and the
// non-recursive contract.
//

#import <XCTest/XCTest.h>

#import "NSURLUtil.h"

@interface NSURLUtilTests : XCTestCase
@end

@implementation NSURLUtilTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    NSString *name = [NSString stringWithFormat:@"NSURLUtilTests-%@", NSUUID.UUID.UUIDString];
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
    XCTAssertTrue([[NSData data] writeToURL:url atomically:YES]);
    return url;
}

- (NSArray<NSString *> *)listedNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in [NSURLUtil audioFilesInDirectory:_dir]) {
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
    NSArray *names = [self listedNames];
    XCTAssertEqualObjects(names, (@[@"a.mp3", @"b.FLAC"]));
}

- (void)testSkipsHiddenAndAppleDoubleFiles {
    [self makeFile:@"song.mp3"];
    [self makeFile:@"._song.mp3"];
    [self makeFile:@".hidden.flac"];
    XCTAssertEqualObjects([self listedNames], @[@"song.mp3"]);
}

- (void)testSortsNumericallyByFilename {
    [self makeFile:@"10 - ten.mp3"];
    [self makeFile:@"2 - two.mp3"];
    [self makeFile:@"1 - one.mp3"];
    XCTAssertEqualObjects([self listedNames],
                          (@[@"1 - one.mp3", @"2 - two.mp3", @"10 - ten.mp3"]));
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
    XCTAssertEqualObjects([self listedNames], @[@"top.mp3"]);
}

- (void)testDirectoryNamedLikeAudioFileIsNotListed {
    [self makeFile:@"real.mp3"];
    NSURL *impostor = [_dir URLByAppendingPathComponent:@"fake.mp3" isDirectory:YES];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtURL:impostor
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:NULL]);
    XCTAssertEqualObjects([self listedNames], @[@"real.mp3"]);
}

- (void)testMissingDirectoryReturnsEmpty {
    NSURL *gone = [_dir URLByAppendingPathComponent:@"missing" isDirectory:YES];
    XCTAssertEqualObjects([NSURLUtil audioFilesInDirectory:gone], @[]);
}

@end
