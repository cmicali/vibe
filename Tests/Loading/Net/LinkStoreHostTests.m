//
//  LinkStoreHostTests.m
//
//  Each share host's link through the real LinkStore, over HTTPStub answering
//  that host, and links opened from the debug channel's fake web server. The
//  host rules' own tests are vibe-libs' (files/ShareLinks).
//

#import <XCTest/XCTest.h>

#include <stdatomic.h>

#import "ICloudLinkRules.h"
#import "ICloudLookupFixtures.h"
#import "LinkStoreTestCase.h"
#import "VibeFakeHTTP.h"

// A Dropbox link through the real LinkStore, over HTTPStub answering Dropbox's
// host.
@interface DropboxLinkStoreTests : LinkStoreTestCase
@end

@implementation DropboxLinkStoreTests

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

@end

// A Google Drive link through the real LinkStore, over HTTPStub answering
// Google's download host.
@interface GoogleDriveLinkStoreTests : LinkStoreTestCase
@end

@implementation GoogleDriveLinkStoreTests

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

@end

static NSString *const kChecksum = @"AQIDBAUGBwgJCgsMDQ4PEBESExQV";

@interface ICloudLinkStoreTests : LinkStoreTestCase
@end

static NSString *const kICloudLink = @"https://www.icloud.com/iclouddrive/0FakeShareID0000000000000#Song_One";
// The path the client posts its lookup to.
static NSString *LookupPath(void) {
    return [NSURL URLWithString:kVibeICloudLinkLookupURL].path;
}

// A version as the record keeps it: the checksum as a strong ETag.
static NSString *ETag(NSString *checksum) {
    return [NSString stringWithFormat:@"\"%@\"", checksum];
}
static NSString *const kOtherChecksum = @"AZaYl5aVlJOSkZCPjo2Mi4qJiIeG";

static NSData *JSONData(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}

// A lookup's answer naming `bytes` under `checksum`, its address signed with
// `signature` and valid for 15 minutes.
static NSData *LookupOf(NSData *bytes, NSString *checksum, NSString *signature) {
    long long expiry = (long long)NSDate.date.timeIntervalSince1970 + 900;
    return JSONData(ICloudLookup(checksum, (long long)bytes.length, @"Song One", @"flac",
                                 ICloudAddress(checksum, expiry, signature)));
}

// The path a checksum's file is served at, with the name iCloud's own
// address carries.
static NSString *ICloudPath(NSString *checksum) {
    return [NSString stringWithFormat:@"/B/%@/Song One.flac", checksum];
}

// iCloud's two hosts on the stub: the lookup, and the file at the address it
// names. cvws sends no ETag, Last-Modified when it signed the address, and
// the name in ${f} back as the file's.
@implementation ICloudLinkStoreTests

- (void)serveICloud:(NSData *)bytes checksum:(NSString *)checksum {
    [_stub answerHost:@"ckdatabasews.icloud.com"];
    [_stub answerHost:@"cvws.icloud-content.com"];
    [self serve:LookupOf(bytes, checksum, @"first") at:LookupPath()
        headers:@{@"Content-Type": @"application/json"}];
    [self serve:bytes at:ICloudPath(checksum) headers:@{
        @"Content-Type": @"audio/flac",
        @"Last-Modified": kModified,
        @"Content-Disposition": @"attachment; filename=\"Song%20One.flac\"; filename*=UTF-8''Song%20One.flac",
    }];
}

- (void)queueLookup:(NSData *)answer {
    [_stub queueStep:[HTTPStubStep status:200 headers:@{@"Content-Type": @"application/json"} body:answer]
             forPath:LookupPath()];
}

- (NSURL *)resolveICloud {
    NSError *error = nil;
    NSURL *file = [self resolve:kICloudLink error:&error];
    XCTAssertNotNil(file, @"%@", error);
    return file;
}

