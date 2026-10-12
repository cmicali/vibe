//
//  HTTPTransferClientTests.m
//
//  The plain-HTTP client over HTTPStub and a per-test temp directory: the
//  request defaults, the probe, the ranged read, the failure ladder, the
//  allowsURL check on requests and redirects, and the download's resends,
//  version pin, kept part, and length check.
//

#import <XCTest/XCTest.h>

#include <fcntl.h>
#include <sched.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/xattr.h>

#import "HTTPStub.h"
#import "HTTPTransferClientInternal.h"

static const char *const kVersionAttribute = "com.commonwealthrecordings.Vibe.rev";

// A client whose request hook waits for `hookGate` before answering, and
// signals `hookDone` once the base has taken the answer.
@interface HTTPTransferHeldClient : HTTPTransferClient
@property (nonatomic) dispatch_semaphore_t hookGate;
@property (nonatomic) dispatch_semaphore_t hookDone;
@end

@implementation HTTPTransferHeldClient

- (void)makeRequestForTarget:(id)target
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_wait(self.hookGate, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        [super makeRequestForTarget:target state:state completion:completion];
        dispatch_semaphore_signal(self.hookDone);
    });
}

@end

// How many of this process's descriptors are open on `url`.
static NSUInteger OpenDescriptorsOn(NSURL *url) {
    char wanted[PATH_MAX], path[PATH_MAX];
    if (!realpath(url.fileSystemRepresentation, wanted)) {
        return 0;
    }
    NSUInteger count = 0;
    for (int fd = 0; fd < getdtablesize(); fd++) {
        if (fcntl(fd, F_GETPATH, path) == 0 && strcmp(path, wanted) == 0) {
            count++;
        }
    }
    return count;
}

// A client whose failure ladder parks its resend for the test, as a hung
// token refresh does. `_entered` is relaxed, so it orders nothing. `parked`
// hands the resend over once the test has acted.
@interface HTTPTransferParkedClient : HTTPTransferClient {
@public
    atomic_bool _entered;
}
@property (nonatomic) dispatch_semaphore_t parked;
@property (nonatomic, copy) void (^resend)(NSInteger attempt);
@end

@implementation HTTPTransferParkedClient

- (void)handleFailureStatus:(NSInteger)status
                       data:(NSData *)data
                 retryAfter:(NSString *)retryAfter
                      state:(NSMutableDictionary<NSString *, id> *)state
                    attempt:(NSInteger)attempt
                     resend:(void (^)(NSInteger))resend
                       fail:(void (^)(NSError *))fail {
    self.resend = resend;
    atomic_store_explicit(&_entered, true, memory_order_relaxed);
    dispatch_semaphore_signal(self.parked);
}

@end

@interface HTTPTransferClientTests : XCTestCase
@end

@implementation HTTPTransferClientTests {
    HTTPStub *_stub;
    HTTPTransferClient *_client;
    NSURL *_directory;
    NSMutableArray<dispatch_semaphore_t> *_gates;
}

- (void)setUp {
    [super setUp];
    _stub = [[HTTPStub alloc] init];
    _client = [[HTTPTransferClient alloc] initWithConfiguration:_stub.configuration];
    _client.retryDelayScale = 0.01;
    _gates = [NSMutableArray array];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"HTTPTransferClientTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
    _directory = [NSURL fileURLWithPath:path isDirectory:YES];
}

- (void)tearDown {
    // A held stub delivery goes on to find its load stopped.
    for (dispatch_semaphore_t gate in _gates) {
        dispatch_semaphore_signal(gate);
    }
    [NSFileManager.defaultManager removeItemAtURL:_directory error:NULL];
    [super tearDown];
}

- (dispatch_semaphore_t)gate {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [_gates addObject:gate];
    return gate;
}

- (NSURL *)partURL {
    return [_directory URLByAppendingPathComponent:@"song.part"];
}

#pragma mark Helpers

typedef struct {
    NSDictionary *metadata;
    NSHTTPURLResponse *response;
    NSData *bytes;
    NSError *error;
} ProbeResult;

