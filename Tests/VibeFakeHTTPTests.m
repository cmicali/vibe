//
//  VibeFakeHTTPTests.m
//
//  The debug channel's fake web server, host-less: what each answer looks
//  like on the wire, what each fault does to the plain HTTPTransferClient,
//  and a LinkStore opening a link from it. The fake's state is process-wide,
//  so only this class drives it.
//

#import <XCTest/XCTest.h>

#include <sys/stat.h>

#import "HTTPStub.h"
#import "HTTPTransferClientInternal.h"
#import "LinkStore.h"
#import "NSURLUtil.h"
#import "VibeFakeHTTP.h"

static const NSUInteger kSongBytes = 512 * 1024;

// ID3, then a pattern: an MP3 to the probe, distinct bytes to every range.
static NSData *SongBytes(NSUInteger count) {
    NSMutableData *data = [PatternBytes(count) mutableCopy];
    memcpy(data.mutableBytes, "ID3\x04\x00", MIN(count, (NSUInteger)5));
    return data;
}

typedef struct {
    NSHTTPURLResponse *response;
    NSData *data;
    NSError *error;
} RawAnswer;

@interface VibeFakeHTTPTests : XCTestCase
@end

@implementation VibeFakeHTTPTests {
    HTTPTransferClient *_client;
    NSURLSession *_session;
    NSURL *_base;
    NSURL *_served;
    NSData *_song;
    time_t _songModified;
}

- (void)setUp {
    [super setUp];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"VibeFakeHTTPTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _base = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    _served = [_base URLByAppendingPathComponent:@"served" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:[_served URLByAppendingPathComponent:@"album"]
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    _song = SongBytes(kSongBytes);
    [_song writeToURL:[_served URLByAppendingPathComponent:@"album/song.mp3"] atomically:NO];
    _songModified = 1445412480;
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:
                                                      [NSDate dateWithTimeIntervalSince1970:_songModified]}
                                   ofItemAtPath:[_served URLByAppendingPathComponent:@"album/song.mp3"].path
                                          error:NULL];
    NSMutableData *flac = [SongBytes(4096) mutableCopy];
    memcpy(flac.mutableBytes, "fLaC", 4);
    [flac writeToURL:[_served URLByAppendingPathComponent:@"tone.flac"] atomically:NO];

    _client = [[HTTPTransferClient alloc] initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    _client.retryDelayScale = 0.01;
    [VibeFakeHTTP installWithDirectory:_served transferSeconds:0 client:_client];
    _session = [NSURLSession sessionWithConfiguration:VibeFakeHTTP.sessionConfiguration];
}

- (void)tearDown {
    [VibeFakeHTTP clearFaults];
    [VibeFakeHTTP uninstallFromClient:_client];
    [_session invalidateAndCancel];
    [NSFileManager.defaultManager removeItemAtURL:_base error:NULL];
    [super tearDown];
}

#pragma mark Helpers

- (NSURL *)songURL {
    return [NSURL URLWithString:@"https://fake.vibe.test/album/song.mp3"];
}

- (NSURL *)partURL {
    return [_base URLByAppendingPathComponent:@"song.part"];
}

// The fake's raw answer, headers and all.
- (RawAnswer)get:(NSURL *)url range:(NSString *)range {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if (range) {
        [request setValue:range forHTTPHeaderField:@"Range"];
    }
    __block RawAnswer answer = {0};
    XCTestExpectation *done = [self expectationWithDescription:@"get"];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        answer = (RawAnswer){(NSHTTPURLResponse *)response, data, error};
        [done fulfill];
    }] resume];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    return answer;
}

