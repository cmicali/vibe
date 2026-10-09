//
//  RemotePlaceholderStoreTests.m
//
//  The placeholder store over the plain HTTPTransferClient, HTTPStub, and a
//  per-test temp root: the placeholder and the install, the directory index,
//  the fetch that streams and its tail window, the ranged read, the budget,
//  and the backend it installs. The subclass below says only which URL a
//  placeholder stands for and whether its server reads by range.
//

#import <XCTest/XCTest.h>

#include <stdatomic.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/xattr.h>

#import "CloudFileMaterializer.h"
#import "HTTPStub.h"
#import "HTTPTransferClientInternal.h"
#import "NSURL+Hash.h"
#import "NSURLUtil.h"
#import "RemotePlaceholderStoreInternal.h"

static NSString *const kIndexAttribute = @"com.commonwealthrecordings.vibe.test-store";
static const char *const kVersionAttribute = "com.commonwealthrecordings.Vibe.rev";
static const time_t kStamp = 1577934245;
// RemotePlaceholderStore's kStreamReadableBytes.
static const uint64_t kReadableBytes = 256 * 1024;
// Where a streaming download is held: past readable, short of the end.
static const NSUInteger kStallBytes = 5 * 64 * 1024;
// A small format's window (AudioFileOpenRules.h).
static const uint64_t kWindowBytes = 128 * 1024;

static NSData *PatternBytes(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        bytes[i] = (uint8_t)((i * 7 + i / 251) & 0xff);
    }
    return data;
}

static struct stat StatOf(NSURL *url) {
    struct stat st = {0};
    lstat(url.fileSystemRepresentation, &st);
    return st;
}

// What NSURLUtil reads as a placeholder under a registered root.
static BOOL IsPlaceholder(NSURL *url) {
    struct stat st = StatOf(url);
    return S_ISREG(st.st_mode) && VibeFileModeIsRemotePlaceholder(st.st_mode);
}

@interface TestPlaceholderStore : RemotePlaceholderStore
// File name → the URL it stands for.
@property (atomic, copy) NSDictionary<NSString *, NSURL *> *targets;
@property (atomic) BOOL readsByRange;
@property (atomic, readonly) NSArray<NSNumber *> *reportedTotals;
@end

@implementation TestPlaceholderStore {
    NSMutableArray<NSNumber *> *_totals;
}

- (id)remoteTargetForURL:(NSURL *)url error:(NSError **)error {
    NSURL *target = self.targets[url.lastPathComponent];
    return target ?: [super remoteTargetForURL:url error:error];
}

- (BOOL)readsByRangeAtURL:(NSURL *)url {
    return self.readsByRange;
}

- (void)downloadsDidChangeWithTotal:(long long)total {
    @synchronized (self) {
        if (!_totals) {
            _totals = [NSMutableArray array];
        }
        [_totals addObject:@(total)];
    }
}

- (NSArray<NSNumber *> *)reportedTotals {
    @synchronized (self) {
        return [_totals copy] ?: @[];
    }
}

@end

@interface RemotePlaceholderStoreTests : XCTestCase
@end

@implementation RemotePlaceholderStoreTests {
    HTTPStub *_stub;
    HTTPTransferClient *_client;
    TestPlaceholderStore *_store;
    NSURL *_root;
    NSURL *_album;
    NSMutableArray<dispatch_semaphore_t> *_gates;
}

- (void)setUp {
    [super setUp];
    _stub = [[HTTPStub alloc] init];
    _client = [[HTTPTransferClient alloc] initWithConfiguration:_stub.configuration];
    _client.retryDelayScale = 0.01;
    _gates = [NSMutableArray array];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"RemotePlaceholderStoreTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _root = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    _album = [_root URLByAppendingPathComponent:@"Album" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_album withIntermediateDirectories:YES attributes:nil error:NULL];
    _store = [self storeWithBudget:1LL << 40];
}

- (void)tearDown {
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    // A held stub delivery goes on to find its load stopped.
    for (dispatch_semaphore_t gate in _gates) {
        dispatch_semaphore_signal(gate);
        dispatch_semaphore_signal(gate);
    }
    [NSFileManager.defaultManager removeItemAtURL:_root error:NULL];
    [super tearDown];
}

- (TestPlaceholderStore *)storeWithBudget:(long long)budget {
    TestPlaceholderStore *store = [[TestPlaceholderStore alloc] initWithClient:_client rootURL:_root
                                                                 indexAttribute:kIndexAttribute
                                                                 downloadBudget:budget];
    store.readsByRange = YES;
    store.targets = _store.targets;
    return store;
}

