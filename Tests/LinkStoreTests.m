//
//  LinkStoreTests.m
//
//  The Links backend over the plain HTTPTransferClient, HTTPStub and a
//  per-test temp root: what each probe answer opens as, the address rule on
//  the link and its redirects, the record and its reuse, the stream, the
//  resends and kept parts, the server that ignores ranges, the budget, the
//  pruning and the backend beside another root.
//

#import <XCTest/XCTest.h>

#include <stdatomic.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/xattr.h>

#import "CloudFileMaterializer.h"
#import "HTTPStub.h"
#import "HTTPTransferClientInternal.h"
#import "LinkStore.h"
#import "NSURL+Hash.h"
#import "NSURLUtil.h"
#import "RemotePlaceholderStoreInternal.h"

static const char *const kRecordAttribute = "com.commonwealthrecordings.vibe.link";
static const char *const kVersionAttribute = "com.commonwealthrecordings.Vibe.rev";
static NSString *const kModified = @"Wed, 21 Oct 2015 07:28:00 GMT";
static const time_t kModifiedTime = 1445412480;
// RemotePlaceholderStore's kStreamReadableBytes.
static const uint64_t kReadableBytes = 256 * 1024;
// Where a streaming download is held: past readable, short of the end.
static const NSUInteger kStallBytes = 5 * 64 * 1024;
// A small format's window (AudioFileOpenRules.h).
static const uint64_t kWindowBytes = 128 * 1024;
static const NSTimeInterval kDay = 24 * 60 * 60;

// A FLAC's signature, then a pattern: audio to the probe, distinct bytes to
// every range.
static NSData *FlacBytes(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        bytes[i] = (uint8_t)((i * 7 + i / 251) & 0xff);
    }
    memcpy(bytes, "fLaC", MIN(count, (NSUInteger)4));
    return data;
}

static struct stat StatOf(NSURL *url) {
    struct stat st = {0};
    lstat(url.fileSystemRepresentation, &st);
    return st;
}

static BOOL IsPlaceholder(NSURL *url) {
    struct stat st = StatOf(url);
    return S_ISREG(st.st_mode) && VibeFileModeIsRemotePlaceholder(st.st_mode);
}

static BOOL IsDownloaded(NSURL *url) {
    struct stat st = StatOf(url);
    return S_ISREG(st.st_mode) && !VibeFileModeIsRemotePlaceholder(st.st_mode);
}

@interface LinkStoreTests : XCTestCase
@end

@implementation LinkStoreTests {
    HTTPStub *_stub;
    HTTPTransferClient *_client;
    LinkStore *_store;
    NSURL *_base;
    NSURL *_root;
    NSMutableArray<dispatch_semaphore_t> *_gates;
}

- (void)setUp {
    [super setUp];
    _stub = [[HTTPStub alloc] init];
    _client = [[HTTPTransferClient alloc] initWithConfiguration:_stub.configuration];
    _client.retryDelayScale = 0.01;
    _gates = [NSMutableArray array];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"LinkStoreTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _base = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    _root = [_base URLByAppendingPathComponent:@"Links" isDirectory:YES];
    _store = [[LinkStore alloc] initWithClient:_client rootURL:_root];
}

- (void)tearDown {
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    // A held stub delivery goes on to find its load stopped.
    for (dispatch_semaphore_t gate in _gates) {
        dispatch_semaphore_signal(gate);
        dispatch_semaphore_signal(gate);
    }
    [NSFileManager.defaultManager removeItemAtURL:_base error:NULL];
    [super tearDown];
}

#pragma mark Helpers

- (dispatch_semaphore_t)gate {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [_gates addObject:gate];
    return gate;
}

- (HTTPStubFile *)serve:(NSData *)bytes at:(NSString *)path headers:(NSDictionary<NSString *, NSString *> *)headers {
    return [_stub serveData:bytes atPath:path headers:headers];
}

- (NSURL *)resolve:(NSString *)link error:(NSError **)error {
    __block NSURL *file = nil;
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"resolved"];
    [_store resolveURLString:link completion:^(NSURL *answer, NSError *answerError) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertTrue((answer == nil) != (answerError == nil), @"exactly one of file and error");
        file = answer;
        failure = answerError;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (error) *error = failure;
    return file;
}

- (NSURL *)resolvePath:(NSString *)path {
    NSError *error = nil;
    NSURL *file = [self resolve:[_stub URLForPath:path].absoluteString error:&error];
    XCTAssertNotNil(file, @"%@", error);
    return file;
}

// The link's failure, which must be one of the store's own.
- (VibeLinkError)failureOf:(NSString *)link {
    NSError *error = nil;
    XCTAssertNil([self resolve:link error:&error]);
    XCTAssertEqualObjects(error.domain, VibeLinkErrorDomain);
    return (VibeLinkError)error.code;
}

- (NSDictionary *)recordOf:(NSURL *)file {
    return [_store indexOfDirectory:file.URLByDeletingLastPathComponent];
}

- (void)setRecordOf:(NSURL *)file opened:(NSTimeInterval)opened {
    NSMutableDictionary *record = [[self recordOf:file] mutableCopy];
    record[@"opened"] = @(opened);
    [_store writeIndex:record ofDirectory:file.URLByDeletingLastPathComponent];
}