- (void)testAnICloudLinkIsLookedUpThenProbedThenStreamed {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    XCTAssertEqualObjects(file.lastPathComponent, @"Song One.flac", @"the lookup's name, by iCloud's echo");
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertEqual(StatOf(file).st_size, 200000);
    XCTAssertEqual(StatOf(file).st_mtimespec.tv_sec, kICloudModified, @"the record's mtime, not Last-Modified");

    NSDictionary *record = [self recordOf:file];
    XCTAssertEqualObjects(record[@"url"], kICloudLink, @"the share link, never the signed address");
    XCTAssertEqualObjects(record[@"version"], ETag(kChecksum));
    XCTAssertEqualObjects(record[@"modified"], @(kICloudModified));
    XCTAssertNil(record[@"lastModified"], @"when the address was signed");
    XCTAssertEqualObjects(record[@"host"], @"www.icloud.com");
    XCTAssertEqualObjects(record[@"ranges"], @YES);

    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 2u);
    XCTAssertEqualObjects(requests[0].URL.absoluteString, kVibeICloudLinkLookupURL);
    XCTAssertEqualObjects(requests[0].HTTPMethod, @"POST");
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Content-Type"], @"text/plain");
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Origin"], @"https://www.icloud.com");
    XCTAssertEqualObjects(requests[1].URL.host, @"cvws.icloud-content.com");
    XCTAssertEqualObjects(requests[1].URL.path, ICloudPath(kChecksum));
    XCTAssertTrue([requests[1].URL.query containsString:@"s=first"]);
    XCTAssertEqualObjects([requests[1] valueForHTTPHeaderField:@"Range"], @"bytes=0-15");

    NSError *error = nil;
    XCTAssertEqualObjects([_store readPlaceholderAtURL:file offset:1000 length:64 error:&error],
                          [bytes subdataWithRange:NSMakeRange(1000, 64)], @"a tag read: %@", error);
    NSString *key = file.cacheKey;
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqualObjects(file.cacheKey, key, @"the install keeps the record's mtime");
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 1u, @"every request reuses the probe's lookup");
}

- (void)testAnExpiredAddressIsLookedUpAgainAndResumes {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self queueLookup:LookupOf(bytes, kChecksum, @"second")];
    [self dropNextAnswerTo:ICloudPath(kChecksum) after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep status:410 headers:@{@"Content-Type": @"text/plain"}
                                      body:[@"Gone" dataUsingEncoding:NSUTF8StringEncoding]]
             forPath:ICloudPath(kChecksum)];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqualObjects([self recordOf:file][@"version"], ETag(kChecksum));

    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u, @"one lookup again");
    NSArray<NSURLRequest *> *fetches = [self requestsTo:ICloudPath(kChecksum) since:1];
    XCTAssertEqual(fetches.count, 3u, @"the download, the refused resend, and the resend");
    XCTAssertNil([fetches[0] valueForHTTPHeaderField:@"Range"]);
    XCTAssertEqualObjects([fetches[1] valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
    XCTAssertTrue([fetches[1].URL.query containsString:@"s=first"]);
    XCTAssertEqualObjects([fetches[2] valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
    XCTAssertTrue([fetches[2].URL.query containsString:@"s=second"], @"the fresh address");
}

- (void)testAnAddressRefusedAfterALookupAgainFails {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self queueLookup:LookupOf(bytes, kChecksum, @"second")];
    for (NSUInteger i = 0; i < 2; i++) {
        [_stub queueStep:[HTTPStubStep status:403 headers:nil body:nil] forPath:ICloudPath(kChecksum)];
    }
    NSError *error = nil;
    XCTAssertNil([_store readPlaceholderAtURL:file offset:0 length:64 error:&error]);
    XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], @403, @"%@", error);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u, @"looked up again once, not twice");
}

- (void)testAnotherChecksumMidDownloadFails {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    NSData *changed = FlacBytes(210000);
    [self serve:changed at:ICloudPath(kOtherChecksum) headers:@{@"Content-Type": @"audio/flac"}];
    [self queueLookup:LookupOf(changed, kOtherChecksum, @"second")];
    [self dropNextAnswerTo:ICloudPath(kChecksum) after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep status:410 headers:nil body:nil] forPath:ICloudPath(kChecksum)];
    NSError *error = nil;
    XCTAssertFalse([self fetch:file error:&error]);
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorVersionChanged);
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[PlaceholderFiles remotePlaceholderPartURL:file].path]);
}