- (NSError *)downloadWithMetadata:(NSDictionary **)metadata
                         progress:(void (^)(uint64_t written, int64_t size, NSString *version))progress {
    __block NSError *result = nil;
    __block NSDictionary *answered = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    [_client downloadTarget:[self songURL] toURL:[self partURL] progress:progress
                 completion:^(NSDictionary *downloaded, NSError *error) {
        answered = downloaded;
        result = error;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (metadata) *metadata = answered;
    return result;
}

- (NSDictionary *)probeResponse:(NSHTTPURLResponse **)response error:(NSError **)error {
    __block NSDictionary *answered = nil;
    __block NSHTTPURLResponse *answeredResponse = nil;
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"probe"];
    [_client probeTarget:[self songURL] length:16
              completion:^(NSDictionary *metadata, NSHTTPURLResponse *probed, NSData *bytes, NSError *probeError) {
        answered = metadata;
        answeredResponse = probed;
        failure = probeError;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (response) *response = answeredResponse;
    if (error) *error = failure;
    return answered;
}

- (void)addFault:(NSString *)kind after:(uint64_t)after once:(NSNumber *)once {
    XCTAssertTrue([VibeFakeHTTP addFaultOfKind:kind file:nil after:after seconds:0 rate:0 status:0 once:once]);
}

- (NSArray<NSDictionary *> *)log {
    return VibeFakeHTTP.statistics[@"log"];
}

- (NSURL *)resolve:(LinkStore *)store link:(NSString *)link error:(NSError **)error {
    __block NSURL *file = nil;
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"resolved"];
    [store resolveURLString:link completion:^(NSURL *answer, NSError *answerError) {
        file = answer;
        failure = answerError;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (error) *error = failure;
    return file;
}

#pragma mark The answers

- (void)testAClosedRangeIsA206OfThoseBytes {
    RawAnswer answer = [self get:[self songURL] range:@"bytes=1000-5999"];
    XCTAssertEqual(answer.response.statusCode, 206);
    XCTAssertEqualObjects([answer.response valueForHTTPHeaderField:@"Content-Range"],
                          ([NSString stringWithFormat:@"bytes 1000-5999/%lu", (unsigned long)kSongBytes]));
    XCTAssertEqualObjects([answer.response valueForHTTPHeaderField:@"Content-Length"], @"5000");
    XCTAssertEqualObjects(answer.data, [_song subdataWithRange:NSMakeRange(1000, 5000)]);
}

- (void)testAnOpenRangeIsTheRestOfTheFile {
    RawAnswer answer = [self get:[self songURL] range:@"bytes=200000-"];
    XCTAssertEqual(answer.response.statusCode, 206);
    XCTAssertEqualObjects([answer.response valueForHTTPHeaderField:@"Content-Range"],
                          ([NSString stringWithFormat:@"bytes 200000-%lu/%lu", (unsigned long)kSongBytes - 1,
                            (unsigned long)kSongBytes]));
    XCTAssertEqualObjects(answer.data, [_song subdataWithRange:NSMakeRange(200000, kSongBytes - 200000)]);
}

- (void)testARangePastTheEndIs416 {
    RawAnswer answer = [self get:[self songURL]
                           range:[NSString stringWithFormat:@"bytes=%lu-", (unsigned long)kSongBytes]];
    XCTAssertEqual(answer.response.statusCode, 416);
    XCTAssertEqualObjects([answer.response valueForHTTPHeaderField:@"Content-Range"],
                          ([NSString stringWithFormat:@"bytes */%lu", (unsigned long)kSongBytes]));
}

- (void)testAWholeRequestIs200WithTheFilesVersionAndType {
    RawAnswer answer = [self get:[self songURL] range:nil];
    XCTAssertEqual(answer.response.statusCode, 200);
    XCTAssertEqualObjects(answer.data, _song);
    XCTAssertEqualObjects([answer.response valueForHTTPHeaderField:@"Content-Length"],
                          @(kSongBytes).stringValue);
    XCTAssertEqualObjects([answer.response valueForHTTPHeaderField:@"Content-Type"], @"audio/mpeg");
    XCTAssertEqualObjects([answer.response valueForHTTPHeaderField:@"Last-Modified"],
                          @"Wed, 21 Oct 2015 07:28:00 GMT");
    NSString *etag = [answer.response valueForHTTPHeaderField:@"ETag"];
    XCTAssertTrue([etag hasPrefix:@"\""] && [etag hasSuffix:@"\""], @"a strong ETag: %@", etag);
    XCTAssertEqualObjects(etag, [[self get:[self songURL] range:@"bytes=0-0"].response valueForHTTPHeaderField:@"ETag"],
                          @"every answer names one version");

    RawAnswer flac = [self get:[NSURL URLWithString:@"http://fake.local/tone.flac"] range:nil];
    XCTAssertEqual(flac.response.statusCode, 200);
    XCTAssertEqualObjects([flac.response valueForHTTPHeaderField:@"Content-Type"], @"audio/flac");
    XCTAssertNotEqualObjects([flac.response valueForHTTPHeaderField:@"ETag"], etag);
}

- (void)testAMissingFileIs404AndAnotherHostIsUnknown {
    XCTAssertEqual([self get:[NSURL URLWithString:@"https://fake.vibe.test/none.mp3"] range:nil].response.statusCode,
                   404);
    XCTAssertEqual([self get:[NSURL URLWithString:@"https://fake.vibe.test/../secret.mp3"] range:nil]
                           .response.statusCode, 404);
    RawAnswer elsewhere = [self get:[NSURL URLWithString:@"https://example.com/song.mp3"] range:nil];
    XCTAssertEqualObjects(elsewhere.error.domain, NSURLErrorDomain);
    XCTAssertEqual(elsewhere.error.code, NSURLErrorCannotFindHost);
    XCTAssertEqualObjects(self.log.lastObject[@"outcome"], @"unknown-host");
    XCTAssertEqual([VibeFakeHTTP.statistics[@"requests"] integerValue], 3);
}

- (void)testTheClientDownloadsTheFile {
    NSDictionary *metadata = nil;
    XCTAssertNil([self downloadWithMetadata:&metadata progress:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], _song);
    XCTAssertEqual([_client sizeOfMetadata:metadata], (int64_t)kSongBytes);
    XCTAssertNotNil([_client versionOfMetadata:metadata]);
}

#pragma mark The faults

- (void)testADropLosesTheConnectionAtItsOffset {
    // Every answer from 128 KB on drops there. The resends gain nothing.
    [self addFault:@"drop" after:128 * 1024 once:@NO];
    NSError *error = [self downloadWithMetadata:NULL progress:nil];
    XCTAssertEqualObjects(error.domain, NSURLErrorDomain);
    XCTAssertEqual(error.code, NSURLErrorNetworkConnectionLost);
    struct stat kept = {0};
    stat([self partURL].fileSystemRepresentation, &kept);
    XCTAssertEqual(kept.st_size, 128 * 1024, @"the link ended it, so the part is kept");
    XCTAssertEqualObjects(self.log.firstObject[@"outcome"], @"dropped");
    XCTAssertEqual([self.log.firstObject[@"delivered"] integerValue], 128 * 1024);
}

- (void)testAOnceDropIsResumedFromItsRange {
    [self addFault:@"drop" after:128 * 1024 once:nil];
    XCTAssertNil([self downloadWithMetadata:NULL progress:nil]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], _song);
    NSArray<NSDictionary *> *log = self.log;
    XCTAssertEqual(log.count, 2u);
    XCTAssertEqualObjects(log[0][@"outcome"], @"dropped");
    XCTAssertEqualObjects(log[1][@"range"], @"bytes=131072-");
    XCTAssertEqualObjects(log[1][@"outcome"], @"complete");
}

- (void)testNoRangeAnswersTheWholeFile {
    [self addFault:@"no-range" after:0 once:nil];
    RawAnswer answer = [self get:[self songURL] range:@"bytes=0-15"];
    XCTAssertEqual(answer.response.statusCode, 200);
    XCTAssertNil([answer.response valueForHTTPHeaderField:@"Content-Range"]);
    XCTAssertEqualObjects(answer.data, _song);
    NSHTTPURLResponse *response = nil;
    NSDictionary *metadata = [self probeResponse:&response error:NULL];
    XCTAssertEqual(response.statusCode, 200);
    XCTAssertEqual([_client sizeOfMetadata:metadata], (int64_t)kSongBytes);
}

- (void)testNoLengthStatesNoSize {
    [self addFault:@"no-length" after:0 once:nil];
    NSHTTPURLResponse *response = nil;
    NSDictionary *metadata = [self probeResponse:&response error:NULL];
    XCTAssertEqual(response.statusCode, 200);
    XCTAssertNil([response valueForHTTPHeaderField:@"Content-Length"]);
    XCTAssertNil([response valueForHTTPHeaderField:@"Content-Range"]);
    XCTAssertEqual([_client sizeOfMetadata:metadata], -1);
}

- (void)testIcyIsARadioStreamsHeaders {
    [self addFault:@"icy" after:0 once:nil];
    NSHTTPURLResponse *response = nil;
    NSDictionary *metadata = [self probeResponse:&response error:NULL];
    XCTAssertNotNil([response valueForHTTPHeaderField:@"icy-name"]);
    XCTAssertEqual([_client sizeOfMetadata:metadata], -1);
}

- (void)testStatusAnswersThatStatusOnce {
    XCTAssertTrue([VibeFakeHTTP addFaultOfKind:@"status" file:nil after:0 seconds:0 rate:0 status:404 once:@YES]);
    NSError *error = nil;
    [self probeResponse:NULL error:&error];
    XCTAssertEqual(error.code, VibeHTTPErrorStatus);
    XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], @404);
    XCTAssertEqual([self get:[self songURL] range:nil].response.statusCode, 200, @"once, so the next is the file");
    XCTAssertFalse([VibeFakeHTTP addFaultOfKind:@"status" file:nil after:0 seconds:0 rate:0 status:0 once:nil],
                   @"a status needs its code");
}

- (void)testHtmlIsAWebPage {
    [self addFault:@"html" after:0 once:nil];
    RawAnswer answer = [self get:[self songURL] range:@"bytes=0-15"];
    XCTAssertEqual(answer.response.statusCode, 200);
    XCTAssertTrue([[answer.response valueForHTTPHeaderField:@"Content-Type"] hasPrefix:@"text/html"]);
    XCTAssertTrue([[[NSString alloc] initWithData:answer.data encoding:NSUTF8StringEncoding] hasPrefix:@"<!doctype"]);
}

- (void)testGzipIsAnEncoded200WithNoSize {
    [self addFault:@"gzip" after:0 once:nil];
    NSHTTPURLResponse *response = nil;
    NSDictionary *metadata = [self probeResponse:&response error:NULL];
    XCTAssertEqual(response.statusCode, 200);
    XCTAssertEqualObjects([response valueForHTTPHeaderField:@"Content-Encoding"], @"gzip");
    XCTAssertEqual([_client sizeOfMetadata:metadata], -1, @"an encoded length is not the file's");
}

- (void)testAnETagChangeMovesTheVersionUnderAResend {
    NSHTTPURLResponse *before = [self get:[self songURL] range:@"bytes=0-0"].response;
    [self addFault:@"etag-change" after:128 * 1024 once:nil];
    NSError *error = [self downloadWithMetadata:NULL progress:nil];
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorVersionChanged);
    NSHTTPURLResponse *after = [self get:[self songURL] range:@"bytes=0-0"].response;
    XCTAssertNotEqualObjects([after valueForHTTPHeaderField:@"ETag"], [before valueForHTTPHeaderField:@"ETag"]);
    XCTAssertNotEqualObjects([after valueForHTTPHeaderField:@"Last-Modified"],
                             [before valueForHTTPHeaderField:@"Last-Modified"],
                             @"both move, or the client would take it for the CDN case");
    [VibeFakeHTTP clearFaults];
    XCTAssertEqualObjects([[self get:[self songURL] range:@"bytes=0-0"].response valueForHTTPHeaderField:@"ETag"],
                          [after valueForHTTPHeaderField:@"ETag"], @"the version stays where it moved");
}