- (BOOL)fetch:(NSURL *)url error:(NSError **)error {
    return [_store fetchPlaceholderAtURL:url onReadable:nil onCancel:^(dispatch_block_t cancel) {
    } error:error];
}

- (void)fetchExpectingSuccess:(NSURL *)url {
    NSError *error = nil;
    XCTAssertTrue([self fetch:url error:&error], @"%@", error);
}

- (NSArray<NSString *> *)linkDirectories {
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:_root.path error:NULL]
            sortedArrayUsingSelector:@selector(compare:)] ?: @[];
}

- (void)settleDiskQueue {
    dispatch_sync(_store.diskQueue, ^{
    });
}

- (void)waitUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        usleep(1000);
    }
}

// A drop of the next answer to path once `bytes` of url's part are on disk:
// a failure sent straight after the bytes overtakes them on the client's side.
- (void)dropNextAnswerTo:(NSString *)path after:(NSUInteger)bytes partOf:(NSURL *)url {
    NSString *part = [NSURLUtil remotePlaceholderPartURL:url].path;
    [_stub queueStep:[HTTPStubStep dropAfter:bytes ready:^BOOL {
        struct stat st;
        return stat(part.fileSystemRepresentation, &st) == 0 && (NSUInteger)st.st_size >= bytes;
    }] forPath:path];
}

- (NSArray<NSURLRequest *> *)requestsTo:(NSString *)path since:(NSUInteger)count {
    NSArray<NSURLRequest *> *requests = [_stub requestsToPath:path];
    return [requests subarrayWithRange:NSMakeRange(count, requests.count - MIN(count, requests.count))];
}

#pragma mark What a probe opens as

- (void)testARangedLinkBecomesARecordAndAPlaceholder {
    [self serve:FlacBytes(4000) at:@"/music/Song.flac"
        headers:@{@"ETag": @"\"v1\"", @"Last-Modified": kModified, @"Content-Type": @"audio/flac"}];
    NSURL *link = [_stub URLForPath:@"/music/Song.flac"];
    NSTimeInterval before = NSDate.date.timeIntervalSince1970;
    NSURL *file = [self resolvePath:@"/music/Song.flac"];

    XCTAssertEqualObjects(file.lastPathComponent, @"Song.flac");
    XCTAssertEqualObjects(file.URLByDeletingLastPathComponent.lastPathComponent, VibeLinkDirectoryName(link));
    XCTAssertEqualObjects(VibeComparablePath(file.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.path),
                          VibeComparablePath(_root.path));
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertEqual(StatOf(file).st_size, 4000);
    XCTAssertEqual(StatOf(file).st_mtimespec.tv_sec, kModifiedTime, @"the mtime is Last-Modified");

    NSDictionary *record = [self recordOf:file];
    XCTAssertEqualObjects(record[@"url"], link.absoluteString);
    XCTAssertEqualObjects(record[@"etag"], @"\"v1\"");
    XCTAssertEqualObjects(record[@"lastModified"], kModified);
    XCTAssertEqualObjects(record[@"version"], @"\"v1\"");
    XCTAssertEqualObjects(record[@"size"], @4000);
    XCTAssertEqualObjects(record[@"modified"], @(kModifiedTime));
    XCTAssertEqualObjects(record[@"contentType"], @"audio/flac");
    XCTAssertEqualObjects(record[@"ranges"], @YES);
    XCTAssertEqualObjects(record[@"host"], _stub.host);
    XCTAssertGreaterThanOrEqual([record[@"opened"] doubleValue], before - 1);

    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 1u, @"one probe");
    XCTAssertEqualObjects([requests.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=0-15");
}

- (void)testAWholeAnswerGivesTheSizeAndNoRanges {
    HTTPStubFile *served = [self serve:FlacBytes(400000) at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    served.ignoresRanges = YES;
    NSTimeInterval before = floor(NSDate.date.timeIntervalSince1970);
    NSURL *file = [self resolvePath:@"/a.flac"];
    XCTAssertEqual(StatOf(file).st_size, 400000);
    XCTAssertEqualObjects([self recordOf:file][@"ranges"], @NO);
    XCTAssertGreaterThanOrEqual(StatOf(file).st_mtimespec.tv_sec, before, @"no Last-Modified: the probe's time");
}

- (void)testAnEncodedWholeAnswerHasNoSize {
    HTTPStubFile *served = [self serve:FlacBytes(4000) at:@"/a.flac" headers:@{@"Content-Encoding": @"gzip"}];
    served.ignoresRanges = YES;
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/a.flac"].absoluteString], VibeLinkErrorNoSize);
    XCTAssertEqualObjects([self linkDirectories], @[], @"nothing written");
}

- (void)testAnAnswerWithNoSizeIsRefused {
    HTTPStubFile *served = [self serve:FlacBytes(4000) at:@"/a.flac"
                               headers:@{@"Content-Type": @"application/octet-stream"}];
    served.ignoresRanges = YES;
    served.omitsLength = YES;
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/a.flac"].absoluteString], VibeLinkErrorNoSize);
}

- (void)testIcyHeadersAreALiveStream {
    HTTPStubFile *served = [self serve:FlacBytes(4000) at:@"/radio"
                               headers:@{@"icy-name": @"Radio", @"Content-Type": @"audio/mpeg"}];
    served.ignoresRanges = YES;
    served.omitsLength = YES;
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/radio"].absoluteString], VibeLinkErrorLiveStream);
}

- (void)testChunkedAudioIsALiveStream {
    HTTPStubFile *served = [self serve:FlacBytes(4000) at:@"/radio"
                               headers:@{@"Transfer-Encoding": @"chunked", @"Content-Type": @"audio/mpeg"}];
    served.ignoresRanges = YES;
    served.omitsLength = YES;
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/radio"].absoluteString], VibeLinkErrorLiveStream);
}

- (void)testEachStatusNamesItsFailure {
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:nil];
    NSDictionary<NSNumber *, NSNumber *> *cases = @{
        @401: @(VibeLinkErrorDenied), @403: @(VibeLinkErrorDenied),
        @404: @(VibeLinkErrorNotFound), @410: @(VibeLinkErrorNotFound),
        @500: @(VibeLinkErrorServer), @418: @(VibeLinkErrorServer), @204: @(VibeLinkErrorServer),
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSNumber *status, NSNumber *expected, BOOL *stop) {
        [self->_stub queueStep:[HTTPStubStep status:status.integerValue headers:nil body:nil] forPath:@"/a.flac"];
        NSError *error = nil;
        XCTAssertNil([self resolve:[self->_stub URLForPath:@"/a.flac"].absoluteString error:&error]);
        XCTAssertEqualObjects(error.domain, VibeLinkErrorDomain);
        XCTAssertEqual(error.code, expected.integerValue, @"HTTP %@", status);
        XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], status);
    }];
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