// A relaunch looks the share up afresh. Its address and Last-Modified are
// new, but the checksum is the same, so the download is kept.
- (void)testAKeptDownloadSurvivesARelaunchsFreshLookup {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self fetchExpectingSuccess:file];
    NSString *key = file.cacheKey;
    ino_t inode = StatOf(file).st_ino;

    [self relaunch];
    [self queueLookup:LookupOf(bytes, kChecksum, @"second")];
    [_stub queueStep:[HTTPStubStep changeHeaders:@{@"Last-Modified": @"Thu, 22 Oct 2015 07:28:00 GMT"}]
             forPath:ICloudPath(kChecksum)];
    NSUInteger fetched = [_stub requestsToPath:ICloudPath(kChecksum)].count;
    XCTAssertEqualObjects([self resolveICloud], file);
    XCTAssertTrue(IsDownloaded(file));
    XCTAssertEqual(StatOf(file).st_ino, inode);
    XCTAssertEqualObjects(file.cacheKey, key);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u);
    NSArray<NSURLRequest *> *sent = [self requestsTo:ICloudPath(kChecksum) since:fetched];
    XCTAssertEqual(sent.count, 1u, @"the probe alone");
    XCTAssertEqualObjects([sent.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=0-15");
}

- (void)testAnotherChecksumOnAFreshLookupIsAnotherVersion {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self fetchExpectingSuccess:file];

    // The same size and mtime: only the checksum tells.
    NSMutableData *changed = [FlacBytes(200000) mutableCopy];
    ((uint8_t *)changed.mutableBytes)[100] ^= 0xFF;
    [self serve:changed at:ICloudPath(kOtherChecksum) headers:@{@"Content-Type": @"audio/flac"}];
    [self relaunch];
    [self queueLookup:LookupOf(changed, kOtherChecksum, @"second")];
    XCTAssertEqualObjects([self resolveICloud], file);
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertEqualObjects([self recordOf:file][@"version"], ETag(kOtherChecksum));
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], changed);
}

- (void)testConcurrentRequestsShareOneLookup {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self relaunch];
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:1 gate:gate] forPath:LookupPath()];
    dispatch_group_t reads = dispatch_group_create();
    __block atomic_int read = 0;
    LinkStore *store = _store;
    for (NSUInteger i = 0; i < 4; i++) {
        dispatch_group_async(reads, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *data = [store readPlaceholderAtURL:file offset:i * 100 length:100 error:NULL];
            if ([data isEqualToData:[bytes subdataWithRange:NSMakeRange(i * 100, 100)]]) {
                atomic_fetch_add(&read, 1);
            }
        });
    }
    [self waitUntil:^BOOL {
        return [self->_stub requestsToPath:LookupPath()].count == 2;
    }];
    usleep(50000);
    dispatch_semaphore_signal(gate);
    XCTAssertEqual(dispatch_group_wait(reads, dispatch_time(DISPATCH_TIME_NOW,
                                                            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    XCTAssertEqual(atomic_load(&read), 4);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u, @"the resolve's, then one for all four reads");
}

- (void)testAShareForInvitedPeopleSendsNothingToTheFile {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSMutableDictionary *invited = ICloudLookup(kChecksum, 4000, @"Song One", @"flac",
                                                ICloudAddress(kChecksum, 0, @"x"));
    ICloudResult(invited)[@"requireAppleLogin"] = @YES;
    [self queueLookup:JSONData(invited)];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorICloudPrivate);
    XCTAssertEqual(_stub.requests.count, 1u, @"the lookup alone");
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

- (void)testAFolderShareIsRefused {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSMutableDictionary *folder = ICloudLookup(kChecksum, 4000, @"Songs", @"",
                                               ICloudAddress(kChecksum, 0, @"x"));
    ICloudResult(folder)[@"rootRecord"][@"recordType"] = @"folder";
    [self queueLookup:JSONData(folder)];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorICloudFolder);
    XCTAssertEqual(_stub.requests.count, 1u);
}