- (void)testAStallHoldsUntilTheFaultsClear {
    [self addFault:@"stall" after:128 * 1024 once:nil];
    dispatch_semaphore_t held = dispatch_semaphore_create(0);
    __block BOOL signalled = NO;
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    __block NSError *result = nil;
    [_client downloadTarget:[self songURL] toURL:[self partURL]
                   progress:^(uint64_t written, int64_t size, NSString *version) {
        if (written >= 128 * 1024 && !signalled) {
            signalled = YES;
            dispatch_semaphore_signal(held);
        }
    } completion:^(NSDictionary *metadata, NSError *error) {
        result = error;
        [done fulfill];
    }];
    XCTAssertEqual(dispatch_semaphore_wait(held, dispatch_time(DISPATCH_TIME_NOW,
                                                               (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    // Negative: held. Nothing arrives in a short window.
    XCTestExpectation *nothing = [self expectationWithDescription:@"no more bytes"];
    nothing.inverted = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        struct stat part = {0};
        stat([self partURL].fileSystemRepresentation, &part);
        if (part.st_size != 128 * 1024) {
            [nothing fulfill];
        }
    });
    [self waitForExpectations:@[nothing] timeout:0.5];
    XCTAssertEqualObjects(VibeFakeHTTP.statistics[@"transfers"][0][@"outcome"], @"stalled");
    [VibeFakeHTTP clearFaults];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertNil(result);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], _song);
}