// No stub answers either host, so the connection fails as an unknown host does.
- (void)testAFailedConnectionIsUnreachableOrTheLocalNetworks {
    NSString *name = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *public = [NSString stringWithFormat:@"https://nowhere-%@.example.com/a.flac", name];
    XCTAssertEqual([self failureOf:public], VibeLinkErrorUnreachable);
    NSString *local = [NSString stringWithFormat:@"http://pi-%@.local/a.flac", name];
    XCTAssertEqual([self failureOf:local], VibeLinkErrorLocalNetwork);
}

- (void)testTheTransportSecurityRefusalIsInsecure {
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep failWithError:[NSError errorWithDomain:NSURLErrorDomain
            code:NSURLErrorAppTransportSecurityRequiresSecureConnection userInfo:nil]] forPath:@"/a.flac"];
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/a.flac"].absoluteString], VibeLinkErrorInsecure);
}

- (void)testAWebPageIsNotAudio {
    [self serve:[@"<!doctype html><html></html>" dataUsingEncoding:NSUTF8StringEncoding] at:@"/a.mp3"
        headers:@{@"Content-Type": @"text/html; charset=utf-8"}];
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/a.mp3"].absoluteString], VibeLinkErrorNotAudio);
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

- (void)testARefusedAddressSendsNothing {
    [_stub answerHost:@"8.8.8.8"];
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:nil];
    XCTAssertEqual([self failureOf:@"http://8.8.8.8/a.flac"], VibeLinkErrorInsecure);
    XCTAssertEqual([self failureOf:@"ftp://8.8.8.8/a.flac"], VibeLinkErrorInvalid);
    XCTAssertEqual([self failureOf:@"8.8.8.8/a.flac"], VibeLinkErrorInvalid);
    XCTAssertEqual([self failureOf:@""], VibeLinkErrorInvalid);
    XCTAssertEqual(_stub.requests.count, 0u);
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

- (void)testARedirectToPublicPlainHTTPIsRefused {
    [_stub answerHost:@"example.com"];
    [self serve:FlacBytes(4000) at:@"/b.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep redirectTo:[NSURL URLWithString:@"http://example.com/b.flac"]] forPath:@"/a.flac"];
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/a.flac"].absoluteString], VibeLinkErrorInsecure);
    XCTAssertEqual([_stub requestsToPath:@"/a.flac"].count, 1u);
    XCTAssertEqual([_stub requestsToPath:@"/b.flac"].count, 0u, @"never sent");
}

// A public page cannot send Vibe's requests to a device at home, over
// https either.
- (void)testARedirectFromAPublicHostIntoTheLocalNetworkIsRefused {
    [_stub answerHost:@"example.com"];
    [_stub answerHost:@"192.168.1.1"];
    [self serve:FlacBytes(4000) at:@"/b.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep redirectTo:[NSURL URLWithString:@"http://192.168.1.1/b.flac"]] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep redirectTo:[NSURL URLWithString:@"https://192.168.1.1/b.flac"]] forPath:@"/a.flac"];
    XCTAssertEqual([self failureOf:@"https://example.com/a.flac"], VibeLinkErrorInsecure);
    XCTAssertEqual([self failureOf:@"https://example.com/a.flac"], VibeLinkErrorInsecure);
    XCTAssertEqual([_stub requestsToPath:@"/a.flac"].count, 2u);
    XCTAssertEqual([_stub requestsToPath:@"/b.flac"].count, 0u, @"never sent");
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

- (void)testARedirectBetweenPublicHostsOrWithinTheLocalNetworkOpens {
    [_stub answerHost:@"example.com"];
    [_stub answerHost:@"cdn.example.org"];
    [_stub answerHost:@"nas.local"];
    [self serve:FlacBytes(4000) at:@"/b.flac" headers:nil];
    [_stub queueStep:[HTTPStubStep redirectTo:[NSURL URLWithString:@"https://cdn.example.org/b.flac"]]
             forPath:@"/a.flac"];
    NSError *error = nil;
    XCTAssertNotNil([self resolve:@"https://example.com/a.flac" error:&error], @"%@", error);
    [_stub queueStep:[HTTPStubStep redirectTo:[NSURL URLWithString:@"http://nas.local/b.flac"]] forPath:@"/c.flac"];
    XCTAssertNotNil([self resolve:[_stub URLForPath:@"/c.flac" scheme:@"http"].absoluteString error:&error],
                    @"%@", error);
    XCTAssertEqual([_stub requestsToPath:@"/b.flac"].count, 2u);
}

- (void)testEveryRequestAsksForTheBytesAsStored {
    NSData *bytes = FlacBytes(4000);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    NSError *error = nil;
    XCTAssertEqualObjects([_store readPlaceholderAtURL:file offset:100 length:50 error:&error],
                          [bytes subdataWithRange:NSMakeRange(100, 50)]);
    [self fetchExpectingSuccess:file];
    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 3u);
    for (NSURLRequest *request in requests) {
        XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Accept-Encoding"], @"identity");
        XCTAssertEqualObjects(request.HTTPMethod, @"GET");
    }
}

- (void)testADropboxShareLinkAsksForTheFile {
    [_stub answerHost:@"www.dropbox.com"];
    NSMutableData *bytes = [FlacBytes(4000) mutableCopy];
    memcpy(bytes.mutableBytes, "ID3", 3);
    [self serve:bytes at:@"/scl/fi/abc123/Song.mp3" headers:@{@"ETag": @"\"v1\""}];
    NSError *error = nil;
    NSURL *file = [self resolve:@"https://www.dropbox.com/scl/fi/abc123/Song.mp3?rlkey=k1&dl=0" error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertEqualObjects(file.lastPathComponent, @"Song.mp3");
    NSURLComponents *sent = [NSURLComponents componentsWithURL:_stub.requests.firstObject.URL resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(sent.query, @"rlkey=k1&dl=1");
    XCTAssertEqualObjects([self recordOf:file][@"url"],
                          @"https://www.dropbox.com/scl/fi/abc123/Song.mp3?rlkey=k1&dl=1");
}

- (void)testTheBytesNameAFileWhoseURLDoesNot {
    [self serve:FlacBytes(4000) at:@"/stream" headers:@{@"Content-Type": @"application/octet-stream"}];
    XCTAssertEqualObjects([self resolvePath:@"/stream"].lastPathComponent, @"stream.flac");
}

// The headers Google answered for a shared WAV: no ETag, and the name only in
// Content-Disposition.
- (void)testAGoogleDriveLinkAsksForTheFileAndTakesItsName {
    [_stub answerHost:@"drive.usercontent.google.com"];
    NSMutableData *bytes = [FlacBytes(4000) mutableCopy];
    memcpy(bytes.mutableBytes, "RIFF\x01\x02\x03\x04WAVE", 12);
    [self serve:bytes at:@"/download" headers:@{
        @"Content-Type": @"audio/wav",
        @"Content-Disposition": @"attachment; filename=\"07A - Greg Benz Remix 0710.wav\"",
        @"Last-Modified": kModified,
    }];
    NSError *error = nil;
    NSURL *file = [self resolve:@"https://drive.google.com/file/d/1k_kSNfbzdX-Ab/view?usp=sharing" error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertEqualObjects(file.lastPathComponent, @"07A - Greg Benz Remix 0710.wav");
    NSURLComponents *sent = [NSURLComponents componentsWithURL:_stub.requests.firstObject.URL resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(sent.query, @"id=1k_kSNfbzdX-Ab&export=download&confirm=t");
    NSDictionary *record = [self recordOf:file];
    XCTAssertEqualObjects(record[@"url"],
                          @"https://drive.usercontent.google.com/download?id=1k_kSNfbzdX-Ab&export=download&confirm=t");
    XCTAssertEqualObjects(record[@"version"], kModified, @"no ETag: the version is Last-Modified");
    XCTAssertEqualObjects(record[@"ranges"], @YES);
    XCTAssertEqual(StatOf(file).st_size, 4000);
}

// A private or over-quota file answers a sign-in or quota page instead.
- (void)testAGooglePageInsteadOfTheFileFailsClearly {
    [_stub answerHost:@"drive.usercontent.google.com"];
    NSString *link = @"https://drive.google.com/file/d/1abc/view?usp=sharing";
    NSData *page = [@"<!DOCTYPE html><html><head><title>Sign in</title></head></html>"
                    dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *html = @{@"Content-Type": @"text/html; charset=utf-8"};
    HTTPStubFile *served = [self serve:page at:@"/download" headers:html];

    [_stub queueStep:[HTTPStubStep status:403 headers:html body:page] forPath:@"/download"];
    XCTAssertEqual([self failureOf:link], VibeLinkErrorDenied);

    XCTAssertEqual([self failureOf:link], VibeLinkErrorNotAudio, @"a page with its length");

    served.ignoresRanges = YES;
    served.omitsLength = YES;
    XCTAssertEqual([self failureOf:link], VibeLinkErrorNotAudio, @"a page with no length");
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

#pragma mark The record

- (void)testTheRecordRoundTripsThroughItsAttribute {
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:@{@"ETag": @"\"v1\"", @"Last-Modified": kModified}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    NSURL *directory = file.URLByDeletingLastPathComponent;
    char raw[2048] = {0};
    ssize_t length = getxattr(directory.fileSystemRepresentation, kRecordAttribute, raw, sizeof raw - 1, 0,
                              XATTR_NOFOLLOW);
    XCTAssertGreaterThan(length, 0);
    NSDictionary *stored = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:raw length:(NSUInteger)length]
                                                           options:0 error:NULL];
    XCTAssertEqualObjects(stored, [self recordOf:file]);
    LinkStore *other = [[LinkStore alloc] initWithClient:_client rootURL:_root];
    XCTAssertEqualObjects([other indexOfDirectory:directory], stored, @"read back by a new store");
    XCTAssertEqualObjects([_store recordOfLinkFileURL:file], stored, @"a shell reads it by the file");
    XCTAssertNil([_store recordOfLinkFileURL:[_base URLByAppendingPathComponent:@"a.flac"]], @"outside the root");
    NSSet *keys = [NSSet setWithArray:@[@"url", @"etag", @"lastModified", @"version", @"size", @"modified", @"ranges",
                                        @"host", @"opened"]];
    XCTAssertEqualObjects([NSSet setWithArray:stored.allKeys], keys, @"no Content-Type, so none recorded");
}

- (void)testReopeningReusesTheLinkAndTouchesItsOpenedTime {
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    ino_t inode = StatOf(file).st_ino;
    [self setRecordOf:file opened:1000];

    NSURL *again = [self resolvePath:@"/a.flac"];
    XCTAssertEqualObjects(again, file);
    XCTAssertEqual(StatOf(again).st_ino, inode, @"the placeholder was not written again");
    XCTAssertGreaterThan([[self recordOf:file][@"opened"] doubleValue], 1000);
    XCTAssertEqual([self linkDirectories].count, 1u);

    // A fragment and the host's case name the same link.
    NSURLComponents *spelled = [NSURLComponents componentsWithURL:[_stub URLForPath:@"/a.flac"] resolvingAgainstBaseURL:NO];
    spelled.host = spelled.host.uppercaseString;
    spelled.fragment = @"t=10";
    XCTAssertEqualObjects([self resolve:spelled.string error:NULL], file);

    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertTrue(IsDownloaded(file), @"the download is kept");
}

- (void)testAChangedVersionOnReopenGoesBackToAPlaceholder {
    HTTPStubFile *served = [self serve:FlacBytes(4000) at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self fetchExpectingSuccess:file];
    XCTAssertTrue(IsDownloaded(file));

    served.data = FlacBytes(5000);
    served.headers = @{@"ETag": @"\"v2\""};
    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertEqual(StatOf(file).st_size, 5000);
    XCTAssertEqualObjects([self recordOf:file][@"version"], @"\"v2\"");
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], served.data);
}

// A record from disk is checked field by field. One of the wrong shape is
// no record, and the link opens anew.
- (void)testARecordOfTheWrongShapeIsNoRecord {
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    NSMutableDictionary *record = [[self recordOf:file] mutableCopy];
    record[@"opened"] = @[@1];
    record[@"size"] = @"4000";
    [_store writeIndex:record ofDirectory:file.URLByDeletingLastPathComponent];
    ino_t inode = StatOf(file).st_ino;
    XCTAssertNil([_store recordOfLinkFileURL:file]);
    NSError *error = nil;
    XCTAssertNil([_store readPlaceholderAtURL:file offset:0 length:16 error:&error], @"no record names no target");

    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertNotEqual(StatOf(file).st_ino, inode, @"a fresh placeholder");
    XCTAssertEqualObjects([self recordOf:file][@"size"], @4000);
    XCTAssertNotNil([_store recordOfLinkFileURL:file]);
}

- (void)testALinkWithNoVersionIsFetchedAgain {
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:nil];
    NSURL *file = [self resolvePath:@"/a.flac"];
    XCTAssertNil([self recordOf:file][@"version"]);
    [self fetchExpectingSuccess:file];
    XCTAssertTrue(IsDownloaded(file));
    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertTrue(IsPlaceholder(file), @"nothing proves the download current");
}

- (void)testAnInstalledLinkOpensOffline {
    [self serve:FlacBytes(4000) at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    [self serve:FlacBytes(4000) at:@"/b.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self fetchExpectingSuccess:file];
    NSURL *placeholder = [self resolvePath:@"/b.flac"];
    [self setRecordOf:file opened:1000];

    NSError *offline = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
    [_stub queueStep:[HTTPStubStep failWithError:offline] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep failWithError:offline] forPath:@"/b.flac"];
    NSError *error = nil;
    XCTAssertEqualObjects([self resolve:[_stub URLForPath:@"/a.flac"].absoluteString error:&error], file);
    XCTAssertNil(error);
    XCTAssertGreaterThan([[self recordOf:file][@"opened"] doubleValue], 1000);
    // The stub's host ends in .test, a local name.
    XCTAssertEqual([self failureOf:[_stub URLForPath:@"/b.flac"].absoluteString], VibeLinkErrorLocalNetwork,
                   @"a placeholder has nothing to play offline");
    XCTAssertTrue(IsPlaceholder(placeholder));
}

#pragma mark The stream

- (void)testAStreamIsReadableWithItsTailWindowAndKeepsItsCacheKey {
    NSData *bytes = FlacBytes(1024 * 1024);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    NSString *key = file.cacheKey;
    XCTAssertNotNil(key);
    // The download and its tail read arrive in either order: each step holds
    // past the tail's length, so only the download is held.
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:@"/a.flac"];

    XCTestExpectation *readable = [self expectationWithDescription:@"readable"];
    XCTestExpectation *returned = [self expectationWithDescription:@"fetched"];
    __block BOOL fetched = NO;
    LinkStore *store = _store;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        fetched = [store fetchPlaceholderAtURL:file onReadable:^{
            [readable fulfill];
        } onCancel:^(dispatch_block_t cancel) {
        } error:NULL];
        [returned fulfill];
    });
    [self waitForExpectations:@[readable] timeout:VIBE_TEST_HANG_TIMEOUT];
    CloudFileAvailability *stream = [_store availabilityForURL:file];
    XCTAssertNotNil(stream);
    XCTAssertEqual(stream.size, bytes.length);
    XCTAssertGreaterThanOrEqual(stream.writtenBytes, kReadableBytes);
    [self waitUntil:^BOOL {
        return stream.windowLength > 0;
    }];
    XCTAssertEqual(stream.windowLength, kWindowBytes);
    XCTAssertEqualObjects([stream readyBytesAt:bytes.length - 64 length:64],
                          [bytes subdataWithRange:NSMakeRange(bytes.length - 64, 64)]);

    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(fetched);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqualObjects(file.cacheKey, key, @"the install keeps the probe's mtime");
}

- (void)testAChangeWhileStreamingUpdatesOnlyTheRecord {
    NSData *bytes = FlacBytes(1024 * 1024);
    HTTPStubFile *served = [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:@"/a.flac"];
    XCTestExpectation *readable = [self expectationWithDescription:@"readable"];
    XCTestExpectation *returned = [self expectationWithDescription:@"fetched"];
    __block BOOL fetched = NO;
    LinkStore *store = _store;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        fetched = [store fetchPlaceholderAtURL:file onReadable:^{
            [readable fulfill];
        } onCancel:^(dispatch_block_t cancel) {
        } error:NULL];
        [returned fulfill];
    });
    [self waitForExpectations:@[readable] timeout:VIBE_TEST_HANG_TIMEOUT];
    ino_t inode = StatOf(file).st_ino;

    served.headers = @{@"ETag": @"\"v2\""};
    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertEqual(StatOf(file).st_ino, inode, @"the placeholder under the stream stands");
    XCTAssertNotNil([_store availabilityForURL:file]);
    XCTAssertEqualObjects([self recordOf:file][@"version"], @"\"v2\"");

    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(fetched);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqualObjects([self recordOf:file][@"version"], @"\"v1\"", @"the record follows what was downloaded");
}