- (dispatch_semaphore_t)gate {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [_gates addObject:gate];
    return gate;
}

// A placeholder for `bytes` served at /<name> with a strong ETag.
- (NSURL *)placeholder:(NSString *)name bytes:(NSData *)bytes {
    [_stub serveData:bytes atPath:[@"/" stringByAppendingString:name] headers:@{@"ETag": @"\"v1\""}];
    NSMutableDictionary *targets = [_store.targets mutableCopy] ?: [NSMutableDictionary dictionary];
    targets[name] = [_stub URLForPath:name];
    _store.targets = targets;
    NSURL *url = [_album URLByAppendingPathComponent:name];
    XCTAssertTrue([RemotePlaceholderStore writePlaceholderAtURL:url size:(long long)bytes.length modified:kStamp]);
    return url;
}

// Both requests a fetch sends, the download and its tail read, arrive in
// either order, and steps go to requests by arrival: each takes a stall past
// the tail's whole length, so only the download is held.
- (dispatch_semaphore_t)stallStreamOf:(NSString *)name {
    dispatch_semaphore_t gate = [self gate];
    NSString *path = [@"/" stringByAppendingString:name];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:path];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:path];
    return gate;
}

typedef struct {
    XCTestExpectation *returned;
    XCTestExpectation *readable;
} FetchExpectations;

// The fetch on a worker, as the materializer runs it. `fetched` gets its
// answer; `cancel` the block it hands back.
- (FetchExpectations)startFetch:(NSURL *)url
                        fetched:(void (^)(BOOL fetched, NSError *error))fetched
                         cancel:(void (^)(dispatch_block_t cancel))cancel {
    XCTestExpectation *returned = [self expectationWithDescription:@"fetch returned"];
    XCTestExpectation *readable = [self expectationWithDescription:@"readable"];
    TestPlaceholderStore *store = _store;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        BOOL answer = [store fetchPlaceholderAtURL:url onReadable:^{
            [readable fulfill];
        } onCancel:^(dispatch_block_t block) {
            if (cancel) {
                cancel(block);
            }
        } error:&error];
        fetched(answer, error);
        [returned fulfill];
    });
    return (FetchExpectations){returned, readable};
}

- (BOOL)fetch:(NSURL *)url {
    NSError *error = nil;
    BOOL fetched = [_store fetchPlaceholderAtURL:url onReadable:nil onCancel:^(dispatch_block_t cancel) {
    } error:&error];
    XCTAssertNil(error);
    return fetched;
}

- (long long)measuredDownloads {
    XCTestExpectation *measured = [self expectationWithDescription:@"measure"];
    __block long long bytes = -1;
    [_store measureDownloadsWithCompletion:^(long long total) {
        bytes = total;
        [measured fulfill];
    }];
    [self waitForExpectations:@[measured] timeout:VIBE_TEST_HANG_TIMEOUT];
    return bytes;
}

- (void)waitUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        usleep(1000);
    }
}

- (NSArray<NSURLRequest *> *)closedRangeRequestsTo:(NSString *)name {
    return [[_stub requestsToPath:[@"/" stringByAppendingString:name]] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        NSString *range = [request valueForHTTPHeaderField:@"Range"];
        return range && ![range hasSuffix:@"-"];
    }]];
}

#pragma mark Placeholder and install

- (void)testAPlaceholderIsSparseDatedUnreadableAndRenamedIn {
    NSURL *url = [_album URLByAppendingPathComponent:@"a.flac"];
    [[NSData dataWithBytes:"old" length:3] writeToURL:url atomically:NO];
    ino_t before = StatOf(url).st_ino;

    XCTAssertTrue([RemotePlaceholderStore writePlaceholderAtURL:url size:5000000 modified:kStamp]);
    struct stat st = StatOf(url);
    XCTAssertEqual(st.st_size, 5000000);
    XCTAssertEqual(st.st_mtimespec.tv_sec, kStamp);
    XCTAssertEqual(st.st_mode & 0777, 0);
    XCTAssertNotEqual(st.st_ino, before, @"renamed into place, not written over");
    XCTAssertTrue(IsPlaceholder(url));
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:_album.path error:NULL];
    XCTAssertEqualObjects(names, @[@"a.flac"], @"no temp file left");

    NSURL *folder = [_album URLByAppendingPathComponent:@"b.flac" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:NULL];
    XCTAssertTrue([RemotePlaceholderStore writePlaceholderAtURL:folder size:10 modified:kStamp]);
    XCTAssertTrue(S_ISREG(StatOf(folder).st_mode), @"a directory in the way is replaced");
}

