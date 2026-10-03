#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "NSURL+Hash.h"

@interface NSURLHashTests : XCTestCase
@end

@implementation NSURLHashTests {
    NSURL *_dir;
}

- (void)setUp {
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"vibe-hash-%@",
                                            NSUUID.UUID.UUIDString]]];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:NULL];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
}

- (NSURL *)writeFileNamed:(NSString *)name contents:(NSString *)contents {
    NSURL *url = [_dir URLByAppendingPathComponent:name];
    [[contents dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES];
    return url;
}

#pragma mark - Shape

- (void)testKeyIsSizeMtimeAndPathHash {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *key = file.cacheKey;
    XCTAssertNotNil(key);

    NSError *error = nil;
    NSRegularExpression *shape =
            [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+-[0-9]+-[0-9a-f]{40}$"
                                                      options:0
                                                        error:&error];
    XCTAssertEqual([shape numberOfMatchesInString:key options:0
                                            range:NSMakeRange(0, key.length)], 1,
                   @"unexpected key shape: %@", key);
    XCTAssertTrue([key hasPrefix:@"5-"], @"leads with the byte size: %@", key);
}

- (void)testKeyIsStableAcrossReads {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    XCTAssertEqualObjects(file.cacheKey, file.cacheKey);
}

#pragma mark - What moves the key

- (void)testRewritingTheFileMovesTheKey {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *before = file.cacheKey;

    [self writeFileNamed:@"a.mp3" contents:@"a different length entirely"];
    XCTAssertNotEqualObjects(before, file.cacheKey);
}

- (void)testSameSizeRewriteStillMovesTheKeyViaMtime {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"aaaaa"];
    NSString *before = file.cacheKey;

    usleep(20000); // outrun the mtime's microsecond resolution
    [self writeFileNamed:@"a.mp3" contents:@"bbbbb"];

    XCTAssertNotEqualObjects(before, file.cacheKey);
}

- (void)testMovingTheFileMovesTheKey {
    NSURL *original = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *before = original.cacheKey;

    NSURL *moved = [_dir URLByAppendingPathComponent:@"b.mp3"];
    [NSFileManager.defaultManager moveItemAtURL:original toURL:moved error:NULL];

    XCTAssertNotEqualObjects(before, moved.cacheKey);
}

- (void)testIdenticalContentAtDifferentPathsKeysSeparately {
    NSURL *first = [self writeFileNamed:@"a.mp3" contents:@"same bytes"];
    NSURL *second = [self writeFileNamed:@"b.mp3" contents:@"same bytes"];
    XCTAssertNotEqualObjects(first.cacheKey, second.cacheKey);
}

- (void)testSymlinkResolvesToItsTargetsIdentity {
    NSURL *target = [self writeFileNamed:@"real.mp3" contents:@"hello"];
    NSURL *link = [_dir URLByAppendingPathComponent:@"link.mp3"];
    [NSFileManager.defaultManager createSymbolicLinkAtURL:link
                                       withDestinationURL:target
                                                    error:NULL];

    XCTAssertEqualObjects(link.cacheKey, target.cacheKey);
}

#pragma mark - No identity

- (void)testMissingFileHasNoKey {
    // Callers read nil as "don't cache".
    NSURL *missing = [_dir URLByAppendingPathComponent:@"nope.mp3"];
    XCTAssertNil(missing.cacheKey);
}

- (void)testNonFileURLHasNoKey {
    XCTAssertNil([NSURL URLWithString:@"https://example.com/a.mp3"].cacheKey);
}

#pragma mark - AudioTrack memoization

- (void)testTrackMemoizesItsKey {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    AudioTrack *track = [AudioTrack withURL:file];

    NSString *first = track.cacheKey;
    XCTAssertNotNil(first);

    // Deleting the file would change the answer if it were re-derived.
    [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
    XCTAssertEqualObjects(track.cacheKey, first, @"second read must hit the memo");
}

- (void)testTrackDoesNotMemoizeAFailedStat {
    // A stat failure is transient: memoizing nil would strand the track
    // uncached, e.g. a cloud file that lands a moment later.
    NSURL *file = [_dir URLByAppendingPathComponent:@"late.mp3"];
    AudioTrack *track = [AudioTrack withURL:file];
    XCTAssertNil(track.cacheKey);

    [self writeFileNamed:@"late.mp3" contents:@"arrived"];
    XCTAssertNotNil(track.cacheKey, @"a later call must retry rather than stay nil");
}

// A download that installed another version than its placeholder's: the memo
// holds the old version's key until it is retired, then answers the file's.
- (void)testAReplacedFileAnswersItsNewKeyOnceTheMemosAreRetired {
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"version one"];
    AudioTrack *track = [AudioTrack withURL:file];
    AudioTrack *row = [AudioTrack withURL:file];
    NSString *old = track.cacheKey;
    XCTAssertEqualObjects(row.cacheKey, old);

    [self writeFileNamed:@"a.mp3" contents:@"version two, re-uploaded"];
    NSString *installed = file.cacheKey;
    XCTAssertNotEqualObjects(installed, old);
    XCTAssertEqualObjects(track.cacheKey, old, @"memoized until retired");

    [AudioTrack invalidateMemoizedCacheKeys];
    XCTAssertEqualObjects(track.cacheKey, installed);
    XCTAssertEqualObjects(row.cacheKey, installed, @"every track, not one");
    [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
    XCTAssertEqualObjects(track.cacheKey, installed, @"and memoized again");
}

@end