// The record moved to another version while the placeholder streamed. The
// stream is cancelled and keeps its part. The next open must not reuse the
// placeholder of the old size under the new record.
- (void)testAPlaceholderTheRecordMovedPastIsWrittenAgain {
    NSData *bytes = FlacBytes(1024 * 1024);
    HTTPStubFile *served = [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:@"/a.flac"];
    [_stub queueStep:[HTTPStubStep stallAfter:kStallBytes gate:gate] forPath:@"/a.flac"];
    XCTestExpectation *readable = [self expectationWithDescription:@"readable"];
    XCTestExpectation *returned = [self expectationWithDescription:@"fetched"];
    __block dispatch_block_t cancelFetch = nil;
    __block NSError *fetchError = nil;
    LinkStore *store = _store;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        XCTAssertFalse([store fetchPlaceholderAtURL:file onReadable:^{
            [readable fulfill];
        } onCancel:^(dispatch_block_t cancel) {
            @synchronized (self) {
                cancelFetch = cancel;
            }
        } error:&error]);
        fetchError = error;
        [returned fulfill];
    });
    [self waitForExpectations:@[readable] timeout:VIBE_TEST_HANG_TIMEOUT];

    NSData *changed = FlacBytes(1536 * 1024);
    served.data = changed;
    served.headers = @{@"ETag": @"\"v2\""};
    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertEqual(StatOf(file).st_size, (off_t)bytes.length, @"the placeholder under the stream stands");
    XCTAssertEqualObjects([self recordOf:file][@"size"], @(changed.length));

    @synchronized (self) {
        cancelFetch();
    }
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(fetchError.code, VibeHTTPErrorCancelled);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[NSURLUtil remotePlaceholderPartURL:file].path],
                  @"the cancel keeps the part");

    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertEqual(StatOf(file).st_size, (off_t)changed.length, @"a fresh placeholder of the new size");
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], changed);
}