- (ProbeResult)probe:(NSURL *)url length:(uint64_t)length {
    __block ProbeResult result = {0};
    XCTestExpectation *done = [self expectationWithDescription:@"probe"];
    [_client probeTarget:url length:length
              completion:^(NSDictionary *metadata, NSHTTPURLResponse *response, NSData *bytes, NSError *error) {
        result = (ProbeResult){metadata, response, bytes, error};
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    return result;
}

- (NSData *)read:(NSURL *)url offset:(uint64_t)offset length:(uint64_t)length
        metadata:(NSDictionary **)metadata error:(NSError **)error {
    __block NSData *result = nil;
    __block NSDictionary *answeredMetadata = nil;
    __block NSError *answeredError = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"read"];
    [_client readTarget:url offset:offset length:length
             completion:^(NSData *data, NSDictionary *answered, NSError *failure) {
        result = data;
        answeredMetadata = answered;
        answeredError = failure;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (metadata) *metadata = answeredMetadata;
    if (error) *error = answeredError;
    return result;
}

// The download into partURL; progress, if given, sees every call.
- (NSError *)download:(NSURL *)url metadata:(NSDictionary **)metadata
             progress:(void (^)(uint64_t written, int64_t size, NSString *version))progress {
    __block NSError *result = nil;
    __block NSDictionary *answeredMetadata = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    [_client downloadTarget:url toURL:[self partURL] progress:progress
                 completion:^(NSDictionary *answered, NSError *error) {
        result = error;
        answeredMetadata = answered;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (metadata) *metadata = answeredMetadata;
    return result;
}

- (void)keepPart:(NSData *)bytes version:(NSString *)version {
    [bytes writeToURL:[self partURL] atomically:NO];
    if (version) {
        setxattr([self partURL].fileSystemRepresentation, kVersionAttribute, version.UTF8String,
                 strlen(version.UTF8String), 0, 0);
    }
}

- (NSString *)versionOfPart {
    char value[256] = {0};
    ssize_t length = getxattr([self partURL].fileSystemRepresentation, kVersionAttribute, value, sizeof value - 1, 0, 0);
    return length > 0 ? @(value) : nil;
}

- (BOOL)partExists {
    return [NSFileManager.defaultManager fileExistsAtPath:[self partURL].path];
}

#pragma mark Requests

- (void)testEveryRequestIsAnIdentityGETWithItsRange {
    NSData *file = PatternBytes(4000);
    [_stub serveData:file atPath:@"/a.flac" headers:nil];
    NSURL *url = [_stub URLForPath:@"/a.flac"];
    [self probe:url length:16];
    NSError *error = nil;
    NSData *read = [self read:url offset:100 length:200 metadata:NULL error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(read, [file subdataWithRange:NSMakeRange(100, 200)]);
    XCTAssertNil([self download:url metadata:NULL progress:nil]);
    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 3u);
    for (NSURLRequest *request in requests) {
        XCTAssertEqualObjects(request.HTTPMethod, @"GET");
        XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Accept-Encoding"], @"identity");
    }
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Range"], @"bytes=0-15");
    XCTAssertEqualObjects([requests[1] valueForHTTPHeaderField:@"Range"], @"bytes=100-299");
    XCTAssertNil([requests[2] valueForHTTPHeaderField:@"Range"]);
}

#pragma mark Probe

- (void)testARangedProbeStatesTheTotalAndTheStrongETag {
    NSData *file = PatternBytes(4000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\"", @"Content-Type": @"audio/flac",
                                                      @"Last-Modified": @"Wed, 21 Oct 2015 07:28:00 GMT"}];
    NSURL *url = [_stub URLForPath:@"/a.flac"];
    ProbeResult probe = [self probe:url length:16];
    XCTAssertNil(probe.error);
    XCTAssertEqual(probe.response.statusCode, 206);
    XCTAssertEqualObjects(probe.bytes, [file subdataWithRange:NSMakeRange(0, 16)]);
    XCTAssertEqualObjects(probe.metadata[@"size"], @4000);
    XCTAssertEqualObjects(probe.metadata[@"contentType"], @"audio/flac");
    XCTAssertEqualObjects(probe.metadata[@"url"], url);
    XCTAssertEqualObjects([_client versionOfMetadata:probe.metadata], @"\"v1\"");
    XCTAssertEqual([_client sizeOfMetadata:probe.metadata], 4000);
}

// The stall holds every byte past the first piece: only a probe that cancels
// itself at 16 bytes completes before the gate's timeout.
- (void)testAWholeAnswerProbeIsCutAtItsLength {
    NSData *file = PatternBytes(400000);
    HTTPStubFile *served = [_stub serveData:file atPath:@"/a.mp3" headers:nil];
    served.ignoresRanges = YES;
    served.chunk = 1024;
    [_stub queueStep:[HTTPStubStep stallAfter:4096 gate:[self gate]] forPath:@"/a.mp3"];
    ProbeResult probe = [self probe:[_stub URLForPath:@"/a.mp3"] length:16];
    XCTAssertNil(probe.error);
    XCTAssertEqual(probe.response.statusCode, 200);
    XCTAssertEqualObjects(probe.bytes, [file subdataWithRange:NSMakeRange(0, 16)]);
    XCTAssertEqualObjects(probe.metadata[@"size"], @400000);
}

- (void)testAnEncodedWholeAnswerStatesNoSize {
    HTTPStubFile *served = [_stub serveData:PatternBytes(4000) atPath:@"/a.mp3" headers:@{@"Content-Encoding": @"br"}];
    served.ignoresRanges = YES;
    ProbeResult probe = [self probe:[_stub URLForPath:@"/a.mp3"] length:16];
    XCTAssertNil(probe.error);
    XCTAssertEqual(probe.response.statusCode, 200);
    XCTAssertNil(probe.metadata[@"size"]);
    XCTAssertEqual([_client sizeOfMetadata:probe.metadata], -1);
}

- (void)testAWeakETagFallsBackToLastModified {
    NSString *modified = @"Wed, 21 Oct 2015 07:28:00 GMT";
    [_stub serveData:PatternBytes(4000) atPath:@"/a.flac" headers:@{@"ETag": @"W/\"v1\"", @"Last-Modified": modified}];
    ProbeResult probe = [self probe:[_stub URLForPath:@"/a.flac"] length:16];
    XCTAssertEqualObjects([_client versionOfMetadata:probe.metadata], modified);
}

- (void)testAShortFileIsAllOfIt {
    NSData *file = PatternBytes(5);
    [_stub serveData:file atPath:@"/a.flac" headers:nil];
    ProbeResult probe = [self probe:[_stub URLForPath:@"/a.flac"] length:16];
    XCTAssertNil(probe.error);
    XCTAssertEqualObjects(probe.bytes, file);
    XCTAssertEqualObjects(probe.metadata[@"size"], @5);
}

#pragma mark Failure ladder

// Retry-After 1000 capped at 10 s, scaled by 0.01: a tenth of a second, not ten.
- (void)testThrottlingWaitsCappedThenFailsWithTheStatus {
    [_stub serveData:PatternBytes(4000) atPath:@"/a.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep status:429 headers:@{@"Retry-After": @"3"} body:nil] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep status:503 headers:@{@"Retry-After": @"1000"} body:nil] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep status:429 headers:nil body:nil] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep status:429 headers:nil body:nil] forPath:@"/a.flac"];
    ProbeResult probe = [self probe:[_stub URLForPath:@"/a.flac"] length:16];
    XCTAssertEqualObjects(probe.error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(probe.error.code, VibeHTTPErrorStatus);
    XCTAssertEqualObjects(probe.error.userInfo[VibeHTTPErrorStatusCodeKey], @429);
    XCTAssertNil(probe.metadata);
    XCTAssertNil(probe.bytes);
    NSArray<NSNumber *> *times = _stub.requestTimes;
    XCTAssertEqual(times.count, 4u);
    if (times.count == 4) {
        XCTAssertGreaterThanOrEqual(times[1].doubleValue - times[0].doubleValue, 0.03);
        NSTimeInterval capped = times[2].doubleValue - times[1].doubleValue;
        XCTAssertGreaterThanOrEqual(capped, 0.1);
        XCTAssertLessThan(capped, 5.0);
    }
}

- (void)testAThrottleThenARefusalFailsWithTheRefusal {
    [_stub serveData:PatternBytes(4000) atPath:@"/a.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep status:503 headers:nil body:nil] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep status:404 headers:nil body:[@"gone" dataUsingEncoding:NSUTF8StringEncoding]]
             forPath:@"/a.flac"];
    NSError *error = nil;
    XCTAssertNil([self read:[_stub URLForPath:@"/a.flac"] offset:0 length:16 metadata:NULL error:&error]);
    XCTAssertEqual(error.code, VibeHTTPErrorStatus);
    XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], @404);
    XCTAssertEqual(_stub.requests.count, 2u);
}

#pragma mark allowsURL

- (void)testARefusedURLSendsNothing {
    _client.allowsURL = ^BOOL(NSURL *from, NSURL *url) {
        return [url.scheme isEqualToString:@"https"];
    };
    [_stub serveData:PatternBytes(4000) atPath:@"/a.flac" headers:nil];
    NSURL *url = [_stub URLForPath:@"/a.flac" scheme:@"http"];
    XCTAssertEqual([self probe:url length:16].error.code, VibeHTTPErrorRefusedURL);
    NSError *error = nil;
    [self read:url offset:0 length:16 metadata:NULL error:&error];
    XCTAssertEqual(error.code, VibeHTTPErrorRefusedURL);
    XCTAssertEqual([self download:url metadata:NULL progress:nil].code, VibeHTTPErrorRefusedURL);
    XCTAssertEqual(_stub.requests.count, 0u);
    XCTAssertFalse([self partExists]);
}

- (void)testARefusedRedirectFailsEveryTransfer {
    _client.allowsURL = ^BOOL(NSURL *from, NSURL *url) {
        return [url.scheme isEqualToString:@"https"];
    };
    [_stub serveData:PatternBytes(4000) atPath:@"/b.flac" headers:nil];
    NSURL *away = [_stub URLForPath:@"/b.flac" scheme:@"http"];
    for (NSUInteger i = 0; i < 3; i++) {
        [_stub queueStep:[HTTPStubStep redirectTo:away] forPath:@"/a.flac"];
    }
    NSURL *url = [_stub URLForPath:@"/a.flac"];
    ProbeResult probe = [self probe:url length:16];
    XCTAssertEqualObjects(probe.error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(probe.error.code, VibeHTTPErrorRefusedURL);
    NSError *error = nil;
    XCTAssertNil([self read:url offset:0 length:16 metadata:NULL error:&error]);
    XCTAssertEqual(error.code, VibeHTTPErrorRefusedURL);
    XCTAssertEqual([self download:url metadata:NULL progress:nil].code, VibeHTTPErrorRefusedURL);
    XCTAssertFalse([self partExists]);
    XCTAssertEqual([_stub requestsToPath:@"/a.flac"].count, 3u);
    XCTAssertEqual([_stub requestsToPath:@"/b.flac"].count, 0u);
}

- (void)testAnAllowedRedirectDownloads {
    NSMutableArray *asked = [NSMutableArray array];
    _client.allowsURL = ^BOOL(NSURL *from, NSURL *url) {
        @synchronized (asked) {
            [asked addObject:@[from ?: NSNull.null, url]];
        }
        return [url.scheme isEqualToString:@"https"];
    };
    NSData *file = PatternBytes(100000);
    [_stub serveData:file atPath:@"/b.flac" headers:@{@"ETag": @"\"e\""}];
    NSURL *cdn = [_stub URLForPath:@"/b.flac"];
    [_stub queueStep:[HTTPStubStep redirectTo:cdn] forPath:@"/a.flac"];
    NSDictionary *metadata = nil;
    XCTAssertNil([self download:[_stub URLForPath:@"/a.flac"] metadata:&metadata progress:nil]);
    XCTAssertEqualObjects(metadata[@"url"], cdn);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqualObjects([self versionOfPart], @"\"e\"");
    NSArray *expected = @[@[NSNull.null, [_stub URLForPath:@"/a.flac"]], @[[_stub URLForPath:@"/a.flac"], cdn]];
    XCTAssertEqualObjects(asked, expected, @"the request, then the redirect from where it was sent");
}

#pragma mark Download

- (void)testProgressFollowsTheBytesOnDisk {
    NSData *file = PatternBytes(300000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    // Held at 100000 bytes until the client notes them, so the bytes come in
    // two writes at least.
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:100000 gate:gate] forPath:@"/a.flac"];
    NSMutableArray<NSArray *> *calls = [NSMutableArray array];
    NSString *part = [self partURL].path;
    NSError *downloadError = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL
                       progress:^(uint64_t written, int64_t size, NSString *version) {
        if (written == 100000) {
            dispatch_semaphore_signal(gate);
        }
        struct stat info;
        long long onDisk = stat(part.fileSystemRepresentation, &info) == 0 ? info.st_size : -1;
        [calls addObject:@[@(written), @(size), version ?: NSNull.null, @(onDisk)]];
    }];
    XCTAssertNil(downloadError);
    XCTAssertGreaterThan(calls.count, 2u);
    XCTAssertEqualObjects(calls.firstObject[0], @0);
    uint64_t previous = 0;
    for (NSArray *call in calls) {
        XCTAssertEqualObjects(call[0], call[3], @"the bytes noted are the bytes on disk");
        XCTAssertEqualObjects(call[1], @300000);
        XCTAssertEqualObjects(call[2], @"\"v1\"");
        XCTAssertGreaterThanOrEqual([call[0] unsignedLongLongValue], previous);
        previous = [call[0] unsignedLongLongValue];
    }
    XCTAssertEqual(previous, 300000u);
}

- (void)testADroppedDownloadResumesFromItsLastByteWithTheSameVersion {
    NSData *file = PatternBytes(1000000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    __block _Atomic uint64_t written = 0;
    [_stub queueStep:[HTTPStubStep dropAfter:300000 ready:^BOOL {
        return atomic_load(&written) >= 300000;
    }] forPath:@"/a.flac"];
    NSDictionary *metadata = nil;
    NSError *downloadError = [self download:[_stub URLForPath:@"/a.flac"] metadata:&metadata
                       progress:^(uint64_t bytes, int64_t size, NSString *version) {
        atomic_store(&written, bytes);
    }];
    XCTAssertNil(downloadError);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqualObjects(metadata[@"etag"], @"\"v1\"");
    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 2u);
    XCTAssertNil([requests.firstObject valueForHTTPHeaderField:@"Range"]);
    XCTAssertEqualObjects([requests.lastObject valueForHTTPHeaderField:@"Range"], @"bytes=300000-");
}

- (void)testAVersionChangeOnTheResendFailsAndDeletesThePart {
    [_stub serveData:PatternBytes(1000000) atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    __block _Atomic uint64_t written = 0;
    [_stub queueStep:[HTTPStubStep dropAfter:300000 ready:^BOOL {
        return atomic_load(&written) >= 300000;
    }] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep changeHeaders:@{@"ETag": @"\"v2\""}] forPath:@"/a.flac"];
    NSError *error = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL
                           progress:^(uint64_t bytes, int64_t size, NSString *version) {
        atomic_store(&written, bytes);
    }];
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorVersionChanged);
    XCTAssertFalse([self partExists]);
    XCTAssertEqual(_stub.requests.count, 2u);
}

- (void)testAKeptPartResumesFromItsLength {
    NSData *file = PatternBytes(500000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [self keepPart:[file subdataWithRange:NSMakeRange(0, 100000)] version:@"\"v1\""];
    NSMutableArray<NSNumber *> *noted = [NSMutableArray array];
    NSError *downloadError = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL
                       progress:^(uint64_t bytes, int64_t size, NSString *version) {
        [noted addObject:@(bytes)];
    }];
    XCTAssertNil(downloadError);
    XCTAssertEqualObjects(noted.firstObject, @100000);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqual(_stub.requests.count, 1u);
    XCTAssertEqualObjects([_stub.requests.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
}

- (void)testAKeptPartOfAnotherVersionStartsOver {
    NSData *file = PatternBytes(500000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v2\""}];
    [self keepPart:PatternBytes(100000) version:@"\"v1\""];
    XCTAssertNil([self download:[_stub URLForPath:@"/a.flac"] metadata:NULL progress:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqualObjects([self versionOfPart], @"\"v2\"");
    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 2u);
    XCTAssertEqualObjects([requests.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
    XCTAssertNil([requests.lastObject valueForHTTPHeaderField:@"Range"]);
}

- (void)testAKeptPartWithNoVersionIsReplaced {
    NSData *file = PatternBytes(200000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [self keepPart:PatternBytes(50000) version:nil];
    XCTAssertNil([self download:[_stub URLForPath:@"/a.flac"] metadata:NULL progress:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqual(_stub.requests.count, 1u);
    XCTAssertNil([_stub.requests.firstObject valueForHTTPHeaderField:@"Range"]);
}

- (void)testAKeptPartLongerThanTheFileRestartsWhole {
    NSData *file = PatternBytes(50000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [self keepPart:PatternBytes(100000) version:@"\"v1\""];
    XCTAssertNil([self download:[_stub URLForPath:@"/a.flac"] metadata:NULL progress:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 2u);
    XCTAssertEqualObjects([requests.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
    XCTAssertNil([requests.lastObject valueForHTTPHeaderField:@"Range"]);
}

- (void)testAWholeAnswerToARangedResendSkipsTheBytesWritten {
    NSData *file = PatternBytes(1000000);
    HTTPStubFile *served = [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    served.ignoresRanges = YES;
    __block _Atomic uint64_t written = 0;
    [_stub queueStep:[HTTPStubStep dropAfter:300000 ready:^BOOL {
        return atomic_load(&written) >= 300000;
    }] forPath:@"/a.flac"];
    NSError *downloadError = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL
                       progress:^(uint64_t bytes, int64_t size, NSString *version) {
        atomic_store(&written, bytes);
    }];
    XCTAssertNil(downloadError);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqual(_stub.requests.count, 2u);
    XCTAssertEqualObjects([_stub.requests.lastObject valueForHTTPHeaderField:@"Range"], @"bytes=300000-");
}

- (void)testADownloadOfAnotherLengthThanItsSizeFailsAndDeletesThePart {
    NSData *file = PatternBytes(4000);
    [_stub serveData:file atPath:@"/a.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep status:200 headers:@{@"Content-Length": @"5000", @"ETag": @"\"v1\""} body:file]
             forPath:@"/a.flac"];
    NSError *error = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL progress:nil];
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorLengthMismatch);
    XCTAssertFalse([self partExists]);
}

- (void)testADropAfterTheLastByteIsComplete {
    NSData *file = PatternBytes(200000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    __block _Atomic uint64_t written = 0;
    [_stub queueStep:[HTTPStubStep dropAfter:file.length ready:^BOOL {
        return atomic_load(&written) >= 200000;
    }] forPath:@"/a.flac"];
    NSError *downloadError = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL
                       progress:^(uint64_t bytes, int64_t size, NSString *version) {
        atomic_store(&written, bytes);
    }];
    XCTAssertNil(downloadError);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqual(_stub.requests.count, 1u);
}

- (void)testACancelBeforeTheRequestNeverSendsIt {
    HTTPTransferHeldClient *client = [[HTTPTransferHeldClient alloc] initWithConfiguration:_stub.configuration];
    client.hookGate = [self gate];
    client.hookDone = dispatch_semaphore_create(0);
    [_stub serveData:PatternBytes(4000) atPath:@"/a.flac" headers:nil];
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"cancelled"];
    dispatch_block_t cancel = [client downloadTarget:[_stub URLForPath:@"/a.flac"] toURL:[self partURL] progress:nil
                                          completion:^(NSDictionary *metadata, NSError *error) {
        failure = error;
        [done fulfill];
    }];
    cancel();
    // Settled at once, with the hook still holding the request.
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(failure.code, VibeHTTPErrorCancelled);
    dispatch_semaphore_signal(client.hookGate);
    XCTAssertEqual(dispatch_semaphore_wait(client.hookDone, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    XCTAssertEqual(_stub.requests.count, 0u);
}

- (void)testACancelMidBodyKeepsThePartWithItsVersion {
    NSData *file = PatternBytes(500000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [_stub queueStep:[HTTPStubStep stallAfter:131072 gate:[self gate]] forPath:@"/a.flac"];
    dispatch_semaphore_t reached = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"cancelled"];
    dispatch_block_t cancel = [_client downloadTarget:[_stub URLForPath:@"/a.flac"] toURL:[self partURL]
                                             progress:^(uint64_t bytes, int64_t size, NSString *version) {
        if (bytes == 131072) {
            dispatch_semaphore_signal(reached);
        }
    } completion:^(NSDictionary *metadata, NSError *error) {
        failure = error;
        [done fulfill];
    }];
    XCTAssertEqual(dispatch_semaphore_wait(reached, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    cancel();
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(failure.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(failure.code, VibeHTTPErrorCancelled);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], [file subdataWithRange:NSMakeRange(0, 131072)]);
    XCTAssertEqualObjects([self versionOfPart], @"\"v1\"");
}

// A cancel racing the step that ended a download's last task, as Dropbox's
// does when the token refresh after a 401 hangs. The file is the steps'
// alone: the cancel settles at once without touching it, and the step that
// runs next closes it. Before, the cancel closed it while the delegate's
// step could still read it. The test sees the step parked through a relaxed
// atomic, which orders nothing, so ThreadSanitizer sees the two threads as
// concurrent.
- (void)testACancelWhileAStepHoldsTheFileSettlesAtOnceAndLeavesTheFileToTheStep {
    NSData *file = PatternBytes(500000);
    NSURL *part = [self partURL];
    HTTPTransferParkedClient *client = [[HTTPTransferParkedClient alloc] initWithConfiguration:_stub.configuration];
    client.parked = dispatch_semaphore_create(0);
    client.retryDelayScale = 0.01;
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [_stub queueStep:[HTTPStubStep dropAfter:131072 ready:^BOOL {
        struct stat st;
        return stat(part.fileSystemRepresentation, &st) == 0 && st.st_size >= 131072;
    }] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep status:503 headers:nil body:nil] forPath:@"/a.flac"];
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"cancelled"];
    dispatch_block_t cancel = [client downloadTarget:[_stub URLForPath:@"/a.flac"] toURL:part progress:nil
                                          completion:^(NSDictionary *metadata, NSError *error) {
        failure = error;
        [done fulfill];
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!atomic_load_explicit(&client->_entered, memory_order_relaxed) && deadline.timeIntervalSinceNow > 0) {
        sched_yield();
    }
    XCTAssertTrue(atomic_load_explicit(&client->_entered, memory_order_relaxed), @"the 503's step parked");
    cancel();
    // Settled with the step still parked.
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(failure.code, VibeHTTPErrorCancelled);
    XCTAssertEqual(OpenDescriptorsOn(part), 1u, @"the step still holds the file");
    XCTAssertEqual(dispatch_semaphore_wait(client.parked, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    // The step resends, finds the cancel, and closes the file. Nothing is sent.
    client.resend(2);
    XCTAssertEqual(OpenDescriptorsOn(part), 0u);
    XCTAssertEqual(_stub.requests.count, 2u);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:part], [file subdataWithRange:NSMakeRange(0, 131072)]);
    XCTAssertEqualObjects([self versionOfPart], @"\"v1\"");
}

// A kept part as long as the file is the file: the 416 to its resend, of
// its version, completes the download with the bytes kept.
- (void)testAKeptPartHoldingTheWholeFileIsComplete {
    NSData *file = PatternBytes(4000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [self keepPart:file version:@"\"v1\""];
    NSDictionary *metadata = nil;
    XCTAssertNil([self download:[_stub URLForPath:@"/a.flac"] metadata:&metadata progress:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    XCTAssertEqual([_client sizeOfMetadata:metadata], 4000);
    XCTAssertEqualObjects([_client versionOfMetadata:metadata], @"\"v1\"");
    XCTAssertEqual(_stub.requests.count, 1u);
    XCTAssertEqualObjects([_stub.requests.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=4000-");
}

- (void)testAKeptPartOfAnotherVersionAsLongAsTheFileStartsOver {
    NSData *file = PatternBytes(4000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v2\""}];
    [self keepPart:PatternBytes(4000) version:@"\"v1\""];
    XCTAssertNil([self download:[_stub URLForPath:@"/a.flac"] metadata:NULL progress:nil]);
    XCTAssertEqualObjects([self versionOfPart], @"\"v2\"");
    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 2u);
    XCTAssertNil([requests.lastObject valueForHTTPHeaderField:@"Range"]);
}

// A resend answered from an earlier byte skips what the file holds, as a
// whole answer does.
- (void)testAPartialResendFromAnEarlierByteSkipsTheBytesWritten {
    NSData *file = PatternBytes(1000000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    __block _Atomic uint64_t written = 0;
    [_stub queueStep:[HTTPStubStep dropAfter:300000 ready:^BOOL {
        return atomic_load(&written) >= 300000;
    }] forPath:@"/a.flac"];
    NSData *rest = [file subdataWithRange:NSMakeRange(200000, 800000)];
    [_stub queueStep:[HTTPStubStep status:206 headers:@{@"ETag": @"\"v1\"",
                                                        @"Content-Range": @"bytes 200000-999999/1000000"}
                                      body:rest] forPath:@"/a.flac"];
    NSError *downloadError = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL
                       progress:^(uint64_t bytes, int64_t size, NSString *version) {
        atomic_store(&written, bytes);
    }];
    XCTAssertNil(downloadError);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
}

// A resend answered from past the bytes written would leave a gap.
- (void)testAPartialResendFromALaterByteFailsAndDeletesThePart {
    NSData *file = PatternBytes(1000000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    __block _Atomic uint64_t written = 0;
    [_stub queueStep:[HTTPStubStep dropAfter:300000 ready:^BOOL {
        return atomic_load(&written) >= 300000;
    }] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep status:206 headers:@{@"ETag": @"\"v1\"",
                                                        @"Content-Range": @"bytes 400000-999999/1000000"}
                                      body:[file subdataWithRange:NSMakeRange(400000, 600000)]]
             forPath:@"/a.flac"];
    NSError *error = [self download:[_stub URLForPath:@"/a.flac"] metadata:NULL
                           progress:^(uint64_t bytes, int64_t size, NSString *version) {
        atomic_store(&written, bytes);
    }];
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorBadRange);
    XCTAssertFalse([self partExists]);
}

// A kept part's resend answered from past its end starts over, whole.
- (void)testAKeptPartAnsweredFromALaterByteStartsOver {
    NSData *file = PatternBytes(500000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [self keepPart:[file subdataWithRange:NSMakeRange(0, 100000)] version:@"\"v1\""];
    [_stub queueStep:[HTTPStubStep status:206 headers:@{@"ETag": @"\"v1\"",
                                                        @"Content-Range": @"bytes 200000-499999/500000"}
                                      body:[file subdataWithRange:NSMakeRange(200000, 300000)]]
             forPath:@"/a.flac"];
    XCTAssertNil([self download:[_stub URLForPath:@"/a.flac"] metadata:NULL progress:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], file);
    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 2u);
    XCTAssertEqualObjects([requests.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
    XCTAssertNil([requests.lastObject valueForHTTPHeaderField:@"Range"]);
}

#pragma mark Ranged read

- (void)testARangedReadAnswersItsBytesAndTheFilesSize {
    NSData *file = PatternBytes(4000);
    [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSDictionary *metadata = nil;
    NSError *error = nil;
    NSData *read = [self read:[_stub URLForPath:@"/a.flac"] offset:3900 length:500 metadata:&metadata error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(read, [file subdataWithRange:NSMakeRange(3900, 100)], @"fewer bytes only at the end");
    XCTAssertEqualObjects(metadata[@"size"], @4000);
    XCTAssertEqualObjects([_client versionOfMetadata:metadata], @"\"v1\"");
}

- (void)testAReadPastTheEndOfAWholeAnswerIsEmpty {
    HTTPStubFile *served = [_stub serveData:PatternBytes(4000) atPath:@"/a.flac" headers:nil];
    served.ignoresRanges = YES;
    NSError *error = nil;
    NSData *read = [self read:[_stub URLForPath:@"/a.flac"] offset:5000 length:100 metadata:NULL error:&error];
    XCTAssertNil(error);
    XCTAssertNotNil(read);
    XCTAssertEqual(read.length, 0u);
}

// A server ignoring the range sends the whole file. The read keeps its
// bytes and stops the answer, never holding the file in memory. The answer
// is held at 2 MB, so only a stop ends it in time.
- (void)testAWholeAnswerToAReadIsCutAndStopped {
    NSData *file = PatternBytes(5 * 1024 * 1024);
    HTTPStubFile *served = [_stub serveData:file atPath:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    served.ignoresRanges = YES;
    [_stub queueStep:[HTTPStubStep stallAfter:2 * 1024 * 1024 gate:[self gate]] forPath:@"/a.flac"];
    NSDictionary *metadata = nil;
    NSError *error = nil;
    NSData *read = [self read:[_stub URLForPath:@"/a.flac"] offset:1024 * 1024 length:4096 metadata:&metadata
                        error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(read, [file subdataWithRange:NSMakeRange(1024 * 1024, 4096)]);
    XCTAssertEqualObjects(metadata[@"size"], @(file.length));
    XCTAssertEqual(_stub.stoppedAnswers, 1u, @"cancelled before the body ended");
}

- (void)testAPartialAnswerFromAnotherByteFailsTheRead {
    NSData *file = PatternBytes(4000);
    [_stub serveData:file atPath:@"/a.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep status:206 headers:@{@"Content-Range": @"bytes 0-49/4000"}
                                      body:[file subdataWithRange:NSMakeRange(0, 50)]] forPath:@"/a.flac"];
    NSError *error = nil;
    XCTAssertNil([self read:[_stub URLForPath:@"/a.flac"] offset:100 length:50 metadata:NULL error:&error]);
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorBadRange);
}

#pragma mark Logs

- (void)testALogNamesALinkByItsHostAndFileOnly {
    NSURL *url = [NSURL URLWithString:@"https://user:secret@example.com/music/a.flac?token=key#t=10"];
    NSString *described = [_client descriptionOfTarget:url];
    XCTAssertEqualObjects(described, @"example.com/a.flac");
    for (NSString *hidden in @[@"user", @"secret", @"token", @"key", @"t=10", @"music"]) {
        XCTAssertFalse([described containsString:hidden], @"%@", hidden);
    }
    XCTAssertEqualObjects([_client descriptionOfTarget:[NSURL URLWithString:@"https://example.com/?a=b"]],
                          @"example.com");
}

// A server that honors ranges refuses one past the end: the status error.
- (void)testAReadPastTheEndOfARangedAnswerFailsWithItsStatus {
    [_stub serveData:PatternBytes(4000) atPath:@"/a.flac" headers:nil];
    NSError *error = nil;
    XCTAssertNil([self read:[_stub URLForPath:@"/a.flac"] offset:5000 length:100 metadata:NULL error:&error]);
    XCTAssertEqual(error.code, VibeHTTPErrorStatus);
    XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], @416);
}

@end
