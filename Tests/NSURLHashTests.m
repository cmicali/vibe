//
// The cache key both the metadata and waveform caches are stored under. It is
// deliberately content-blind — file attributes only — so the interesting
// behavior is exactly WHICH changes move it and which don't.
//

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
    // A documented miss: an edited file re-analyzes rather than serving a
    // stale waveform.
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *before = file.cacheKey;

    [self writeFileNamed:@"a.mp3" contents:@"a different length entirely"];
    XCTAssertNotEqualObjects(before, file.cacheKey);
}

- (void)testSameSizeRewriteStillMovesTheKeyViaMtime {
    // Size alone is not the identity — the microsecond mtime is what catches
    // an in-place edit that happens to preserve length.
    NSURL *file = [self writeFileNamed:@"a.mp3" contents:@"aaaaa"];
    NSString *before = file.cacheKey;

    usleep(20000); // outrun the mtime's microsecond resolution
    [self writeFileNamed:@"a.mp3" contents:@"bbbbb"];

    XCTAssertNotEqualObjects(before, file.cacheKey);
}

- (void)testMovingTheFileMovesTheKey {
    // The other documented miss: the path is hashed, so a rename re-analyzes.
    NSURL *original = [self writeFileNamed:@"a.mp3" contents:@"hello"];
    NSString *before = original.cacheKey;

    NSURL *moved = [_dir URLByAppendingPathComponent:@"b.mp3"];
    [NSFileManager.defaultManager moveItemAtURL:original toURL:moved error:NULL];

    XCTAssertNotEqualObjects(before, moved.cacheKey);
}

- (void)testIdenticalContentAtDifferentPathsKeysSeparately {
    // Content-blind by design: two copies are two cache entries.
    NSURL *first = [self writeFileNamed:@"a.mp3" contents:@"same bytes"];
    NSURL *second = [self writeFileNamed:@"b.mp3" contents:@"same bytes"];
    XCTAssertNotEqualObjects(first.cacheKey, second.cacheKey);
}

- (void)testSymlinkResolvesToItsTargetsIdentity {
    // Links key off the target so a link and the file itself share one entry.
    NSURL *target = [self writeFileNamed:@"real.mp3" contents:@"hello"];
    NSURL *link = [_dir URLByAppendingPathComponent:@"link.mp3"];
    [NSFileManager.defaultManager createSymbolicLinkAtURL:link
                                       withDestinationURL:target
                                                    error:NULL];

    XCTAssertEqualObjects(link.cacheKey, target.cacheKey);
}

#pragma mark - No identity

- (void)testMissingFileHasNoKey {
    // Every caller branches on this: no stable identity means don't cache.
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
    // A stat failure is treated as transient — memoizing nil would strand the
    // track uncached for the rest of its life, e.g. a cloud file that lands a
    // moment later.
    NSURL *file = [_dir URLByAppendingPathComponent:@"late.mp3"];
    AudioTrack *track = [AudioTrack withURL:file];
    XCTAssertNil(track.cacheKey);

    [self writeFileNamed:@"late.mp3" contents:@"arrived"];
    XCTAssertNotNil(track.cacheKey, @"a later call must retry rather than stay nil");
}

@end