- (void)testADroppedFetchResumesWhereItStopped {
    NSData *bytes = FlacBytes(200000);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self dropNextAnswerTo:@"/a.flac" after:100000 partOf:file];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    NSArray<NSURLRequest *> *fetches = [self requestsTo:@"/a.flac" since:1];
    XCTAssertEqual(fetches.count, 2u);
    XCTAssertNil([fetches.firstObject valueForHTTPHeaderField:@"Range"]);
    XCTAssertEqualObjects([fetches.lastObject valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
}

- (void)testAnotherETagOnAResendFails {
    [self serve:FlacBytes(200000) at:@"/a.flac" headers:@{@"ETag": @"\"v1\"", @"Last-Modified": kModified}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self dropNextAnswerTo:@"/a.flac" after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep changeHeaders:@{@"ETag": @"\"v2\"", @"Last-Modified": @"Thu, 22 Oct 2015 07:28:00 GMT"}]
             forPath:@"/a.flac"];
    NSError *error = nil;
    XCTAssertFalse([self fetch:file error:&error]);
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorVersionChanged);
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[NSURLUtil remotePlaceholderPartURL:file].path]);
}

// A CDN's edges can each tag one file with an ETag of their own.
- (void)testAnotherETagWithTheSameSizeAndDateIsTheSameFile {
    NSData *bytes = FlacBytes(200000);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"edge-1\"", @"Last-Modified": kModified}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self dropNextAnswerTo:@"/a.flac" after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep changeHeaders:@{@"ETag": @"\"edge-2\""}] forPath:@"/a.flac"];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqualObjects([self recordOf:file][@"version"], @"\"edge-1\"");
    XCTAssertEqual(StatOf(file).st_mtimespec.tv_sec, kModifiedTime);

    // And a reopen through a third edge keeps the download.
    XCTAssertEqualObjects([self resolvePath:@"/a.flac"], file);
    XCTAssertTrue(IsDownloaded(file));
}