- (void)testRateAndLatencyShowInTheFakesOwnStamps {
    XCTAssertTrue([VibeFakeHTTP addFaultOfKind:@"rate" file:nil after:0 seconds:0 rate:1024 * 1024 status:0 once:nil]);
    XCTAssertTrue([VibeFakeHTTP addFaultOfKind:@"latency" file:nil after:0 seconds:0.3 rate:0 status:0 once:nil]);
    XCTAssertNil([self downloadWithMetadata:NULL progress:nil]);
    NSDictionary *line = self.log.firstObject;
    double firstByte = [line[@"firstByte"] doubleValue] - [line[@"t"] doubleValue];
    double body = [line[@"finished"] doubleValue] - [line[@"firstByte"] doubleValue];
    XCTAssertGreaterThanOrEqual(firstByte, 0.25, @"the latency comes before the headers");
    // 512 KB at 1 MB/s is eight pieces 1/16 s apart.
    XCTAssertGreaterThanOrEqual(body, 0.35);
    XCTAssertLessThan(body, VIBE_TEST_HANG_TIMEOUT);
}

#pragma mark Links

- (void)testALocalLinkOpensFromTheFake {
    LinkStore *store = [[LinkStore alloc] initWithClient:_client rootURL:[_base URLByAppendingPathComponent:@"Links"]];
    NSError *error = nil;
    NSURL *file = [self resolve:store link:@"http://fake.local/album/song.mp3" error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertEqualObjects(file.lastPathComponent, @"song.mp3");
    struct stat st = {0};
    lstat(file.fileSystemRepresentation, &st);
    XCTAssertTrue(VibeFileModeIsRemotePlaceholder(st.st_mode));
    XCTAssertEqual(st.st_size, (off_t)kSongBytes);
    XCTAssertEqual(st.st_mtimespec.tv_sec, _songModified, @"the mtime is Last-Modified");
    XCTAssertEqualObjects(self.log.lastObject[@"range"], @"bytes=0-15", @"the probe");
}

- (void)testAPublicPlainHTTPLinkSendsNothing {
    LinkStore *store = [[LinkStore alloc] initWithClient:_client rootURL:[_base URLByAppendingPathComponent:@"Links"]];
    for (NSString *link in @[@"http://8.8.8.8/x.mp3", @"http://vibe.example.com/album/song.mp3"]) {
        NSError *error = nil;
        XCTAssertNil([self resolve:store link:link error:&error]);
        XCTAssertEqualObjects(error.domain, VibeLinkErrorDomain);
        XCTAssertEqual(error.code, VibeLinkErrorInsecure, @"%@", link);
    }
    XCTAssertEqual([VibeFakeHTTP.statistics[@"requests"] integerValue], 0,
                   @"the fake answers every request on the client's sessions, and saw none");
}

@end