- (void)testAnInstalledPartTakesItsMtimeAndReplacesThePlaceholder {
    NSURL *url = [_album URLByAppendingPathComponent:@"a.flac"];
    XCTAssertTrue([RemotePlaceholderStore writePlaceholderAtURL:url size:5 modified:kStamp]);
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:url];
    [[NSData dataWithBytes:"BYTES" length:5] writeToURL:part atomically:NO];

    NSError *error = nil;
    XCTAssertTrue([RemotePlaceholderStore installPart:part atURL:url modified:kStamp + 60 error:&error]);
    XCTAssertNil(error);
    struct stat st = StatOf(url);
    XCTAssertEqual(st.st_mode & 0777, 0644);
    XCTAssertEqual(st.st_mtimespec.tv_sec, kStamp + 60);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], [NSData dataWithBytes:"BYTES" length:5]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:part.path]);

    // No mtime keeps the part's own.
    [[NSData dataWithBytes:"AGAIN" length:5] writeToURL:part atomically:NO];
    time_t written = StatOf(part).st_mtimespec.tv_sec;
    XCTAssertTrue([RemotePlaceholderStore installPart:part atURL:url modified:-1 error:NULL]);
    XCTAssertEqual(StatOf(url).st_mtimespec.tv_sec, written);

    // A part that cannot be installed is gone, with the reason.
    XCTAssertFalse([RemotePlaceholderStore installPart:part atURL:url modified:kStamp error:&error]);
    XCTAssertEqualObjects(error.domain, NSPOSIXErrorDomain);
}

#pragma mark The index

- (void)testTheIndexRoundTripsThroughItsAttributeAndIsCached {
    NSDictionary *index = @{@"url": @"https://example.test/a.flac", @"size": @5};
    [_store writeIndex:index ofDirectory:_album];

    char raw[256] = {0};
    ssize_t length = getxattr(_album.fileSystemRepresentation, kIndexAttribute.UTF8String, raw, sizeof raw - 1, 0,
                              XATTR_NOFOLLOW);
    XCTAssertGreaterThan(length, 0);
    NSDictionary *stored = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:(NSUInteger)length]
                                                           options:0 error:NULL];
    XCTAssertEqualObjects(stored, index);
    XCTAssertEqualObjects([[self storeWithBudget:0] indexOfDirectory:_album], index, @"read back by a new store");

    // Written behind the store's back: the cache answers until forgotten.
    NSData *changed = [NSJSONSerialization dataWithJSONObject:@{@"url": @"https://example.test/b.flac"}
                                                      options:0 error:NULL];
    setxattr(_album.fileSystemRepresentation, kIndexAttribute.UTF8String, changed.bytes, changed.length, 0,
             XATTR_NOFOLLOW);
    XCTAssertEqualObjects([_store indexOfDirectory:_album], index);
    [_store forgetCachedIndexes];
    XCTAssertEqualObjects([_store indexOfDirectory:_album][@"url"], @"https://example.test/b.flac");

    // Through the other spelling of the temp directory, one entry.
    NSString *other = [_album.path hasPrefix:@"/private/"] ? [_album.path substringFromIndex:8] : _album.path;
    XCTAssertEqualObjects([_store indexOfDirectory:[NSURL fileURLWithPath:other isDirectory:YES]][@"url"],
                          @"https://example.test/b.flac");
    XCTAssertNil([_store indexOfDirectory:_root]);
}

#pragma mark The fetch