- (void)testARangedReadOfAnotherFileFails {
    NSData *bytes = FlacBytes(4000);
    HTTPStubFile *served = [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\"", @"Last-Modified": kModified}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    served.headers = @{@"ETag": @"\"v2\"", @"Last-Modified": @"Thu, 22 Oct 2015 07:28:00 GMT"};
    NSError *error = nil;
    XCTAssertNil([_store readPlaceholderAtURL:file offset:0 length:64 error:&error]);
    XCTAssertEqual(error.code, VibeHTTPErrorVersionChanged);

    served.headers = @{@"ETag": @"\"v3\"", @"Last-Modified": kModified};
    error = nil;
    XCTAssertEqualObjects([_store readPlaceholderAtURL:file offset:0 length:64 error:&error],
                          [bytes subdataWithRange:NSMakeRange(0, 64)], @"%@", error);
}

#pragma mark Kept parts

- (void)keepPartOf:(NSURL *)file bytes:(NSData *)bytes version:(NSString *)version {
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:file];
    XCTAssertTrue([bytes writeToURL:part atomically:NO]);
    if (version) {
        setxattr(part.fileSystemRepresentation, kVersionAttribute, version.UTF8String, strlen(version.UTF8String), 0, 0);
    }
}

- (void)testAKeptPartResumesFromItsLength {
    NSData *bytes = FlacBytes(200000);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self keepPartOf:file bytes:[bytes subdataWithRange:NSMakeRange(0, 50000)] version:@"\"v1\""];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    NSArray<NSURLRequest *> *fetches = [self requestsTo:@"/a.flac" since:1];
    XCTAssertEqual(fetches.count, 1u);
    XCTAssertEqualObjects([fetches.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=50000-");
}

- (void)testAKeptPartLongerThanTheFileStartsOver {
    NSData *bytes = FlacBytes(50000);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self keepPartOf:file bytes:FlacBytes(100000) version:@"\"v1\""];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    NSArray<NSURLRequest *> *fetches = [self requestsTo:@"/a.flac" since:1];
    XCTAssertEqual(fetches.count, 2u);
    XCTAssertEqualObjects([fetches.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=100000-", @"a 416");
    XCTAssertNil([fetches.lastObject valueForHTTPHeaderField:@"Range"]);
}

- (void)testAKeptPartWithNoVersionIsReplaced {
    NSData *bytes = FlacBytes(200000);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    [self keepPartOf:file bytes:FlacBytes(50000) version:nil];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    NSArray<NSURLRequest *> *fetches = [self requestsTo:@"/a.flac" since:1];
    XCTAssertEqual(fetches.count, 1u);
    XCTAssertNil([fetches.firstObject valueForHTTPHeaderField:@"Range"]);
}

#pragma mark A server without ranges

- (void)testAServerWithoutRangesDownloadsWholeAndReadsNoTags {
    NSData *bytes = FlacBytes(1024 * 1024);
    HTTPStubFile *served = [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    served.ignoresRanges = YES;
    NSURL *file = [self resolvePath:@"/a.flac"];
    XCTAssertEqualObjects([self recordOf:file][@"ranges"], @NO);

    NSError *error = nil;
    XCTAssertNil([_store readPlaceholderAtURL:file offset:0 length:64 error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqual(_stub.requests.count, 1u, @"no ranged read");

    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    NSArray<NSURLRequest *> *fetches = [self requestsTo:@"/a.flac" since:1];
    XCTAssertEqual(fetches.count, 1u, @"no tail read");
    XCTAssertNil([fetches.firstObject valueForHTTPHeaderField:@"Range"]);
    XCTAssertTrue(IsDownloaded(file), @"the tags come from the file now");
}

#pragma mark The budget

- (void)testTheBudgetSendsTheOldestBackNeverTheNewest {
    _store.downloadBudget = 5000;
    [self settleDiskQueue];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSString *path in @[@"/a.flac", @"/b.flac", @"/c.flac"]) {
        [self serve:FlacBytes(3000) at:path headers:@{@"ETag": @"\"v1\""}];
        [files addObject:[self resolvePath:path]];
    }
    [self fetchExpectingSuccess:files[0]];
    [self fetchExpectingSuccess:files[1]];
    [self settleDiskQueue];
    XCTAssertTrue(IsPlaceholder(files[0]), @"the oldest went back");
    XCTAssertTrue(IsDownloaded(files[1]));

    _store.downloadBudget = 1000;
    [self settleDiskQueue];
    XCTAssertTrue(IsPlaceholder(files[1]));
    [self fetchExpectingSuccess:files[2]];
    [self settleDiskQueue];
    XCTAssertTrue(IsDownloaded(files[2]), @"the file just fetched stays, over the budget");
    XCTAssertEqual(StatOf(files[0]).st_size, 3000);
}

#pragma mark Pruning

- (void)testPruningDeletesOldLinksNothingKeeps {
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSString *path in @[@"/old.flac", @"/kept.flac", @"/recent.flac"]) {
        [self serve:FlacBytes(4000) at:path headers:@{@"ETag": @"\"v1\""}];
        [files addObject:[self resolvePath:path]];
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    [self setRecordOf:files[0] opened:now - 31 * kDay];
    [self setRecordOf:files[1] opened:now - 31 * kDay];
    [self setRecordOf:files[2] opened:now - 29 * kDay];
    NSURL *stray = [_root URLByAppendingPathComponent:@"0123456789abcdef" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:stray withIntermediateDirectories:NO attributes:nil error:NULL];

    // The kept file through the temp directory's other spelling.
    NSString *keptPath = files[1].path;
    if ([keptPath hasPrefix:@"/private/"]) {
        keptPath = [keptPath substringFromIndex:8];
    }
    [_store pruneKeepingURLs:[NSSet setWithObjects:[NSURL fileURLWithPath:keptPath],
                              [NSURL fileURLWithPath:@"/elsewhere/song.flac"], nil]];
    [self settleDiskQueue];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:files[0].URLByDeletingLastPathComponent.path]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:stray.path], @"no record: as old as can be");
    XCTAssertTrue(IsPlaceholder(files[1]));
    XCTAssertTrue(IsPlaceholder(files[2]));
    XCTAssertEqual([self linkDirectories].count, 2u);
    XCTAssertNil([self recordOf:files[0]], @"its cached record went with it");
}

#pragma mark The backend

// Another store's root, Dropbox's on iOS, keeps its own backend.
- (void)testTheBackendSitsBesideAnotherRoot {
    NSURL *other = [_base URLByAppendingPathComponent:@"Other" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:other withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *otherFile = [other URLByAppendingPathComponent:@"song.flac"];
    XCTAssertTrue(VibeWritePlaceholder(otherFile, 4000, kModifiedTime));
    __block _Atomic NSUInteger otherReads = 0;
    NSData *otherBytes = [@"OTHER" dataUsingEncoding:NSUTF8StringEncoding];
    [CloudFileMaterializer setRemoteRoot:other fetch:^BOOL(NSURL *url, dispatch_block_t onReadable,
                                                          void (^onCancel)(dispatch_block_t), NSError **error) {
        return NO;
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        atomic_fetch_add(&otherReads, 1);
        return otherBytes;
    } availability:nil];

    NSData *bytes = FlacBytes(4000);
    [self serve:bytes at:@"/a.flac" headers:@{@"ETag": @"\"v1\""}];
    NSURL *file = [self resolvePath:@"/a.flac"];
    XCTAssertFalse([NSURLUtil isDatalessFile:file], @"not installed yet");
    [_store installAsRemoteBackend];
    XCTAssertTrue([NSURLUtil isDatalessFile:file]);
    XCTAssertTrue([NSURLUtil isDatalessFile:otherFile]);

    NSError *error = nil;
    XCTAssertEqualObjects(CloudFileMaterializer.remoteRead(file, 16, 32, &error),
                          [bytes subdataWithRange:NSMakeRange(16, 32)]);
    XCTAssertEqual(atomic_load(&otherReads), 0u);
    XCTAssertEqualObjects(CloudFileMaterializer.remoteRead(otherFile, 0, 5, &error), otherBytes);
    XCTAssertEqual(atomic_load(&otherReads), 1u);

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    XCTestExpectation *returned = [self expectationWithDescription:@"materialized"];
    __block BOOL materialized = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        materialized = [materializer materializeURL:file token:token onReadable:nil error:NULL];
        [returned fulfill];
    });
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(materialized);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
}

@end
