//
//  NSURLFileIdentityTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import <limits.h>
#import <stdlib.h>

#import "NSURL+FileIdentity.h"

@interface NSURLFileIdentityTests : XCTestCase
@end

@implementation NSURLFileIdentityTests {
    NSURL *_root;
}

- (void)setUp {
    [super setUp];
    _root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"VibeFileIdentity-%@",
                                                                      NSUUID.UUID.UUIDString]]
                       isDirectory:YES];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_root
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&error], @"%@", error);
    char resolved[PATH_MAX];
    if (realpath(_root.fileSystemRepresentation, resolved)) {
        _root = [NSURL fileURLWithFileSystemRepresentation:resolved
                                               isDirectory:YES
                                             relativeToURL:nil];
    }
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_root error:nil];
    [super tearDown];
}

- (NSURL *)writeFileNamed:(NSString *)name {
    NSURL *url = [_root URLByAppendingPathComponent:name];
    XCTAssertTrue([[NSData dataWithBytes:"audio" length:5] writeToURL:url atomically:YES]);
    return url;
}

- (void)testExactAndStandardizedPathsMatch {
    NSURL *file = [self writeFileNamed:@"song.wav"];
    NSURL *directory = [_root URLByAppendingPathComponent:@"folder" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:directory
                                          withIntermediateDirectories:NO
                                                           attributes:nil
                                                                error:nil]);
    NSURL *standardizedAlias = [NSURL fileURLWithPath:
            [_root.path stringByAppendingPathComponent:@"folder/../song.wav"]];

    XCTAssertTrue([file vibeRefersToSameFileAsURL:file]);
    XCTAssertTrue([file vibeRefersToSameFileAsURL:standardizedAlias]);
}

- (void)testSymbolicLinkMatchesItsTarget {
    NSURL *file = [self writeFileNamed:@"song.wav"];
    NSURL *link = [_root URLByAppendingPathComponent:@"linked.wav"];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager createSymbolicLinkAtURL:link
                                                      withDestinationURL:file
                                                                   error:&error], @"%@", error);

    XCTAssertTrue([link vibeRefersToSameFileAsURL:file]);
}

- (void)testHardLinkMatchesItsTarget {
    NSURL *file = [self writeFileNamed:@"song.wav"];
    NSURL *link = [_root URLByAppendingPathComponent:@"hard-linked.wav"];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager linkItemAtURL:file toURL:link error:&error],
            @"%@", error);

    XCTAssertTrue([link vibeRefersToSameFileAsURL:file]);
}

- (void)testMissingLocationsMatchOnlyWhenTheirPathsDo {
    NSURL *missing = [_root URLByAppendingPathComponent:@"missing.wav"];
    NSURL *sameMissing = [NSURL fileURLWithPath:
            [_root.path stringByAppendingPathComponent:@"folder/../missing.wav"]];
    NSURL *differentMissing = [_root URLByAppendingPathComponent:@"other-missing.wav"];

    XCTAssertTrue([missing vibeRefersToSameFileAsURL:sameMissing]);
    XCTAssertFalse([missing vibeRefersToSameFileAsURL:differentMissing]);
}

- (void)testCaseAliasesFollowTheFilesystem {
    NSURL *mixedCase = [self writeFileNamed:@"CaseTrack.wav"];
    NSURL *lowerCase = [_root URLByAppendingPathComponent:@"casetrack.wav"];
    if ([NSFileManager.defaultManager fileExistsAtPath:lowerCase.path]) {
        XCTAssertTrue([mixedCase vibeRefersToSameFileAsURL:lowerCase]);
        return;
    }

    XCTAssertTrue([[NSData dataWithBytes:"other" length:5] writeToURL:lowerCase atomically:YES]);
    XCTAssertFalse([mixedCase vibeRefersToSameFileAsURL:lowerCase]);
}

- (void)testDistinctFilesAndNonFileURLsDoNotMatch {
    NSURL *first = [self writeFileNamed:@"first.wav"];
    NSURL *second = [self writeFileNamed:@"second.wav"];

    XCTAssertFalse([first vibeRefersToSameFileAsURL:second]);
    NSURL *remote = [NSURL URLWithString:@"https://example.com/first.wav"];
    XCTAssertFalse([first vibeRefersToSameFileAsURL:remote]);
    XCTAssertFalse([first vibeRefersToSameFileAsURL:nil]);
}

@end