- (void)testAFetchIsReadableAtItsHeadWithItsTailWindowAndKeepsTheCacheKey {
    NSData *bytes = PatternBytes(1024 * 1024);
    NSURL *url = [self placeholder:@"a.flac" bytes:bytes];
    NSString *key = url.cacheKey;
    XCTAssertNotNil(key);
    dispatch_semaphore_t gate = [self stallStreamOf:@"a.flac"];

    __block BOOL fetched = NO;
    __block NSError *failure = nil;
    FetchExpectations fetch = [self startFetch:url fetched:^(BOOL answer, NSError *error) {
        fetched = answer;
        failure = error;
    } cancel:nil];
    [self waitForExpectations:@[fetch.readable] timeout:VIBE_TEST_HANG_TIMEOUT];

    CloudFileAvailability *stream = [_store availabilityForURL:url];
    XCTAssertNotNil(stream);
    XCTAssertEqual(stream.size, bytes.length);
    XCTAssertGreaterThanOrEqual(stream.writtenBytes, kReadableBytes);
    XCTAssertLessThanOrEqual(stream.writtenBytes, kStallBytes);
    [self waitUntil:^BOOL {
        return stream.windowLength > 0;
    }];
    XCTAssertEqual(stream.windowLength, kWindowBytes, @"the tail read is installed past the download's edge");
    XCTAssertEqualObjects([stream readyBytesAt:bytes.length - 128 length:128],
                          [bytes subdataWithRange:NSMakeRange(bytes.length - 128, 128)]);
    XCTAssertEqual([self closedRangeRequestsTo:@"a.flac"].count, 1u);

    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[fetch.returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(fetched);
    XCTAssertNil(failure);
    XCTAssertNil([_store availabilityForURL:url], @"forgotten once finished");
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], bytes);
    XCTAssertEqual(StatOf(url).st_mode & 0777, 0644);
    XCTAssertEqualObjects(url.cacheKey, key, @"the install keeps the placeholder's size and mtime");
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[NSURLUtil remotePlaceholderPartURL:url].path]);
}