- (void)testAGoneShareAndAnUnreadableAnswerFailClearly {
    [self serveICloud:FlacBytes(4000) checksum:kChecksum];
    [self queueLookup:JSONData(@{@"results": @[@{@"serverErrorCode": @"NOT_FOUND", @"requireAppleLogin": @NO}]})];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorNotFound);
    [self queueLookup:[@"<html>" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorICloudUnreadable);
    [_stub queueStep:[HTTPStubStep status:500 headers:nil body:nil] forPath:LookupPath()];
    NSError *error = nil;
    XCTAssertNil([self resolve:kICloudLink error:&error]);
    XCTAssertEqual(error.code, VibeLinkErrorServer);
    XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], @500);
    XCTAssertEqual([_stub requestsToPath:ICloudPath(kChecksum)].count, 0u);
}

- (void)failNextLookups:(NSUInteger)count code:(NSInteger)code {
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
    for (NSUInteger i = 0; i < count; i++) {
        [_stub queueStep:[HTTPStubStep failWithError:error] forPath:LookupPath()];
    }
}

// Offline, a downloaded share still opens. The lookup is what fails, once
// its two resends have failed too.
- (void)testAnUnreachableLookupOpensTheDownload {
    [self serveICloud:FlacBytes(4000) checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self fetchExpectingSuccess:file];
    [self relaunch];
    [self failNextLookups:3 code:NSURLErrorNotConnectedToInternet];
    XCTAssertEqualObjects([self resolveICloud], file);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 4u, @"the first open's, then three");

    [self relaunch];
    [self failNextLookups:3 code:NSURLErrorNotConnectedToInternet];
    [NSFileManager.defaultManager removeItemAtURL:_root error:NULL];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorUnreachable);
}

// A dropped connection and a throttle are sent again, as a request's are.
// A download's resend waiting on its lookup then goes on.
- (void)testALookupThatDropsOrIsThrottledIsSentAgain {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    [self failNextLookups:2 code:NSURLErrorNetworkConnectionLost];
    NSURL *file = [self resolveICloud];
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 3u);

    // The download's resend after a drop needs a lookup again, which is
    // throttled, then answered.
    [self relaunch];
    [self queueLookup:LookupOf(bytes, kChecksum, @"first")];
    [_stub queueStep:[HTTPStubStep status:503 headers:@{@"Retry-After": @"1"} body:nil] forPath:LookupPath()];
    NSUInteger lookups = [_stub requestsToPath:LookupPath()].count;
    [self dropNextAnswerTo:ICloudPath(kChecksum) after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep status:410 headers:nil body:nil] forPath:ICloudPath(kChecksum)];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, lookups + 3, @"the first, the throttled, and its resend");
}

- (void)testALookupFromReplacedSessionsIsNotKept {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self relaunch];
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:1 gate:gate] forPath:LookupPath()];
    LinkStore *store = _store;
    __block NSData *read = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"read"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        read = [store readPlaceholderAtURL:file offset:0 length:64 error:NULL];
        [done fulfill];
    });
    [self waitUntil:^BOOL {
        return [self->_stub requestsToPath:LookupPath()].count == 2;
    }];
    [_client useSessionConfiguration:_stub.configuration];
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(read, [bytes subdataWithRange:NSMakeRange(0, 64)], @"its waiter still has it");

    XCTAssertNotNil([_store readPlaceholderAtURL:file offset:64 length:64 error:NULL]);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 3u, @"the next request looks up again");
}

@end

// Links opened from the debug channel's fake web server, through the real
// LinkStore. The fake's state is process-wide, so only this class drives it
// here.
@interface LinkStoreFakeHTTPTests : XCTestCase
@end

@implementation LinkStoreFakeHTTPTests {
    LinkClient *_client;
    NSURL *_base;
    NSURL *_served;
    time_t _songModified;
}

static const NSUInteger kSongBytes = 512 * 1024;