- (void)testAFetchTheLastReaderLeavesIsCancelledAndKeepsItsPart {
    NSData *bytes = PatternBytes(1024 * 1024);
    NSURL *url = [self placeholder:@"a.flac" bytes:bytes];
    [self stallStreamOf:@"a.flac"];
    __block dispatch_block_t cancel = nil;
    dispatch_semaphore_t handed = dispatch_semaphore_create(0);
    __block BOOL fetched = YES;
    __block NSError *failure = nil;
    FetchExpectations fetch = [self startFetch:url fetched:^(BOOL answer, NSError *error) {
        fetched = answer;
        failure = error;
    } cancel:^(dispatch_block_t block) {
        cancel = block;
        dispatch_semaphore_signal(handed);
    }];
    [self waitForExpectations:@[fetch.readable] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(dispatch_semaphore_wait(handed, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    [self waitUntil:^BOOL {
        return [self->_store availabilityForURL:url].writtenBytes == kStallBytes;
    }];

    // What the coordinator does when a skip leaves the stream.
    CloudFileAvailability *stream = [_store availabilityForURL:url];
    stream.onLastReaderGone = cancel;
    [stream addReader];
    [stream removeReader];
    [self waitForExpectations:@[fetch.returned] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertFalse(fetched);
    XCTAssertEqualObjects(failure.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(failure.code, VibeHTTPErrorCancelled);
    XCTAssertNil([_store availabilityForURL:url]);
    XCTAssertTrue(IsPlaceholder(url), @"the placeholder stands");
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:url];
    XCTAssertEqual(StatOf(part).st_size, (off_t)kStallBytes, @"kept for the next fetch to continue");
    char version[64] = {0};
    XCTAssertGreaterThan(getxattr(part.fileSystemRepresentation, kVersionAttribute, version, sizeof version - 1, 0, 0), 0);
    XCTAssertEqualObjects(@(version), @"\"v1\"");
}

- (void)testAFileThatDoesNotReadByRangeHasNoTailReadAndNoRangedRead {
    _store.readsByRange = NO;
    NSData *bytes = PatternBytes(1024 * 1024);
    NSURL *url = [self placeholder:@"a.flac" bytes:bytes];
    NSURL *other = [self placeholder:@"b.flac" bytes:PatternBytes(4000)];

    XCTAssertTrue([self fetch:url]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], bytes);
    NSArray<NSURLRequest *> *requests = [_stub requestsToPath:@"/a.flac"];
    XCTAssertEqual(requests.count, 1u);
    XCTAssertNil([requests.firstObject valueForHTTPHeaderField:@"Range"]);

    NSError *error = nil;
    XCTAssertNil([_store readPlaceholderAtURL:other offset:0 length:16 error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual([_stub requestsToPath:@"/b.flac"].count, 0u);
}

#pragma mark Ranged reads

- (void)testARangedReadOfAPlaceholderAsksForItsRange {
    NSData *bytes = PatternBytes(4000);
    NSURL *url = [self placeholder:@"a.flac" bytes:bytes];
    NSError *error = nil;
    XCTAssertEqualObjects([_store readPlaceholderAtURL:url offset:100 length:200 error:&error],
                          [bytes subdataWithRange:NSMakeRange(100, 200)]);
    XCTAssertNil(error);
    NSURLRequest *read = [_stub requestsToPath:@"/a.flac"].lastObject;
    XCTAssertEqualObjects([read valueForHTTPHeaderField:@"Range"], @"bytes=100-299");
    XCTAssertTrue(IsPlaceholder(url), @"a read is not a download");

    XCTAssertNil([_store readPlaceholderAtURL:[_album URLByAppendingPathComponent:@"unknown.flac"] offset:0
                                       length:16 error:&error]);
    XCTAssertNotNil(error);
}

// The part file's prefix below the bytes written, and only the rest from the
// server: a range past the head and short of the tail does not wait.
- (void)testARangedReadOfAStreamingFileTakesThePartsPrefix {
    NSData *bytes = PatternBytes(4 * 1024 * 1024);
    NSURL *url = [self placeholder:@"a.flac" bytes:bytes];
    dispatch_semaphore_t gate = [self stallStreamOf:@"a.flac"];
    FetchExpectations fetch = [self startFetch:url fetched:^(BOOL answer, NSError *error) {
    } cancel:nil];
    [self waitForExpectations:@[fetch.readable] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitUntil:^BOOL {
        CloudFileAvailability *stream = [self->_store availabilityForURL:url];
        return stream.writtenBytes == kStallBytes && stream.windowLength > 0;
    }];

    uint64_t offset = kStallBytes - 1000, length = 800000;
    NSError *error = nil;
    XCTAssertEqualObjects([_store readPlaceholderAtURL:url offset:offset length:length error:&error],
                          [bytes subdataWithRange:NSMakeRange(offset, length)]);
    XCTAssertNil(error);
    NSURLRequest *read = [self closedRangeRequestsTo:@"a.flac"].lastObject;
    XCTAssertEqualObjects([read valueForHTTPHeaderField:@"Range"],
                          ([NSString stringWithFormat:@"bytes=%lu-%llu", (unsigned long)kStallBytes,
                            offset + length - 1]));

    // The tail comes from the window, with no request.
    NSUInteger before = [_stub requestsToPath:@"/a.flac"].count;
    XCTAssertEqualObjects([_store readPlaceholderAtURL:url offset:bytes.length - 128 length:128 error:&error],
                          [bytes subdataWithRange:NSMakeRange(bytes.length - 128, 128)]);
    XCTAssertEqual([_stub requestsToPath:@"/a.flac"].count, before);

    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[fetch.returned] timeout:VIBE_TEST_HANG_TIMEOUT];
}

#pragma mark The budget

- (void)testDownloadsPastTheBudgetGoBackToPlaceholdersOldestFirst {
    _store = [self storeWithBudget:8];
    NSURL *one = [self placeholder:@"one.flac" bytes:[NSData dataWithBytes:"11111" length:5]];
    NSURL *two = [self placeholder:@"two.flac" bytes:[NSData dataWithBytes:"22222" length:5]];
    XCTAssertTrue([self fetch:one]);
    XCTAssertEqual([self measuredDownloads], 5);
    XCTAssertTrue([self fetch:two]);
    XCTAssertEqual([self measuredDownloads], 5);

    struct stat evicted = StatOf(one);
    XCTAssertEqual(evicted.st_mode & 0777, 0);
    XCTAssertEqual(evicted.st_size, 5);
    XCTAssertEqual(evicted.st_mtimespec.tv_sec, kStamp);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:two], [NSData dataWithBytes:"22222" length:5]);
    XCTAssertEqualObjects(_store.reportedTotals, (@[@5, @5]));
}

- (void)testTheBudgetNeverEvictsTheFileItKeeps {
    NSURL *one = [self placeholder:@"one.flac" bytes:[NSData dataWithBytes:"11111" length:5]];
    NSURL *two = [self placeholder:@"two.flac" bytes:[NSData dataWithBytes:"22222" length:5]];
    XCTAssertTrue([self fetch:one]);
    XCTAssertTrue([self fetch:two]);
    XCTAssertEqual([self measuredDownloads], 10);

    // The oldest is kept, so the newer one goes, and the rest still exceed 1.
    // A store made over the same root: setting the budget would enforce it
    // with nothing kept.
    TestPlaceholderStore *store = [self storeWithBudget:1];
    __block long long total = -1;
    dispatch_sync(store.diskQueue, ^{
        total = [store enforceDownloadBudgetKeeping:one];
    });
    XCTAssertEqual(total, 5);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:one], [NSData dataWithBytes:"11111" length:5]);
    XCTAssertTrue(IsPlaceholder(two));
    XCTAssertEqual(StatOf(two).st_size, 5);
}

- (void)testASmallerBudgetAppliesAtOnceAndReportsTheTotal {
    NSURL *one = [self placeholder:@"one.flac" bytes:[NSData dataWithBytes:"111" length:3]];
    NSURL *two = [self placeholder:@"two.flac" bytes:[NSData dataWithBytes:"222" length:3]];
    XCTAssertTrue([self fetch:one]);
    XCTAssertTrue([self fetch:two]);
    XCTAssertEqual([self measuredDownloads], 6);

    _store.downloadBudget = 4;
    XCTAssertEqual(_store.downloadBudget, 4);
    XCTAssertEqual([self measuredDownloads], 3);
    XCTAssertTrue(IsPlaceholder(one), @"the oldest went back");
    XCTAssertEqualObjects(_store.reportedTotals.lastObject, @3);
}

- (void)testRemovingDownloadsLeavesPlaceholdersAndPlaylists {
    NSURL *one = [self placeholder:@"one.flac" bytes:[NSData dataWithBytes:"11111" length:5]];
    XCTAssertTrue([self fetch:one]);
    NSURL *sheet = [_album URLByAppendingPathComponent:@"one.cue"];
    [[NSData dataWithBytes:"FILE" length:4] writeToURL:sheet atomically:NO];

    XCTestExpectation *removed = [self expectationWithDescription:@"remove"];
    [_store removeDownloadsWithCompletion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[removed] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([self measuredDownloads], 0);
    XCTAssertTrue(IsPlaceholder(one));
    XCTAssertEqual(StatOf(one).st_size, 5);
    XCTAssertEqual(StatOf(one).st_mtimespec.tv_sec, kStamp);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:sheet], [NSData dataWithBytes:"FILE" length:4]);
    XCTAssertEqualObjects(_store.reportedTotals.lastObject, @0);
}

#pragma mark The backend

- (void)testInstallingTheBackendRoutesTheRootToTheStore {
    NSData *bytes = PatternBytes(1024 * 1024);
    NSURL *url = [self placeholder:@"a.flac" bytes:bytes];
    XCTAssertFalse([NSURLUtil isDatalessFile:url], @"no root yet");
    XCTAssertNil(CloudFileMaterializer.remoteRead);
    [_store installAsRemoteBackend];
    XCTAssertTrue([NSURLUtil isDatalessFile:url]);

    NSError *error = nil;
    XCTAssertEqualObjects(CloudFileMaterializer.remoteRead(url, 16, 32, &error),
                          [bytes subdataWithRange:NSMakeRange(16, 32)]);
    XCTAssertNil(error);
    XCTAssertEqualObjects([[_stub requestsToPath:@"/a.flac"].lastObject valueForHTTPHeaderField:@"Range"],
                          @"bytes=16-47");

    dispatch_semaphore_t gate = [self stallStreamOf:@"a.flac"];
    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    XCTestExpectation *readable = [self expectationWithDescription:@"readable"];
    XCTestExpectation *returned = [self expectationWithDescription:@"materialized"];
    __block BOOL materialized = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        materialized = [materializer materializeURL:url token:token onReadable:^{
            [readable fulfill];
        } error:NULL];
        [returned fulfill];
    });
    [self waitForExpectations:@[readable] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNotNil([_store availabilityForURL:url]);
    XCTAssertEqual([CloudFileMaterializer availabilityForURL:url], [_store availabilityForURL:url]);

    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(materialized);
    XCTAssertNil([CloudFileMaterializer availabilityForURL:url]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], bytes);
}

// Application Support that failed to resolve leaves a store with no root. It
// installs nothing, and the backend already there stays.
- (void)testAStoreWithNoRootLeavesTheOtherBackendsInstalled {
    NSURL *url = [self placeholder:@"a.flac" bytes:PatternBytes(4096)];
    [_store installAsRemoteBackend];
    NSURL *noRoot = nil;
    TestPlaceholderStore *rootless = [[TestPlaceholderStore alloc] initWithClient:_client rootURL:noRoot
                                                                    indexAttribute:kIndexAttribute
                                                                    downloadBudget:1LL << 40];
    [rootless installAsRemoteBackend];
    XCTAssertTrue([NSURLUtil isDatalessFile:url]);
    XCTAssertNotNil(CloudFileMaterializer.remoteRead);
}

@end