- (void)setUp {
    [super setUp];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"LinkStoreFakeHTTPTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _base = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    _served = [_base URLByAppendingPathComponent:@"served" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:[_served URLByAppendingPathComponent:@"album"]
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableData *song = [PatternBytes(kSongBytes) mutableCopy];
    memcpy(song.mutableBytes, "ID3\x04\x00", 5);
    NSURL *songURL = [_served URLByAppendingPathComponent:@"album/song.mp3"];
    [song writeToURL:songURL atomically:NO];
    _songModified = 1445412480;
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:
                                                      [NSDate dateWithTimeIntervalSince1970:_songModified]}
                                   ofItemAtPath:songURL.path error:NULL];
    NSMutableData *flac = [PatternBytes(4096) mutableCopy];
    memcpy(flac.mutableBytes, "fLaC", 4);
    [flac writeToURL:[_served URLByAppendingPathComponent:@"tone.flac"] atomically:NO];

    _client = [[LinkClient alloc] initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    _client.retryDelayScale = 0.01;
    [VibeFakeHTTP installWithDirectory:_served transferSeconds:0 client:_client];
}

- (void)tearDown {
    [VibeFakeHTTP clearFaults];
    [VibeFakeHTTP uninstallFromClient:_client];
    [NSFileManager.defaultManager removeItemAtURL:_base error:NULL];
    [super tearDown];
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

- (void)testAnICloudLinkOpensFromTheFake {
    LinkStore *store = [[LinkStore alloc] initWithClient:_client rootURL:[_base URLByAppendingPathComponent:@"Links"]];
    NSError *error = nil;
    NSURL *file = [self resolve:store link:@"https://www.icloud.com/iclouddrive/tone#Tone" error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertEqualObjects(file.lastPathComponent, @"tone.flac");
    NSArray<NSDictionary *> *log = self.log;
    XCTAssertEqual(log.count, 2u);
    XCTAssertEqualObjects(log[0][@"host"], @"ckdatabasews.icloud.com");
    XCTAssertEqualObjects(log[1][@"host"], @"cvws.icloud-content.com");
    XCTAssertEqualObjects(log[1][@"range"], @"bytes=0-15");
    NSDictionary *record = [store indexOfDirectory:file.URLByDeletingLastPathComponent];
    XCTAssertNotNil(record[@"version"]);

    XCTAssertTrue([store fetchPlaceholderAtURL:file onReadable:nil onCancel:^(dispatch_block_t cancel) {
    } error:&error], @"%@", error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file],
                          [NSData dataWithContentsOfURL:[_served URLByAppendingPathComponent:@"tone.flac"]]);
}

- (void)testAnExpiredAddressIsLookedUpAgain {
    LinkStore *store = [[LinkStore alloc] initWithClient:_client rootURL:[_base URLByAppendingPathComponent:@"Links"]];
    XCTAssertTrue([VibeFakeHTTP addFaultOfKind:@"expiry" file:nil after:0 seconds:0 rate:0 status:0 once:@YES]);
    NSError *error = nil;
    XCTAssertNotNil([self resolve:store link:@"https://www.icloud.com/iclouddrive/tone" error:&error], @"%@", error);
    NSArray<NSDictionary *> *log = self.log;
    XCTAssertEqual(log.count, 4u);
    XCTAssertEqualObjects(log[0][@"faults"], @[@"expiry"]);
    XCTAssertEqualObjects(log[1][@"status"], @410);
    XCTAssertEqualObjects(log[2][@"host"], @"ckdatabasews.icloud.com");
    XCTAssertEqualObjects(log[3][@"status"], @206);
}

- (void)testAnICloudFolderOrMissingShareIsRefused {
    LinkStore *store = [[LinkStore alloc] initWithClient:_client rootURL:[_base URLByAppendingPathComponent:@"Links"]];
    NSError *error = nil;
    XCTAssertNil([self resolve:store link:@"https://www.icloud.com/iclouddrive/album" error:&error]);
    XCTAssertEqual(error.code, VibeLinkErrorICloudFolder);
    XCTAssertNil([self resolve:store link:@"https://www.icloud.com/iclouddrive/nothing" error:&error]);
    XCTAssertEqual(error.code, VibeLinkErrorNotFound);
    XCTAssertEqual([VibeFakeHTTP.statistics[@"requests"] integerValue], 2, @"two lookups, and no file asked for");
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
