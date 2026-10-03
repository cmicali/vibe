//
//  DropboxMirrorTests.m
//
//  The real client and mirror over a stubbed HTTP boundary (an NSURLProtocol
//  in the session's configuration) and a per-test temp root: listing
//  reconciliation, the placeholder-to-bytes fetch through
//  CloudFileMaterializer, its cancellation, a download resumed in place, the
//  fetch's part file read while it streams, the token refresh and the unlink.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/time.h>

#import "AudioFileHandle.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileOpenRules.h"
#import "AudioFixtures.h"
#import "CloudFileMaterializer.h"
#import "CloudTransferRegistry.h"
#import "DropboxClientInternal.h"
#import "DropboxMirror.h"
#import "DropboxRules.h"
#import "NSURLUtil.h"

#pragma mark - The stub

// A response: status, headers, body; or hang until the task is cancelled; or
// answer only once `gate` is signalled, without holding the loader thread,
// so other requests are answered meanwhile. A failure ends the load after
// the body, a dropped connection, once failWhen answers YES; with status 0 it
// comes before any response. With a chunk length the body goes out in
// chunks, beforeChunk asked off the loading thread ahead of each, so a test
// can hold the next one back; beforeResponse, asked the same way, holds
// the response itself.
typedef struct {
    NSInteger status;
    NSDictionary<NSString *, NSString *> *_Nullable headers;
    NSData *_Nullable body;
    BOOL hang;
    dispatch_semaphore_t _Nullable gate;
    NSError *_Nullable failure;
    BOOL (^_Nullable failWhen)(void);
    NSUInteger chunk;
    void (^_Nullable beforeChunk)(NSUInteger index);
    dispatch_block_t _Nullable beforeResponse;
} DropboxStubResponse;

typedef DropboxStubResponse (^DropboxStubHandler)(NSURLRequest *request, NSDictionary *_Nullable json);

static os_unfair_lock sStubLock = OS_UNFAIR_LOCK_INIT;
static DropboxStubHandler sStubHandler;
static NSMutableArray<NSURLRequest *> *sStubRequests;

static DropboxStubResponse DropboxStubJSON(NSInteger status, id object) {
    return (DropboxStubResponse){status, @{@"Content-Type": @"application/json"},
            [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL], NO};
}

// The loading thread's run loop may next turn in either mode.
static NSArray<NSString *> *DropboxStubModes(void) {
    NSMutableArray<NSString *> *modes = [NSMutableArray arrayWithObject:NSDefaultRunLoopMode];
    NSString *mode = NSRunLoop.currentRunLoop.currentMode;
    if (mode && ![mode isEqualToString:NSDefaultRunLoopMode]) {
        [modes addObject:mode];
    }
    return modes;
}

@interface DropboxStubProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@end

@implementation DropboxStubProtocol {
    DropboxStubResponse _gated;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

static NSData *DropboxStubBody(NSURLRequest *request) {
    if (request.HTTPBody) {
        return request.HTTPBody;
    }
    NSInputStream *stream = request.HTTPBodyStream;
    if (!stream) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    [stream open];
    uint8_t buffer[4096];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof buffer]) > 0) {
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    [stream close];
    return data;
}

- (void)startLoading {
    NSData *body = DropboxStubBody(self.request);
    id json = body ? [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingFragmentsAllowed error:NULL] : nil;
    os_unfair_lock_lock(&sStubLock);
    DropboxStubHandler handler = sStubHandler;
    if (handler) {
        [sStubRequests addObject:self.request];
    }
    os_unfair_lock_unlock(&sStubLock);
    if (!handler) {
        // Between tests: a request an ended test's client sent late is left unanswered.
        return;
    }
    DropboxStubResponse response = handler(self.request, [json isKindOfClass:NSDictionary.class] ? json : nil);
    if (response.hang) {
        return;
    }
    if (response.gate) {
        // Delivered on this thread, the client's, once the gate opens.
        _gated = response;
        NSThread *loader = NSThread.currentThread;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dispatch_semaphore_wait(response.gate, dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)));
            [self performSelector:@selector(deliverGated) onThread:loader withObject:nil waitUntilDone:NO];
        });
        return;
    }
    [self deliver:response];
}

- (void)deliverGated {
    [self deliver:_gated];
}

- (void)deliver:(DropboxStubResponse)response {
    if (response.beforeResponse) {
        NSThread *thread = NSThread.currentThread;
        NSArray<NSString *> *modes = DropboxStubModes();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            response.beforeResponse();
            dispatch_block_t respond = ^{
                [self respond:response];
            };
            [self performSelector:@selector(runUnlessStopped:) onThread:thread withObject:respond
                    waitUntilDone:NO modes:modes];
        });
        return;
    }
    [self respond:response];
}

- (void)runUnlessStopped:(dispatch_block_t)block {
    if (!self.stopped) {
        block();
    }
}

- (void)respond:(DropboxStubResponse)response {
    if (response.status == 0 && response.failure) {
        [self.client URLProtocol:self didFailWithError:response.failure];
        return;
    }
    NSHTTPURLResponse *http = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                          statusCode:response.status
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:response.headers];
    [self.client URLProtocol:self didReceiveResponse:http cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (response.body && response.chunk > 0) {
        NSThread *thread = NSThread.currentThread;
        NSArray<NSString *> *modes = DropboxStubModes();
        NSData *body = response.body;
        NSUInteger chunk = response.chunk;
        void (^beforeChunk)(NSUInteger) = response.beforeChunk;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (NSUInteger start = 0, index = 0; start < body.length && !self.stopped; start += chunk, index++) {
                if (beforeChunk) {
                    beforeChunk(index);
                }
                NSData *slice = [body subdataWithRange:NSMakeRange(start, MIN(chunk, body.length - start))];
                [self performSelector:@selector(deliverData:) onThread:thread withObject:slice
                        waitUntilDone:NO modes:modes];
            }
            [self performSelector:@selector(finishLoading) onThread:thread withObject:nil
                    waitUntilDone:NO modes:modes];
        });
        return;
    }
    if (response.body) {
        [self.client URLProtocol:self didLoadData:response.body];
    }
    if (response.failure) {
        // TRAP: a failure reported straight after the body overtakes it, and
        // the delegate never sees those bytes, so it waits until the client
        // has written them, then goes on the thread that started the load.
        NSThread *thread = NSThread.currentThread;
        NSArray<NSString *> *modes = DropboxStubModes();
        BOOL (^ready)(void) = response.failWhen;
        NSError *failure = response.failure;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_GATE_TIMEOUT];
            while (ready && !ready() && deadline.timeIntervalSinceNow > 0) {
                usleep(1000);
            }
            [self performSelector:@selector(failLoading:) onThread:thread withObject:failure
                    waitUntilDone:NO modes:modes];
        });
        return;
    }
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)failLoading:(NSError *)failure {
    [self.client URLProtocol:self didFailWithError:failure];
}

- (void)deliverData:(NSData *)data {
    if (!self.stopped) {
        [self.client URLProtocol:self didLoadData:data];
    }
}

- (void)finishLoading {
    if (!self.stopped) {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (void)stopLoading {
    self.stopped = YES;
}

@end

#pragma mark - Tests

static NSString *const kStamp = @"2020-01-02T03:04:05Z";
static const time_t kStampSeconds = 1577934245;
static NSString *const kRev = @"015c0ffee";
// DropboxMirror's kStreamReadableBytes.
static const uint64_t kReadableBytes = 256 * 1024;

// files/download as Dropbox answers it: the whole file, or 206 from a Range's
// first byte, with the version's metadata either way.
static DropboxStubResponse DownloadAnswer(NSURLRequest *request, NSData *bytes, NSDictionary *metadata) {
    NSString *result = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metadata
                                                                                      options:0 error:NULL]
                                             encoding:NSUTF8StringEncoding];
    // TRAP: with no Content-Type the session sniffs the first 512 bytes
    // before it hands the delegate a response, so a shorter body cut off by
    // a failure never reaches it. Dropbox names its type.
    NSDictionary *headers = @{@"Dropbox-API-Result": result, @"Content-Type": @"application/octet-stream"};
    NSString *range = [request valueForHTTPHeaderField:@"Range"];
    if (!range) {
        return (DropboxStubResponse){200, headers, bytes, NO};
    }
    unsigned long long first = 0, last = ULLONG_MAX;
    sscanf(range.UTF8String, "bytes=%llu-%llu", &first, &last);
    last = MIN(last, (unsigned long long)bytes.length - 1);
    NSData *slice = [bytes subdataWithRange:NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1))];
    return (DropboxStubResponse){206, headers, slice, NO};
}

// The answer to `request` cut off after `delivered` bytes by a dropped
// connection, once `part` holds them.
static DropboxStubResponse Dropped(DropboxStubResponse answer, NSURLRequest *request, NSUInteger delivered,
                                   NSURL *part) {
    unsigned long long first = 0;
    sscanf([request valueForHTTPHeaderField:@"Range"].UTF8String ?: "", "bytes=%llu-", &first);
    off_t written = (off_t)(first + delivered);
    answer.body = [answer.body subdataWithRange:NSMakeRange(0, delivered)];
    answer.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil];
    answer.failWhen = ^BOOL {
        struct stat st;
        return stat(part.fileSystemRepresentation, &st) == 0 && st.st_size >= written;
    };
    return answer;
}

static NSDictionary *FileEntry(NSString *folder, NSString *name, long long size, NSString *modified) {
    NSString *path = [folder stringByAppendingPathComponent:name];
    return @{@".tag": @"file", @"name": name, @"path_display": path, @"id": [@"id:" stringByAppendingString:path.lowercaseString],
             @"path_lower": path.lowercaseString, @"size": @(size), @"server_modified": modified};
}

static NSDictionary *FolderEntry(NSString *folder, NSString *name) {
    NSString *path = [folder stringByAppendingPathComponent:name];
    return @{@".tag": @"folder", @"name": name, @"path_display": path, @"id": [@"id:" stringByAppendingString:path.lowercaseString],
             @"path_lower": path.lowercaseString};
}

// Every availability's notes and finish pass through these while they are
// set, so a test sees each as the mirror makes it, before it lands.
static os_unfair_lock sObserverLock = OS_UNFAIR_LOCK_INIT;
static void (^sNoteObserver)(CloudFileAvailability *availability, uint64_t bytes);
static void (^sFinishObserver)(CloudFileAvailability *availability, NSError *error);
static IMP sNoteIMP;
static IMP sFinishIMP;

static void ObservedNote(id availability, SEL selector, uint64_t bytes) {
    os_unfair_lock_lock(&sObserverLock);
    void (^observer)(CloudFileAvailability *, uint64_t) = sNoteObserver;
    os_unfair_lock_unlock(&sObserverLock);
    if (observer) {
        observer(availability, bytes);
    }
    ((void (*)(id, SEL, uint64_t))sNoteIMP)(availability, selector, bytes);
}

static void ObservedFinish(id availability, SEL selector, NSError *error) {
    os_unfair_lock_lock(&sObserverLock);
    void (^observer)(CloudFileAvailability *, NSError *) = sFinishObserver;
    os_unfair_lock_unlock(&sObserverLock);
    if (observer) {
        observer(availability, error);
    }
    ((void (*)(id, SEL, NSError *))sFinishIMP)(availability, selector, error);
}

static void ObserveAvailabilities(void (^_Nullable note)(CloudFileAvailability *, uint64_t),
                                  void (^_Nullable finish)(CloudFileAvailability *, NSError *)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = CloudFileAvailability.class;
        sNoteIMP = method_setImplementation(class_getInstanceMethod(cls, @selector(noteWrittenBytes:)),
                                            (IMP)ObservedNote);
        sFinishIMP = method_setImplementation(class_getInstanceMethod(cls, @selector(finishWithError:)),
                                              (IMP)ObservedFinish);
    });
    os_unfair_lock_lock(&sObserverLock);
    sNoteObserver = [note copy];
    sFinishObserver = [finish copy];
    os_unfair_lock_unlock(&sObserverLock);
}

// Interleaved float32 from the cursor to the end; nil when a read answers NO.
static NSData *DecodeAll(AudioFileHandle *handle, NSError **error) {
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:handle.processingFormat frameCapacity:4096];
    NSMutableData *pcm = [NSMutableData data];
    for (;;) {
        if (![handle readIntoBuffer:buffer frameCount:4096 error:error]) {
            return nil;
        }
        if (buffer.frameLength == 0) {
            return pcm;
        }
        VibeAppendPCM(pcm, buffer);
    }
}

@interface DropboxMirrorTests : XCTestCase <CloudTransferRegistryObserver>
@end

@implementation DropboxMirrorTests {
    NSURL *_root;
    DropboxClient *_client;
    DropboxMirror *_mirror;
    // Path → entries the stub's list_folder answers.
    NSMutableDictionary<NSString *, NSArray *> *_listings;
    // Dropbox path → bytes the stub's files/download answers.
    NSMutableDictionary<NSString *, NSData *> *_contents;
    // Under scriptDownloads:, what answers a closed range (a tail or a tag
    // read beside the downloads); nil answers it as default.
    DropboxStubResponse (^_rangeScript)(NSURLRequest *request);
    NSInteger _tokenRequests;
    // What the stub's files/search_v2 answers.
    NSArray<NSDictionary *> *_searchEntries;
    // Streaming: each held chunk waits on the gate; the observed notes and
    // finishes; the fetch's track and its outcome.
    dispatch_semaphore_t _chunkGate;
    dispatch_semaphore_t _noteSignal;
    NSMutableArray<NSArray *> *_notes;
    NSMutableArray<NSDictionary *> *_finishes;
    NSURL *_streamTrack;
    BOOL _fetched;
    NSError *_fetchError;
    // The row's loading bar: the open, and the movements observed.
    AudioFileMaterializationCoordinator *_coordinator;
    AudioFileOpenToken *_openToken;
    AudioFileHandle *_delivered;
    NSMutableArray<NSString *> *_moves;
}

- (void)setUp {
    [super setUp];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"DropboxMirrorTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES
                                             attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _root = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    _listings = [NSMutableDictionary dictionary];
    _contents = [NSMutableDictionary dictionary];
    _chunkGate = dispatch_semaphore_create(0);
    _noteSignal = dispatch_semaphore_create(0);

    os_unfair_lock_lock(&sStubLock);
    sStubRequests = [NSMutableArray array];
    os_unfair_lock_unlock(&sStubLock);
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        return [self defaultResponseFor:request json:json];
    }];

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[DropboxStubProtocol.class];
    _client = [[DropboxClient alloc] initWithAppKey:@"testkey" keychainService:nil
                                      configuration:configuration];
    _client.retryDelayScale = 0.01;
    _mirror = [[DropboxMirror alloc] initWithClient:_client rootURL:_root downloadBudget:8];
    [_client adoptRefreshToken:@"R1" accountID:@"dbid:test"];
}

- (void)tearDown {
    os_unfair_lock_lock(&sObserverLock);
    sNoteObserver = nil;
    sFinishObserver = nil;
    os_unfair_lock_unlock(&sObserverLock);
    // A held chunk's stub, cancelled under it, goes on to find its load stopped.
    [self releaseChunks:1000];
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    [self installHandler:nil];
    // Let the adopt's posted notification land before the root goes.
    [self spinMainQueue];
    [NSFileManager.defaultManager removeItemAtURL:_root error:NULL];
    [super tearDown];
}

- (void)spinMainQueue {
    XCTestExpectation *spun = [self expectationWithDescription:@"main"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [spun fulfill];
    });
    [self waitForExpectations:@[spun] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)installHandler:(DropboxStubHandler)handler {
    os_unfair_lock_lock(&sStubLock);
    sStubHandler = [handler copy];
    os_unfair_lock_unlock(&sStubLock);
}

- (void)clearRequests {
    os_unfair_lock_lock(&sStubLock);
    [sStubRequests removeAllObjects];
    os_unfair_lock_unlock(&sStubLock);
}

- (NSArray<NSURLRequest *> *)requestsToPath:(NSString *)path {
    os_unfair_lock_lock(&sStubLock);
    NSArray<NSURLRequest *> *requests = [sStubRequests copy];
    os_unfair_lock_unlock(&sStubLock);
    return [requests filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        return [request.URL.path isEqualToString:path];
    }]];
}

- (DropboxStubResponse)defaultResponseFor:(NSURLRequest *)request json:(NSDictionary *)json {
    NSString *path = request.URL.path;
    if ([path isEqualToString:@"/oauth2/token"]) {
        @synchronized (self) {
            _tokenRequests++;
            return DropboxStubJSON(200, @{@"access_token": [NSString stringWithFormat:@"A%ld", (long)_tokenRequests],
                                         @"expires_in": @14400});
        }
    }
    if ([path isEqualToString:@"/2/files/list_folder"]) {
        NSArray *entries = _listings[[json[@"path"] lowercaseString]];
        if (!entries) {
            return DropboxStubJSON(409, @{@"error_summary": @"path/not_found/"});
        }
        return DropboxStubJSON(200, @{@"entries": entries, @"cursor": @"c", @"has_more": @NO});
    }
    if ([path isEqualToString:@"/2/files/search_v2"]) {
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *entry in _searchEntries ?: @[]) {
            [matches addObject:@{@"metadata": @{@".tag": @"metadata", @"metadata": entry}}];
        }
        return DropboxStubJSON(200, @{@"matches": matches, @"has_more": @NO});
    }
    if ([path isEqualToString:@"/2/files/download"]) {
        NSString *argument = [request valueForHTTPHeaderField:@"Dropbox-API-Arg"];
        NSDictionary *arg = [NSJSONSerialization JSONObjectWithData:[argument dataUsingEncoding:NSASCIIStringEncoding]
                                                            options:0 error:NULL];
        NSString *requested = arg[@"path"];
        if ([requested hasPrefix:@"id:"]) {
            requested = [requested substringFromIndex:3];
        }
        NSData *bytes = _contents[requested.lowercaseString];
        if (!bytes) {
            return DropboxStubJSON(409, @{@"error_summary": @"path/not_found/"});
        }
        return DownloadAnswer(request, bytes, @{@"server_modified": kStamp, @"size": @(bytes.length), @"rev": kRev});
    }
    return DropboxStubJSON(400, @{@"error_summary": @"unexpected"});
}

- (NSURL *)refresh:(NSString *)path {
    XCTestExpectation *done = [self expectationWithDescription:path];
    __block NSURL *folder = nil;
    [_mirror refreshDropboxFolder:path completion:^(NSURL *folderURL, NSError *error) {
        XCTAssertNil(error);
        folder = folderURL;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    return folder;
}

static struct stat StatOf(NSURL *url) {
    struct stat st = {0};
    lstat(url.fileSystemRepresentation, &st);
    return st;
}

#pragma mark Listing

- (void)testAListingWritesPlaceholdersFetchesSheetsAndSkipsTheRest {
    NSData *sheet = [@"FILE \"01 Song.flac\" WAVE\n" dataUsingEncoding:NSUTF8StringEncoding];
    _listings[@"/music/album"] = @[
        FileEntry(@"/Music/Album", @"01 Song.flac", 123456, kStamp),
        FileEntry(@"/Music/Album", @"cover.jpg", 5000, kStamp),
        FileEntry(@"/Music/Album", @"Album.cue", (long long)sheet.length, kStamp),
        FolderEntry(@"/Music/Album", @"Disc 2"),
    ];
    _contents[@"/music/album/album.cue"] = sheet;

    NSURL *folder = [self refresh:@"/Music/Album"];
    XCTAssertEqualObjects(folder.lastPathComponent, @"Album");
    XCTAssertEqualObjects([_mirror dropboxPathForURL:folder], @"/Music/Album");

    struct stat track = StatOf([folder URLByAppendingPathComponent:@"01 Song.flac"]);
    XCTAssertTrue(S_ISREG(track.st_mode));
    XCTAssertEqual(track.st_mode & 0777, 0);
    XCTAssertEqual(track.st_size, 123456);
    XCTAssertEqual(track.st_mtimespec.tv_sec, kStampSeconds);

    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"Album.cue"]], sheet);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[folder URLByAppendingPathComponent:@"cover.jpg"].path]);
    BOOL isDirectory = NO;
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[folder URLByAppendingPathComponent:@"Disc 2"].path
                                                     isDirectory:&isDirectory]);
    XCTAssertTrue(isDirectory);

    [NSURLUtil setRemotePlaceholderRoot:_root];
    XCTAssertTrue([NSURLUtil isDatalessFile:[folder URLByAppendingPathComponent:@"01 Song.flac"]]);
    XCTAssertFalse([NSURLUtil isDatalessFile:[folder URLByAppendingPathComponent:@"Album.cue"]]);
    [NSURLUtil setRemotePlaceholderRoot:nil];
}

// Two refreshes of one folder share a sheet's part file, so they share one
// download: a second would unlink the first's bytes mid-transfer and the
// first to finish would install the other's half.
- (void)testTwoRefreshesOfOneFolderFetchItsSheetOnce {
    NSData *sheet = [@"FILE \"01 Song.flac\" WAVE\n" dataUsingEncoding:NSUTF8StringEncoding];
    _listings[@"/music/album"] = @[
        FileEntry(@"/Music/Album", @"01 Song.flac", 123456, kStamp),
        FileEntry(@"/Music/Album", @"Album.cue", (long long)sheet.length, kStamp),
    ];
    _contents[@"/music/album/album.cue"] = sheet;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        DropboxStubResponse response = [self defaultResponseFor:request json:json];
        if ([request.URL.path isEqualToString:@"/2/files/download"]) {
            response.gate = gate;
        }
        return response;
    }];

    XCTestExpectation *both = [self expectationWithDescription:@"both refreshes"];
    both.expectedFulfillmentCount = 2;
    __block NSURL *folder = nil;
    void (^refreshed)(NSURL *, NSError *) = ^(NSURL *folderURL, NSError *error) {
        XCTAssertNil(error);
        folder = folderURL;
        [both fulfill];
    };
    [_mirror refreshDropboxFolder:@"/Music/Album" completion:refreshed];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:@"/2/files/download"].count == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    // The first download is held; the second refresh lists and reconciles
    // under it. The short wait is the negative check's: time for a second
    // download to have been asked for, had one been coming.
    [_mirror refreshDropboxFolder:@"/Music/Album" completion:refreshed];
    while ([self requestsToPath:@"/2/files/list_folder"].count < 2 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    dispatch_semaphore_signal(gate);
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[both] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 1u);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"Album.cue"]], sheet);
}

- (void)testARefreshKeepsCurrentBytesRewritesChangedFilesAndDropsDeparted {
    _listings[@"/a"] = @[FileEntry(@"/A", @"kept.flac", 5, kStamp),
                         FileEntry(@"/A", @"changed.flac", 10, kStamp),
                         FileEntry(@"/A", @"gone.flac", 10, kStamp)];
    NSURL *folder = [self refresh:@"/A"];

    // kept.flac as a finished download of the listed version.
    NSURL *kept = [folder URLByAppendingPathComponent:@"kept.flac"];
    [NSFileManager.defaultManager removeItemAtURL:kept error:NULL];
    [[@"HELLO" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:kept atomically:NO];
    struct timeval times[2] = {{kStampSeconds, 0}, {kStampSeconds, 0}};
    utimes(kept.fileSystemRepresentation, times);

    _listings[@"/a"] = @[FileEntry(@"/A", @"kept.flac", 5, kStamp),
                         FileEntry(@"/A", @"changed.flac", 20, @"2021-01-01T00:00:00Z"),
                         FileEntry(@"/A", @"new.flac", 30, kStamp)];
    [self refresh:@"/A"];

    XCTAssertEqualObjects([NSString stringWithContentsOfURL:kept encoding:NSUTF8StringEncoding error:NULL], @"HELLO");
    struct stat changed = StatOf([folder URLByAppendingPathComponent:@"changed.flac"]);
    XCTAssertEqual(changed.st_size, 20);
    XCTAssertEqual(changed.st_mode & 0777, 0);
    XCTAssertEqual(StatOf([folder URLByAppendingPathComponent:@"new.flac"]).st_size, 30);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[folder URLByAppendingPathComponent:@"gone.flac"].path]);
}

// DropboxRules.h: a path_display's case is only good in its last
// component, so another spelling must find the same directory.
- (void)testAnotherSpellingOfAFolderLandsInTheSameDirectory {
    _listings[@"/music"] = @[FolderEntry(@"/Music", @"Album")];
    _listings[@"/music/album"] = @[FileEntry(@"/Music/Album", @"a.mp3", 1, kStamp)];
    NSURL *first = [self refresh:@"/Music/Album"];
    NSURL *second = [self refresh:@"/MUSIC/album"];
    XCTAssertEqualObjects(second.path, first.path);
    NSArray *accountChildren = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:_mirror.accountURL.path error:NULL];
    XCTAssertEqualObjects(accountChildren, @[@"Music"]);
}

- (void)testMirrorPathsSurviveThePrivatePrefix {
    NSString *account = _mirror.accountURL.path;
    NSURL *track = [NSURL fileURLWithPath:[account stringByAppendingPathComponent:@"Music/a.flac"]];
    XCTAssertEqualObjects([_mirror dropboxPathForURL:track], @"/Music/a.flac");
    XCTAssertEqualObjects([_mirror dropboxPathForURL:_mirror.accountURL], @"");
    XCTAssertTrue([_mirror containsURL:track]);
    XCTAssertNil([_mirror dropboxPathForURL:[NSURL fileURLWithPath:@"/tmp/elsewhere.flac"]]);
    XCTAssertFalse([_mirror containsURL:[NSURL fileURLWithPath:@"/tmp/elsewhere.flac"]]);
}

// The install dates a part to its version just before renaming it, so the
// stale sweep goes by when it last changed, which a write or that dating
// moves, never by its mtime.
- (void)testARelistingKeepsAPartDatedToItsVersion {
    _listings[@"/music"] = @[FileEntry(@"/Music", @"a.flac", 5, kStamp)];
    NSURL *folder = [self refresh:@"/Music"];
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:[folder URLByAppendingPathComponent:@"a.flac"]];
    XCTAssertTrue([[@"12345" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:part atomically:NO]);
    struct timeval times[2] = {{kStampSeconds, 0}, {kStampSeconds, 0}};
    XCTAssertEqual(utimes(part.fileSystemRepresentation, times), 0);

    [self refresh:@"/Music"];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:part.path]);
}

#pragma mark Search

- (void)testASearchHitResolvesToItsPlaceholderAfterItsFolderIsListed {
    NSDictionary *hit = FileEntry(@"/Music/Album", @"01 Song.flac", 77, kStamp);
    NSDictionary *folderHit = FolderEntry(@"/Music", @"Album");
    _searchEntries = @[hit, folderHit, FileEntry(@"/Music/Album", @"cover.jpg", 1, kStamp)];
    _listings[@"/music/album"] = @[hit];

    XCTestExpectation *searched = [self expectationWithDescription:@"search"];
    __block NSArray<NSDictionary *> *found = nil;
    [_mirror searchQuery:@"song" completion:^(NSArray<NSDictionary *> *entries, NSError *error) {
        XCTAssertNil(error);
        found = entries;
        [searched fulfill];
    }];
    [self waitForExpectations:@[searched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(found.count, 2u, @"the jpg is not something the mirror holds");

    XCTestExpectation *resolved = [self expectationWithDescription:@"resolve"];
    __block NSURL *track = nil;
    [_mirror localURLForEntry:found[0] completion:^(NSURL *url, NSError *error) {
        XCTAssertNil(error);
        track = url;
        [resolved fulfill];
    }];
    [self waitForExpectations:@[resolved] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(track.lastPathComponent, @"01 Song.flac");
    XCTAssertEqual(StatOf(track).st_size, 77);
    XCTAssertEqualObjects([_mirror dropboxPathForURL:track.URLByDeletingLastPathComponent], @"/Music/Album");
}

// A folder made on the way to a search hit takes the hit's display
// spelling, not path_lower's lowercase.
- (void)testASearchHitsFolderIsMadeInItsDisplaySpelling {
    NSDictionary *hit = FileEntry(@"/Music/TECHNO", @"x.wav", 3, kStamp);
    _listings[@"/music/techno"] = @[hit];
    XCTestExpectation *resolved = [self expectationWithDescription:@"resolve"];
    __block NSURL *track = nil;
    [_mirror localURLForEntry:hit completion:^(NSURL *url, NSError *error) {
        XCTAssertNil(error);
        track = url;
        [resolved fulfill];
    }];
    [self waitForExpectations:@[resolved] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects([track.URLByDeletingLastPathComponent.path
            substringFromIndex:_mirror.accountURL.path.length], @"/Music/TECHNO");
}

#pragma mark Ranged reads

// A server that ignores Range answers 200 with the whole file; past its end
// that is nothing, never bytes from its start.
- (void)testAWholeFileAnswerPastTheEndReadsAsNothing {
    _listings[@"/music"] = @[FileEntry(@"/Music", @"short.mp3", 100, kStamp)];
    NSURL *track = [[self refresh:@"/Music"] URLByAppendingPathComponent:@"short.mp3"];
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/2/files/download"]) {
            return (DropboxStubResponse){200, @{}, [@"SHRUNK" dataUsingEncoding:NSUTF8StringEncoding], NO};
        }
        return [self defaultResponseFor:request json:json];
    }];
    NSError *error = nil;
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:90 length:10 error:&error], [NSData data]);
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:2 length:3 error:&error],
                          [@"RUN" dataUsingEncoding:NSUTF8StringEncoding]);
}

// A tag parse's read: the bytes asked for, by the listed id, and the
// placeholder left a placeholder.
- (void)testARangedReadReturnsTheBytesAndDownloadsNothing {
    _listings[@"/music"] = @[FileEntry(@"/Music", @"tagged.mp3", 10, kStamp)];
    _contents[@"/music/tagged.mp3"] = [@"ID3abcdefg" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *track = [[self refresh:@"/Music"] URLByAppendingPathComponent:@"tagged.mp3"];

    NSError *error = nil;
    NSData *head = [_mirror readPlaceholderAtURL:track offset:0 length:3 error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(head, [@"ID3" dataUsingEncoding:NSUTF8StringEncoding]);
    NSData *tail = [_mirror readPlaceholderAtURL:track offset:7 length:3 error:&error];
    XCTAssertEqualObjects(tail, [@"efg" dataUsingEncoding:NSUTF8StringEncoding]);

    NSURLRequest *read = [self requestsToPath:@"/2/files/download"].lastObject;
    XCTAssertEqualObjects([read valueForHTTPHeaderField:@"Range"], @"bytes=7-9");
    XCTAssertTrue([[read valueForHTTPHeaderField:@"Dropbox-API-Arg"] containsString:@"id:/music/tagged.mp3"]);
    XCTAssertEqual(StatOf(track).st_mode & 0777, 0, @"a read is not a download");
    XCTAssertEqual([self measuredDownloads], 0);
}

#pragma mark Fetch

- (void)installMirrorFetch {
    DropboxMirror *mirror = _mirror;
    [CloudFileMaterializer setRemoteRoot:_root fetch:^BOOL(NSURL *url, dispatch_block_t onReadable, void (^onCancel)(dispatch_block_t), NSError **error) {
        return [mirror fetchPlaceholderAtURL:url onReadable:onReadable onCancel:onCancel error:error];
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        return [mirror readPlaceholderAtURL:url offset:offset length:length error:error];
    } availability:^CloudFileAvailability *(NSURL *url) {
        return [mirror availabilityForURL:url];
    }];
}

- (void)testMaterializingAPlaceholderDownloadsItsBytesInPlace {
    _listings[@"/music"] = @[FileEntry(@"/Music", @"Café.flac", 5, kStamp)];
    _contents[@"/music/café.flac"] = [@"BYTES" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *track = [[self refresh:@"/Music"] URLByAppendingPathComponent:@"Café.flac"];
    [self installMirrorFetch];
    XCTAssertTrue([NSURLUtil isDatalessFile:track]);

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    NSError *error = nil;
    XCTAssertTrue([materializer materializeURL:track token:[materializer prepareMaterialization] onReadable:nil error:&error]);
    XCTAssertNil(error);

    XCTAssertEqualObjects([NSString stringWithContentsOfURL:track encoding:NSUTF8StringEncoding error:NULL], @"BYTES");
    struct stat st = StatOf(track);
    XCTAssertEqual(st.st_mode & 0777, 0644);
    XCTAssertEqual(st.st_mtimespec.tv_sec, kStampSeconds);
    XCTAssertFalse([NSURLUtil isDatalessFile:track]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[NSURLUtil remotePlaceholderPartURL:track].path]);

    // By the listed id, composed as Dropbox sent it, though the URL's own
    // path comes back decomposed.
    NSURLRequest *download = [self requestsToPath:@"/2/files/download"].lastObject;
    NSString *argument = [download valueForHTTPHeaderField:@"Dropbox-API-Arg"];
    XCTAssertTrue([argument containsString:@"id:/music/caf\\u00e9.flac"], @"%@", argument);
}

// VibeDropboxIndexKey, for a folder: listed by its URL, it is asked
// for by the path its parent's listing recorded, not its decomposed name.
- (void)testAFolderWithAnAccentIsRelistedByItsRecordedPath {
    _listings[@"/music"] = @[FolderEntry(@"/Music", @"Café")];
    _listings[@"/music/café"] = @[FileEntry(@"/Music/Café", @"a.flac", 1, kStamp)];
    NSURL *music = [self refresh:@"/Music"];
    NSURL *cafe = [[NSFileManager.defaultManager contentsOfDirectoryAtURL:music includingPropertiesForKeys:nil
                                                                  options:0 error:NULL] firstObject];
    XCTAssertNotNil(cafe);
    XCTAssertEqualObjects([_mirror dropboxPathForURL:cafe], @"/music/café");

    // The browser's relist: the folder's recorded path, back into the same
    // directory.
    NSURL *relisted = [self refresh:[_mirror dropboxPathForURL:cafe]];
    XCTAssertEqualObjects(relisted.path, cafe.path);
    XCTAssertEqual(StatOf([cafe URLByAppendingPathComponent:@"a.flac"]).st_size, 1);
}

- (long long)measuredDownloads {
    XCTestExpectation *measured = [self expectationWithDescription:@"measure"];
    __block long long bytes = -1;
    [_mirror measureDownloadsWithCompletion:^(long long total) {
        bytes = total;
        [measured fulfill];
    }];
    [self waitForExpectations:@[measured] timeout:VIBE_TEST_HANG_TIMEOUT];
    return bytes;
}

- (BOOL)materialize:(NSURL *)url {
    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    return [materializer materializeURL:url token:[materializer prepareMaterialization] onReadable:nil error:NULL];
}

// The budget is 8 bytes here: the second 5-byte download pushes the first
// back to a placeholder, with the size and mtime its cache key was made from.
- (void)testDownloadsPastTheBudgetGoBackToPlaceholdersOldestFirst {
    _listings[@"/music"] = @[FileEntry(@"/Music", @"one.flac", 5, kStamp),
                             FileEntry(@"/Music", @"two.flac", 5, kStamp)];
    _contents[@"/music/one.flac"] = [@"11111" dataUsingEncoding:NSUTF8StringEncoding];
    _contents[@"/music/two.flac"] = [@"22222" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *folder = [self refresh:@"/Music"];
    NSURL *one = [folder URLByAppendingPathComponent:@"one.flac"];
    NSURL *two = [folder URLByAppendingPathComponent:@"two.flac"];
    [self installMirrorFetch];

    XCTAssertTrue([self materialize:one]);
    XCTAssertEqual([self measuredDownloads], 5);
    XCTAssertTrue([self materialize:two]);
    XCTAssertEqual([self measuredDownloads], 5);

    struct stat evicted = StatOf(one);
    XCTAssertEqual(evicted.st_mode & 0777, 0);
    XCTAssertEqual(evicted.st_size, 5);
    XCTAssertEqual(evicted.st_mtimespec.tv_sec, kStampSeconds);
    XCTAssertEqualObjects([NSString stringWithContentsOfURL:two encoding:NSUTF8StringEncoding error:NULL], @"22222");
}

- (void)testRemovingDownloadsLeavesPlaceholdersAndSheets {
    NSData *sheet = [@"FILE \"one.flac\" WAVE\n" dataUsingEncoding:NSUTF8StringEncoding];
    _listings[@"/music"] = @[FileEntry(@"/Music", @"one.flac", 5, kStamp),
                             FileEntry(@"/Music", @"one.cue", (long long)sheet.length, kStamp)];
    _contents[@"/music/one.flac"] = [@"11111" dataUsingEncoding:NSUTF8StringEncoding];
    _contents[@"/music/one.cue"] = sheet;
    NSURL *folder = [self refresh:@"/Music"];
    [self installMirrorFetch];
    XCTAssertTrue([self materialize:[folder URLByAppendingPathComponent:@"one.flac"]]);

    XCTestExpectation *removed = [self expectationWithDescription:@"remove"];
    [_mirror removeDownloadsWithCompletion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[removed] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([self measuredDownloads], 0);
    XCTAssertEqual(StatOf([folder URLByAppendingPathComponent:@"one.flac"]).st_mode & 0777, 0);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"one.cue"]], sheet);
}

// A cancel while the token refresh hangs settles the transfer now, not when
// the refresh returns: the lane it holds is freed at once.
- (void)testCancellingWhileTheRefreshHangsSettlesAtOnce {
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/oauth2/token"]) {
            return (DropboxStubResponse){0, nil, nil, YES};
        }
        return [self defaultResponseFor:request json:json];
    }];
    XCTestExpectation *read = [self expectationWithDescription:@"read"];
    dispatch_block_t cancelRead = [_client readPath:@"/Music/a.flac" offset:0 length:8
                                         completion:^(NSData *data, NSDictionary *metadata, NSError *error) {
        XCTAssertNil(data);
        XCTAssertEqual(error.code, VibeDropboxErrorCancelled);
        [read fulfill];
    }];
    XCTestExpectation *download = [self expectationWithDescription:@"download"];
    dispatch_block_t cancelDownload = [_client downloadPath:@"/Music/a.flac"
                                                      toURL:[_root URLByAppendingPathComponent:@"a.part"]
                                                   progress:nil
                                                 completion:^(NSDictionary *metadata, NSError *error) {
        XCTAssertNil(metadata);
        XCTAssertEqual(error.code, VibeDropboxErrorCancelled);
        [download fulfill];
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:@"/oauth2/token"].count == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 1u);
    cancelRead();
    cancelDownload();
    [self waitForExpectations:@[read, download] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 0u);
}

- (void)testCancellingAFetchStopsTheTransferAndLeavesThePlaceholder {
    _listings[@"/music"] = @[FileEntry(@"/Music", @"slow.flac", 5, kStamp)];
    NSURL *track = [[self refresh:@"/Music"] URLByAppendingPathComponent:@"slow.flac"];
    [self installMirrorFetch];
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/2/files/download"]) {
            return (DropboxStubResponse){0, nil, nil, YES};
        }
        return [self defaultResponseFor:request json:json];
    }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    XCTestExpectation *returned = [self expectationWithDescription:@"materialize returned"];
    __block BOOL materialized = YES;
    __block NSError *failure = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        materialized = [materializer materializeURL:track token:token onReadable:nil error:&error];
        failure = error;
        [returned fulfill];
    });

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:@"/2/files/download"].count == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 1u);
    [materializer cancel];

    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse(materialized);
    XCTAssertEqualObjects(failure.domain, NSCocoaErrorDomain);
    XCTAssertEqual(failure.code, NSUserCancelledError);
    XCTAssertEqual(StatOf(track).st_mode & 0777, 0);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[NSURLUtil remotePlaceholderPartURL:track].path]);
}

#pragma mark Resumed downloads

// A resend can follow only a response that ended early, since Dropbox's
// status comes before any byte: a throttle or an expired token "mid-way" is
// the answer to the resume after a dropped connection.

static NSData *PatternBytes(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < length; i++) {
        bytes[i] = (uint8_t)(i * 7 + i / 251);
    }
    return data;
}

// Inside the account's directory: the adopt's account change prunes
// everything else under the root, and lands whenever the main queue turns.
- (NSURL *)partURL {
    NSURL *account = _mirror.accountURL;
    [NSFileManager.defaultManager createDirectoryAtURL:account withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    return [account URLByAppendingPathComponent:@"song.flac.part"];
}

static BOOL IsClosedRange(NSURLRequest *request) {
    NSString *range = [request valueForHTTPHeaderField:@"Range"];
    return range && ![range hasSuffix:@"-"];
}

// Files/download's answers by request, counted from 0; the rest as default,
// closed ranges through _rangeScript.
- (void)scriptDownloads:(DropboxStubResponse (^)(NSInteger index, NSURLRequest *request))script {
    __block NSInteger downloads = 0;
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if (![request.URL.path isEqualToString:@"/2/files/download"]) {
            return [self defaultResponseFor:request json:json];
        }
        if (IsClosedRange(request)) {
            DropboxStubResponse (^ranges)(NSURLRequest *);
            @synchronized (self) {
                ranges = self->_rangeScript;
            }
            return ranges ? ranges(request) : [self defaultResponseFor:request json:json];
        }
        NSInteger index;
        @synchronized (self) {
            index = downloads++;
        }
        return script(index, request);
    }];
}

- (DropboxStubResponse)answer:(NSURLRequest *)request {
    return [self defaultResponseFor:request json:nil];
}

- (NSError *)downloadSong:(NSDictionary **)metadata {
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    __block NSError *failure = nil;
    __block NSDictionary *result = nil;
    [_client downloadPath:@"/song.flac" toURL:[self partURL] progress:nil
               completion:^(NSDictionary *answer, NSError *error) {
        result = answer;
        failure = error;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (metadata) *metadata = result;
    return failure;
}

- (void)waitForDownloadRequests:(NSUInteger)count {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:@"/2/files/download"].count < count && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, count);
}

- (void)testAThrottledResumeAppendsToTheSameFile {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    NSURL *part = [self partURL];
    NSMutableArray<NSNumber *> *inodes = [NSMutableArray array];
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, 1600, [self partURL]);
        }
        @synchronized (inodes) {
            [inodes addObject:@(StatOf(part).st_ino)];
        }
        if (index == 1) {
            return DropboxStubJSON(429, @{@"error_summary": @"too_many_requests/"});
        }
        // Marked, to show the completion reports the first response's.
        return DownloadAnswer(request, bytes, @{@"rev": kRev, @"server_modified": @"2021-01-01T00:00:00Z"});
    }];

    NSDictionary *metadata = nil;
    XCTAssertNil([self downloadSong:&metadata]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:part], bytes);
    XCTAssertEqualObjects(metadata[@"server_modified"], kStamp);
    NSArray<NSURLRequest *> *requests = [self requestsToPath:@"/2/files/download"];
    XCTAssertEqual(requests.count, 3u);
    XCTAssertNil([requests[0] valueForHTTPHeaderField:@"Range"]);
    XCTAssertEqualObjects([requests[1] valueForHTTPHeaderField:@"Range"], @"bytes=1600-");
    XCTAssertEqualObjects([requests[2] valueForHTTPHeaderField:@"Range"], @"bytes=1600-");
    ino_t inode = StatOf(part).st_ino;
    XCTAssertNotEqual(inode, 0u);
    XCTAssertEqualObjects(inodes, (@[@(inode), @(inode)]), @"a resend never makes a new file");
}

- (void)testAnExpiredTokenMidDownloadRefreshesAndResumes {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, 1200, [self partURL]);
        }
        if ([[request valueForHTTPHeaderField:@"Authorization"] isEqualToString:@"Bearer A1"]) {
            return DropboxStubJSON(401, @{@"error_summary": @"expired_access_token/",
                                          @"error": @{@".tag": @"expired_access_token"}});
        }
        return [self answer:request];
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 2u);
    NSURLRequest *resumed = [self requestsToPath:@"/2/files/download"].lastObject;
    XCTAssertEqualObjects([resumed valueForHTTPHeaderField:@"Authorization"], @"Bearer A2");
    XCTAssertEqualObjects([resumed valueForHTTPHeaderField:@"Range"], @"bytes=1200-");
    XCTAssertTrue(_client.isLinked);
}

// Three drops in a row, past the bound of two, still finish: each brought
// bytes, and only drops with nothing between them count.
- (void)testDroppedConnectionsThatMakeProgressResumeUntilDone {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        return index < 3 ? Dropped([self answer:request], request, 1000, [self partURL]) : [self answer:request];
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    NSArray<NSURLRequest *> *requests = [self requestsToPath:@"/2/files/download"];
    XCTAssertEqual(requests.count, 4u);
    XCTAssertEqualObjects([requests[3] valueForHTTPHeaderField:@"Range"], @"bytes=3000-");
}

// A transfer the link ended — dropped past the resume bound, or cancelled —
// keeps its part for the next download of that file, which continues it from
// its last byte (below); one its own answer ended, another version or a disk
// write, deletes it, and the stale sweep takes a kept one after a day.
- (void)testDropsWithNoProgressPastTheBoundFailAndKeepThePart {
    _contents[@"/song.flac"] = PatternBytes(4000);
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, 1000, [self partURL]);
        }
        DropboxStubResponse unreachable = {0};
        unreachable.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                                              userInfo:nil];
        return unreachable;
    }];

    NSError *error = [self downloadSong:NULL];
    XCTAssertEqualObjects(error.domain, NSURLErrorDomain);
    XCTAssertEqual(error.code, NSURLErrorNotConnectedToInternet);
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 3u, @"the first, then two resumes");
    XCTAssertEqual(StatOf([self partURL]).st_size, 1000, @"kept for the next download");
}

- (void)testAResumeAnsweringAnotherRevisionFailsAndDeletesThePart {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, 1600, [self partURL]);
        }
        return DownloadAnswer(request, bytes, @{@"rev": @"0200beef", @"server_modified": kStamp});
    }];

    NSError *error = [self downloadSong:NULL];
    XCTAssertEqualObjects(error.domain, VibeDropboxErrorDomain);
    XCTAssertEqual(error.code, VibeDropboxErrorFileChanged);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self partURL].path]);
}

// With no rev on the first answer nothing can prove a resume is the same
// version: whole in one piece it installs, cut off it fails.
- (void)testAFirstAnswerWithoutARevisionDownloadsWholeButNeverResumes {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    __block BOOL drop = NO;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        DropboxStubResponse answer = DownloadAnswer(request, bytes, @{@"server_modified": kStamp});
        return drop && index == 1 ? Dropped(answer, request, 1600, [self partURL]) : answer;
    }];
    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);

    [NSFileManager.defaultManager removeItemAtURL:[self partURL] error:NULL];
    drop = YES;
    NSError *error = [self downloadSong:NULL];
    XCTAssertEqual(error.code, VibeDropboxErrorFileChanged);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self partURL].path]);
}

// A server ignoring the Range answers 200 with the whole file: what was
// already written is skipped, never appended a second time.
- (void)testAWholeFileAnswerToAResumeSkipsWhatWasWritten {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, 1600, [self partURL]);
        }
        NSMutableURLRequest *unranged = [request mutableCopy];
        [unranged setValue:nil forHTTPHeaderField:@"Range"];
        return [self answer:unranged];
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    XCTAssertEqualObjects([[self requestsToPath:@"/2/files/download"].lastObject valueForHTTPHeaderField:@"Range"],
                          @"bytes=1600-");
}

- (void)testCancellingDuringAResumeKeepsThePartAndCompletesOnce {
    _contents[@"/song.flac"] = PatternBytes(4000);
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, 1600, [self partURL]);
        }
        return (DropboxStubResponse){0, nil, nil, YES};
    }];
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    __block NSInteger completions = 0;
    __block NSError *failure = nil;
    dispatch_block_t cancel = [_client downloadPath:@"/song.flac" toURL:[self partURL] progress:nil
                                         completion:^(NSDictionary *metadata, NSError *error) {
        @synchronized (self) {
            completions++;
        }
        failure = error;
        [done fulfill];
    }];
    [self waitForDownloadRequests:2];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:[self partURL].path]);
    cancel();

    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(completions, 1);
    XCTAssertEqualObjects(failure.domain, VibeDropboxErrorDomain);
    XCTAssertEqual(failure.code, VibeDropboxErrorCancelled);
    XCTAssertEqual(StatOf([self partURL]).st_size, 1600, @"kept for the next download");
}

// A download that finds its destination holding bytes of a version continues
// from them: the request asks for the rest, and the file ends whole.
- (void)testTheNextDownloadContinuesAKeptPart {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    [self cancelADownloadAfter:1600];
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        return [self answer:request];
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    NSArray<NSURLRequest *> *requests = [self requestsToPath:@"/2/files/download"];
    XCTAssertEqual(requests.count, 1u);
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Range"], @"bytes=1600-");
}

// A kept part of a version no longer current cannot be continued: the answer
// to the resume names another rev, so the download starts over, whole.
- (void)testAKeptPartOfAnotherVersionIsStartedOver {
    _contents[@"/song.flac"] = PatternBytes(4000);
    [self cancelADownloadAfter:1600];
    NSData *newer = PatternBytes(4400);
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        return DownloadAnswer(request, newer, @{@"rev": @"0200beef", @"server_modified": kStamp});
    }];

    NSDictionary *metadata = nil;
    XCTAssertNil([self downloadSong:&metadata]);
    XCTAssertEqualObjects(metadata[@"rev"], @"0200beef");
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], newer);
    NSArray<NSURLRequest *> *requests = [self requestsToPath:@"/2/files/download"];
    XCTAssertEqual(requests.count, 2u, @"the resume, then the whole file");
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Range"], @"bytes=1600-");
    XCTAssertNil([requests[1] valueForHTTPHeaderField:@"Range"]);
}

// A download of song.flac cancelled once its part holds `written` bytes,
// leaving the part; the request log is cleared for what follows.
- (void)cancelADownloadAfter:(NSUInteger)written {
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, written, [self partURL]);
        }
        return (DropboxStubResponse){0, nil, nil, YES};
    }];
    XCTestExpectation *done = [self expectationWithDescription:@"cancelled"];
    dispatch_block_t cancel = [_client downloadPath:@"/song.flac" toURL:[self partURL] progress:nil
                                         completion:^(NSDictionary *metadata, NSError *error) {
        [done fulfill];
    }];
    [self waitForDownloadRequests:2];
    cancel();
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(StatOf([self partURL]).st_size, (off_t)written);
    [self clearRequests];
}

// A dropped connection after the last byte is the whole file: a resend
// would ask for bytes=<size>-, which Dropbox answers 416.
- (void)testAConnectionDroppedAfterTheLastByteCompletesWithoutAResume {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        return Dropped([self answer:request], request, bytes.length, [self partURL]);
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 1u);
}

// Short or long against its version's size, a file is not that version.
- (void)testADownloadOfAnotherLengthThanItsSizeFailsAndDeletesThePart {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    for (NSNumber *size in @[@3000, @5000]) {
        [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
            return DownloadAnswer(request, bytes, @{@"rev": kRev, @"server_modified": kStamp, @"size": size});
        }];
        NSError *error = [self downloadSong:NULL];
        XCTAssertEqualObjects(error.domain, VibeDropboxErrorDomain, @"size %@", size);
        XCTAssertEqual(error.code, VibeDropboxErrorAPI, @"size %@", size);
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self partURL].path], @"size %@", size);
    }
}

#pragma mark Streaming

// One mirrored track whose download is held back a chunk at a time, every
// chunk waiting on _chunkGate; chunk 0 delivers it whole.
- (NSURL *)streamingTrack:(NSData *)bytes name:(NSString *)name chunk:(NSUInteger)chunk {
    _listings[@"/music"] = @[FileEntry(@"/Music", name, (long long)bytes.length, kStamp)];
    _contents[[@"/music/" stringByAppendingString:name.lowercaseString]] = bytes;
    NSURL *track = [[self refresh:@"/Music"] URLByAppendingPathComponent:name];
    [self installMirrorFetch];
    dispatch_semaphore_t gate = _chunkGate;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        DropboxStubResponse answer = [self answer:request];
        answer.chunk = chunk;
        answer.beforeChunk = ^(NSUInteger chunkIndex) {
            dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        };
        return answer;
    }];
    _streamTrack = track;
    return track;
}

- (void)releaseChunks:(NSUInteger)count {
    for (NSUInteger i = 0; i < count; i++) {
        dispatch_semaphore_signal(_chunkGate);
    }
}

// Each note with the part file's size and the window held as it was made,
// and each finish with what the install and the lookup looked like then.
- (void)recordAvailabilities {
    @synchronized (self) {
        _notes = [NSMutableArray array];
        _finishes = [NSMutableArray array];
    }
    __weak DropboxMirrorTests *weakSelf = self;
    ObserveAvailabilities(^(CloudFileAvailability *availability, uint64_t bytes) {
        DropboxMirrorTests *test = weakSelf;
        if (!test) {
            return;
        }
        struct stat st = {0};
        stat(availability.partURL.fileSystemRepresentation, &st);
        // Outside the test's lock: XCTest takes it to report a runtime issue,
        // which can fire inside the availability's.
        uint64_t window = availability.windowLength;
        @synchronized (test) {
            [test->_notes addObject:@[availability, @(bytes), @(st.st_size), @(window)]];
        }
        dispatch_semaphore_signal(test->_noteSignal);
    }, ^(CloudFileAvailability *availability, NSError *error) {
        DropboxMirrorTests *test = weakSelf;
        if (!test) {
            return;
        }
        NSURL *track = test->_streamTrack;
        NSDictionary *finish = @{
            @"availability": availability,
            @"error": error ?: NSNull.null,
            @"partExists": @([NSFileManager.defaultManager fileExistsAtPath:availability.partURL.path]),
            @"installed": @((StatOf(track).st_mode & 0777) == 0644),
            @"registered": @([test->_mirror availabilityForURL:track] == availability),
        };
        @synchronized (test) {
            [test->_finishes addObject:finish];
        }
    });
}

- (NSArray<NSArray *> *)notes {
    @synchronized (self) {
        return [_notes copy];
    }
}

- (NSArray<NSDictionary *> *)finishes {
    @synchronized (self) {
        return [_finishes copy];
    }
}

- (uint64_t)mostNoted {
    uint64_t most = 0;
    for (NSArray *note in [self notes]) {
        most = MAX(most, [note[1] unsignedLongLongValue]);
    }
    return most;
}

// Until a note has reached `bytes`, or `count` notes were made.
- (void)awaitNoted:(uint64_t)bytes count:(NSUInteger)count {
    while ([self mostNoted] < bytes || [self notes].count < count) {
        if (dispatch_semaphore_wait(_noteSignal, dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) != 0) {
            XCTFail(@"noted %llu of %llu in %lu notes", [self mostNoted], bytes, (unsigned long)[self notes].count);
            return;
        }
    }
}

// The fetch's availability, once its first response made the part file.
- (CloudFileAvailability *)awaitAvailability {
    [self awaitNoted:0 count:1];
    return [self notes].firstObject[0];
}

// Materializes the track on a worker; _fetched and _fetchError once fulfilled.
- (XCTestExpectation *)fetch:(NSURL *)track materializer:(CloudFileMaterializer *)materializer
                  onReadable:(dispatch_block_t)onReadable {
    XCTestExpectation *returned = [self expectationWithDescription:@"fetched"];
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        self->_fetched = [materializer materializeURL:track token:token onReadable:onReadable error:&error];
        self->_fetchError = error;
        [returned fulfill];
    });
    return returned;
}

// A wait for [offset, offset + length) on a worker: `blocked` is signalled
// once it is about to block, and the returned semaphore when it returns.
- (dispatch_semaphore_t)read:(CloudFileAvailability *)availability at:(uint64_t)offset length:(uint64_t)length
                     blocked:(dispatch_semaphore_t)blocked result:(CloudFileAvailabilityWait *)result
                       error:(NSError *__strong *)error {
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block BOOL signalled = NO;
        NSError *waitError = nil;
        *result = [availability waitForBytesAt:offset length:length windowInto:NULL capacity:0 copied:NULL interrupted:^BOOL{
            if (!signalled) {
                signalled = YES;
                dispatch_semaphore_signal(blocked);
            }
            return NO;
        } deadline:nil error:&waitError];
        if (error) {
            *error = waitError;
        }
        dispatch_semaphore_signal(returned);
    });
    return returned;
}

- (BOOL)await:(dispatch_semaphore_t)semaphore {
    BOOL signalled = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
    XCTAssertTrue(signalled);
    return signalled;
}

// The finish came after the install, or the failure, and before the lookup
// let go; then it lets go.
- (void)assertFinishedOnce:(CloudFileAvailability *)availability error:(NSError *)error {
    NSArray<NSDictionary *> *finishes = [self finishes];
    XCTAssertEqual(finishes.count, 1u);
    NSDictionary *finish = finishes.firstObject;
    XCTAssertEqual(finish[@"availability"], availability);
    XCTAssertEqualObjects(finish[@"error"], error ?: NSNull.null);
    // Installed, or deleted; kept only when the link ended the transfer.
    BOOL kept = ([error.domain isEqualToString:VibeDropboxErrorDomain] && error.code == VibeDropboxErrorCancelled)
            || VibeDropboxIsConnectionError(error);
    XCTAssertEqualObjects(finish[@"partExists"], @(kept));
    XCTAssertEqualObjects(finish[@"installed"], @(error == nil));
    XCTAssertEqualObjects(finish[@"registered"], @YES, @"the lookup let go before the finish");
    XCTAssertNil([_mirror availabilityForURL:_streamTrack]);
    XCTAssertNil([CloudFileMaterializer availabilityForURL:_streamTrack]);
}

// Registered at the first response, before any byte; noted after each write
// with no more than is on disk; readable once, past 256 KB; a reader waiting
// ahead released by the download alone.
- (void)testAStreamingFetchIsReadableThroughTheLookupAsItsBytesArrive {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = PatternBytes(16 * chunk);
    NSURL *track = [self streamingTrack:bytes name:@"stream.flac" chunk:chunk];
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:track];
    [self recordAvailabilities];
    DropboxMirror *mirror = _mirror;
    __block _Atomic int readables = 0;
    __block uint64_t readableOnDisk = 0;
    __block CloudFileAvailability *readableRegistered = nil;
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        readableOnDisk = (uint64_t)StatOf(part).st_size;
        readableRegistered = [mirror availabilityForURL:track];
        atomic_fetch_add(&readables, 1);
    }];

    CloudFileAvailability *availability = [self awaitAvailability];
    XCTAssertEqual([_mirror availabilityForURL:track], availability);
    XCTAssertEqual([CloudFileMaterializer availabilityForURL:track], availability);
    XCTAssertEqualObjects(availability.partURL.path, part.path);
    XCTAssertEqual(availability.size, (uint64_t)bytes.length);
    XCTAssertEqual(StatOf(part).st_size, (off_t)0, @"registered before any byte");

    dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
    CloudFileAvailabilityWait waited = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:9 * chunk + 100 length:1000
                                       blocked:blocked result:&waited error:NULL];
    [self await:blocked];
    for (NSUInteger i = 1; i <= 16; i++) {
        [self releaseChunks:1];
        [self awaitNoted:i * chunk count:0];
        if (i * chunk < kReadableBytes) {
            XCTAssertEqual(atomic_load(&readables), 0, @"chunk %lu", (unsigned long)i);
        }
        else if (i * chunk > kReadableBytes) {
            XCTAssertEqual(atomic_load(&readables), 1, @"chunk %lu", (unsigned long)i);
        }
        if (i < 10) {
            XCTAssertNotEqual(dispatch_semaphore_wait(returned, DISPATCH_TIME_NOW), 0, @"chunk %lu", (unsigned long)i);
        }
        else if (i == 10) {
            [self await:returned];
            XCTAssertEqual(waited, CloudFileAvailabilityReady);
        }
    }

    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertEqual(atomic_load(&readables), 1);
    XCTAssertGreaterThanOrEqual(readableOnDisk, kReadableBytes);
    XCTAssertEqual(readableRegistered, availability);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);

    NSArray<NSArray *> *notes = [self notes];
    XCTAssertGreaterThan(notes.count, 16u);
    uint64_t previous = 0;
    for (NSArray *note in notes) {
        XCTAssertEqual(note[0], availability);
        uint64_t noted = [note[1] unsignedLongLongValue];
        XCTAssertGreaterThanOrEqual([note[2] unsignedLongLongValue], noted, @"noted before it was written");
        XCTAssertGreaterThanOrEqual(noted, previous);
        previous = noted;
    }
    XCTAssertEqual(previous, (uint64_t)bytes.length);
    [self assertFinishedOnce:availability error:nil];
}

// Completing says ready: a file no bigger than the readable mark never
// reports readable, though it streams.
- (void)testASmallFileCompletesWithoutReportingReadable {
    NSData *bytes = PatternBytes(100 * 1024);
    NSURL *track = [self streamingTrack:bytes name:@"short.flac" chunk:16 * 1024];
    [self recordAvailabilities];
    [self releaseChunks:7];
    __block _Atomic int readables = 0;
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        atomic_fetch_add(&readables, 1);
    }];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertEqual(atomic_load(&readables), 0);
    XCTAssertEqual([self mostNoted], (uint64_t)bytes.length);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);
}

// The previous steps and this one end to end: the handle opens the part file
// while the rest of the download is held back, reads on as it arrives,
// follows the rename, and decodes exactly what the whole file decodes.
- (void)testAHandleOpenedMidFetchDecodesAsTheWholeFile {
    NSURL *sources = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"DropboxMirrorTests-sources-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:sources withIntermediateDirectories:YES attributes:nil error:NULL];
    // Four seconds of 16-bit stereo, 690 KB: past the readable mark twice over.
    const NSUInteger frames = 4 * 44100;
    NSMutableData *samples = [NSMutableData dataWithLength:frames * 2 * 2];
    int16_t *out = samples.mutableBytes;
    uint32_t state = 0x2468ace1;
    for (NSUInteger i = 0; i < frames * 2; i++) {
        state = state * 1664525u + 1013904223u;
        out[i] = (int16_t)(sin((double)i * 0.0123) * 12000.0 + (double)(int16_t)(state >> 16) * 0.5);
    }
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSURL *wav = VibeWriteWAV([sources URLByAppendingPathComponent:@"noise.wav"], samples, 44100, 2, 16,
                              (uint32_t)samples.length);
    XCTAssertNotNil(wav);
    if (wav) {
        [files addObject:wav];
    }
    // The real encode with a seek table, when the gitignored corpus is here.
    NSString *tone = [[NSString stringWithUTF8String:__FILE__].stringByDeletingLastPathComponent
            stringByAppendingPathComponent:@"../Assets/test_audio_files/tone.flac"].stringByStandardizingPath;
    if ([NSFileManager.defaultManager fileExistsAtPath:tone]) {
        [files addObject:[NSURL fileURLWithPath:tone]];
    }

    const NSUInteger chunk = 32 * 1024;
    NSUInteger streamed = 0;
    for (NSURL *source in files) {
        NSData *bytes = [NSData dataWithContentsOfURL:source];
        if (bytes.length < 2 * kReadableBytes) {
            continue;
        }
        streamed++;
        NSError *error = nil;
        AudioFileHandle *whole = [[AudioFileHandle alloc] initForReading:source error:&error];
        NSData *reference = whole ? DecodeAll(whole, &error) : nil;
        XCTAssertNotNil(reference, @"%@: %@", source.lastPathComponent, error);

        _chunkGate = dispatch_semaphore_create(0);
        NSURL *track = [self streamingTrack:bytes name:source.lastPathComponent chunk:chunk];
        [self recordAvailabilities];
        dispatch_semaphore_t readable = dispatch_semaphore_create(0);
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
            dispatch_semaphore_signal(readable);
        }];
        NSUInteger chunks = (bytes.length + chunk - 1) / chunk;
        NSUInteger head = (NSUInteger)(kReadableBytes / chunk);
        [self releaseChunks:head];
        if (![self await:readable]) {
            [self releaseChunks:chunks];
            [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
            continue;
        }
        CloudFileAvailability *availability = [self awaitAvailability];

        dispatch_semaphore_t opened = dispatch_semaphore_create(0);
        dispatch_semaphore_t decoded = dispatch_semaphore_create(0);
        __block AudioFileHandle *handle = nil;
        __block NSData *pcm = nil;
        __block NSError *readError = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *failure = nil;
            handle = [[AudioFileHandle alloc] initForReading:track error:&failure];
            dispatch_semaphore_signal(opened);
            pcm = handle ? DecodeAll(handle, &failure) : nil;
            readError = failure;
            dispatch_semaphore_signal(decoded);
        });
        // Opened with most of the file still held back: from the part file.
        XCTAssertTrue([self await:opened], @"%@", source.lastPathComponent);
        XCTAssertNotNil(handle, @"%@: %@", source.lastPathComponent, readError);
        XCTAssertLessThan([self mostNoted], (uint64_t)bytes.length);
        [self releaseChunks:chunks];

        XCTAssertTrue([self await:decoded]);
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertTrue(_fetched, @"%@: %@", source.lastPathComponent, _fetchError);
        XCTAssertNotNil(pcm, @"%@: %@", source.lastPathComponent, readError);
        XCTAssertEqual(pcm.length, reference.length, @"%@", source.lastPathComponent);
        XCTAssertTrue([pcm isEqualToData:reference], @"%@: the streamed decode differs", source.lastPathComponent);
        [self assertFinishedOnce:availability error:nil];
    }
    XCTAssertGreaterThan(streamed, 0u);
    [NSFileManager.defaultManager removeItemAtURL:sources error:NULL];
}

// A transfer failing mid-way, by a changed version or an error answer to its
// resume, fails a reader waiting ahead with the fetch's own error, and is
// then forgotten.
- (void)testAFailedResumeWakesAWaitingReaderWithTheFailure {
    for (NSNumber *changed in @[@YES, @NO]) {
        NSData *bytes = PatternBytes(1024 * 1024);
        NSURL *track = [self streamingTrack:bytes name:@"fails.flac" chunk:0];
        NSURL *part = [NSURLUtil remotePlaceholderPartURL:track];
        [self recordAvailabilities];
        dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
        dispatch_semaphore_t resume = dispatch_semaphore_create(0);
        [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
            if (index == 0) {
                return Dropped([self answer:request], request, 300 * 1024, part);
            }
            // Only once the reader is waiting past what was written.
            dispatch_semaphore_wait(resume, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            return changed.boolValue
                    ? DownloadAnswer(request, bytes, @{@"rev": @"0200beef", @"server_modified": kStamp})
                    : DropboxStubJSON(409, @{@"error_summary": @"path/not_found/"});
        }];
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
        CloudFileAvailability *availability = [self awaitAvailability];
        CloudFileAvailabilityWait waited = CloudFileAvailabilityReady;
        NSError *readError = nil;
        dispatch_semaphore_t returned = [self read:availability at:600 * 1024 length:1000
                                           blocked:blocked result:&waited error:&readError];
        [self await:blocked];
        dispatch_semaphore_signal(resume);

        [self await:returned];
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertFalse(_fetched);
        XCTAssertEqual(waited, CloudFileAvailabilityFailed, @"changed %@", changed);
        XCTAssertEqualObjects(readError, _fetchError);
        if (changed.boolValue) {
            XCTAssertEqual(readError.code, VibeDropboxErrorFileChanged);
        }
        XCTAssertEqual(StatOf(track).st_mode & 0777, 0);
        [self assertFinishedOnce:availability error:_fetchError];
    }
}

// The client's cancel reaches a waiting reader as the failure it is, never
// a clean end or a wait that outlives the transfer.
- (void)testCancellingAStreamingFetchWakesItsReaderAndForgetsIt {
    const NSUInteger chunk = 64 * 1024;
    NSURL *track = [self streamingTrack:PatternBytes(8 * chunk) name:@"cancel.flac" chunk:chunk];
    [self recordAvailabilities];
    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    XCTestExpectation *fetched = [self fetch:track materializer:materializer onReadable:nil];
    [self releaseChunks:1];
    [self awaitNoted:chunk count:0];
    CloudFileAvailability *availability = [self notes].firstObject[0];

    dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
    CloudFileAvailabilityWait waited = CloudFileAvailabilityReady;
    NSError *readError = nil;
    dispatch_semaphore_t returned = [self read:availability at:3 * chunk length:1000
                                       blocked:blocked result:&waited error:&readError];
    [self await:blocked];
    [materializer cancel];

    [self await:returned];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(waited, CloudFileAvailabilityFailed);
    XCTAssertEqualObjects(readError.domain, VibeDropboxErrorDomain);
    XCTAssertEqual(readError.code, VibeDropboxErrorCancelled);
    XCTAssertFalse(_fetched);
    XCTAssertEqual(_fetchError.code, NSUserCancelledError);
    XCTAssertEqual(StatOf(track).st_mode & 0777, 0);
    [self assertFinishedOnce:availability error:readError];
}

// A resume continues the transfer, so it continues its availability: one
// object from the first byte to the last, a reader across the gap included
// (short of the tail window, which would answer it from memory).
- (void)testAResumedFetchKeepsItsAvailability {
    NSData *bytes = PatternBytes(1024 * 1024);
    NSURL *track = [self streamingTrack:bytes name:@"resumed.flac" chunk:0];
    NSURL *part = [NSURLUtil remotePlaceholderPartURL:track];
    [self recordAvailabilities];
    dispatch_semaphore_t resume = dispatch_semaphore_create(0);
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return Dropped([self answer:request], request, 300 * 1024, part);
        }
        dispatch_semaphore_wait(resume, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        return [self answer:request];
    }];
    __block _Atomic int readables = 0;
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        atomic_fetch_add(&readables, 1);
    }];
    CloudFileAvailability *availability = [self awaitAvailability];
    dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
    CloudFileAvailabilityWait waited = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:700 * 1024 length:1000
                                       blocked:blocked result:&waited error:NULL];
    [self await:blocked];
    dispatch_semaphore_signal(resume);

    [self await:returned];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertEqual(waited, CloudFileAvailabilityReady);
    XCTAssertEqual(atomic_load(&readables), 1);
    XCTAssertEqualObjects([[self requestsToPath:@"/2/files/download"].lastObject valueForHTTPHeaderField:@"Range"],
                          @"bytes=307200-");
    for (NSArray *note in [self notes]) {
        XCTAssertEqual(note[0], availability);
    }
    XCTAssertEqual([self mostNoted], (uint64_t)bytes.length);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);
    [self assertFinishedOnce:availability error:nil];
}

#pragma mark The tail window

// A small format's window (DropboxRules.h).
static const uint64_t kWindowBytes = 128 * 1024;

// Every ranged read that completes calls this after its completion returns,
// while it is set: when a tail read's answer has reached the mirror.
static os_unfair_lock sReadLock = OS_UNFAIR_LOCK_INIT;
static dispatch_block_t sReadObserver;
static IMP sReadIMP;

static dispatch_block_t ObservedReadPath(id client, SEL selector, NSString *path, uint64_t offset, uint64_t length,
                                         void (^completion)(NSData *, NSDictionary *, NSError *)) {
    void (^observed)(NSData *, NSDictionary *, NSError *) = ^(NSData *data, NSDictionary *metadata, NSError *error) {
        completion(data, metadata, error);
        os_unfair_lock_lock(&sReadLock);
        dispatch_block_t observer = sReadObserver;
        os_unfair_lock_unlock(&sReadLock);
        if (observer) {
            observer();
        }
    };
    return ((dispatch_block_t (*)(id, SEL, NSString *, uint64_t, uint64_t, id))sReadIMP)(client, selector, path, offset,
                                                                                         length, observed);
}

static void ObserveRangedReads(dispatch_block_t _Nullable observer) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sReadIMP = method_setImplementation(class_getInstanceMethod(DropboxClient.class,
                                                                    @selector(readPath:offset:length:completion:)),
                                            (IMP)ObservedReadPath);
    });
    os_unfair_lock_lock(&sReadLock);
    sReadObserver = [observer copy];
    os_unfair_lock_unlock(&sReadLock);
}

- (NSArray<NSURLRequest *> *)tailReads {
    return [[self requestsToPath:@"/2/files/download"] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        return IsClosedRange(request);
    }]];
}

// A stream whose download is held a chunk at a time, its tail read answered
// by `tail` (nil: the file's bytes by range, held until `tailGate`).
- (NSURL *)tailedTrack:(NSData *)bytes name:(NSString *)name chunk:(NSUInteger)chunk
                  tail:(DropboxStubResponse (^_Nullable)(NSURLRequest *request))tail
              tailGate:(dispatch_semaphore_t)tailGate {
    NSURL *track = [self streamingTrack:bytes name:name chunk:chunk];
    NSDictionary *metadata = @{@"server_modified": kStamp, @"size": @(bytes.length), @"rev": kRev};
    @synchronized (self) {
        _rangeScript = tail ?: ^DropboxStubResponse(NSURLRequest *request) {
            DropboxStubResponse answer = DownloadAnswer(request, bytes, metadata);
            answer.chunk = answer.body.length;
            answer.beforeChunk = ^(NSUInteger index) {
                dispatch_semaphore_wait(tailGate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            };
            return answer;
        };
    }
    return track;
}

// A stream past twice the window reads its last 128 KB once, by id, as it
// starts; readable does not wait for it; the window holds it, so an MP3,
// whose open reads its last bytes, opens on the part file with only its head
// downloaded; the download reaching the window drops it; and the decode is
// the whole file's.
- (void)testAStreamReadsItsTailOnceAndAnMP3OpensOnTheHeadAndTheWindow {
    NSData *bytes = VibeMP3WithInfoFrame(4200, YES);
    XCTAssertGreaterThan(bytes.length, 2 * kWindowBytes);
    NSURL *sources = [_root URLByAppendingPathComponent:@"sources" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:sources withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *local = [sources URLByAppendingPathComponent:@"long.mp3"];
    XCTAssertTrue([bytes writeToURL:local atomically:YES]);
    NSError *error = nil;
    AudioFileHandle *whole = [[AudioFileHandle alloc] initForReading:local error:&error];
    NSData *reference = whole ? DecodeAll(whole, &error) : nil;
    XCTAssertNotNil(reference, @"%@", error);

    const NSUInteger chunk = 64 * 1024;
    dispatch_semaphore_t tailGate = dispatch_semaphore_create(0);
    NSURL *track = [self tailedTrack:bytes name:@"long.mp3" chunk:chunk tail:nil tailGate:tailGate];
    [self recordAvailabilities];
    dispatch_semaphore_t readable = dispatch_semaphore_create(0);
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:^{
        dispatch_semaphore_signal(readable);
    }];
    CloudFileAvailability *availability = [self awaitAvailability];
    XCTAssertTrue([self eventually:^BOOL { return [self tailReads].count == 1; }]);
    NSURLRequest *tailRead = [self tailReads].firstObject;
    uint64_t windowOffset = bytes.length - kWindowBytes;
    XCTAssertEqualObjects([tailRead valueForHTTPHeaderField:@"Range"],
                          ([NSString stringWithFormat:@"bytes=%llu-%llu", windowOffset, (uint64_t)bytes.length - 1]));
    XCTAssertTrue([[tailRead valueForHTTPHeaderField:@"Dropbox-API-Arg"] containsString:@"id:/music/long.mp3"]);

    // Readable at the mark, the tail read still held.
    [self releaseChunks:(NSUInteger)(kReadableBytes / chunk)];
    XCTAssertTrue([self await:readable]);
    XCTAssertEqual(availability.windowLength, 0u);
    dispatch_semaphore_signal(tailGate);
    XCTAssertTrue([self eventually:^BOOL { return availability.windowLength == kWindowBytes; }]);

    // Opened on the head and the window, nothing more released.
    dispatch_semaphore_t opened = dispatch_semaphore_create(0);
    dispatch_semaphore_t decoded = dispatch_semaphore_create(0);
    __block AudioFileHandle *handle = nil;
    __block NSData *pcm = nil;
    __block NSError *readError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *failure = nil;
        handle = [[AudioFileHandle alloc] initForReading:track error:&failure];
        dispatch_semaphore_signal(opened);
        pcm = handle ? DecodeAll(handle, &failure) : nil;
        readError = failure;
        dispatch_semaphore_signal(decoded);
    });
    XCTAssertTrue([self await:opened]);
    XCTAssertNotNil(handle, @"%@", readError);
    XCTAssertEqual([self mostNoted], kReadableBytes, @"opened without another byte of the download");
    XCTAssertEqual(handle.length, whole.length);

    // Up to the window's start: dropped, the rest still downloading.
    [self releaseChunks:(NSUInteger)((windowOffset + chunk - 1) / chunk - kReadableBytes / chunk)];
    [self awaitNoted:windowOffset count:0];
    // Polled: the observer sees a note before it lands, and the window goes as it lands.
    XCTAssertTrue([self eventually:^BOOL { return availability.windowLength == 0; }], @"the download reached the window");
    XCTAssertLessThan([self mostNoted], (uint64_t)bytes.length);
    [self releaseChunks:bytes.length / chunk + 1];

    XCTAssertTrue([self await:decoded]);
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    XCTAssertNotNil(pcm, @"%@", readError);
    XCTAssertTrue([pcm isEqualToData:reference], @"the streamed decode differs");
    XCTAssertEqual([self tailReads].count, 1u);
    [self assertFinishedOnce:availability error:nil];
}

// The tail read failing, or stalling until the download's end cancels it, is
// not the transfer's failure: the window stays absent, a read inside it waits
// for the download, and the fetch completes with every byte.
- (void)testAFailedOrStalledTailReadLeavesTheTransferWhole {
    for (NSNumber *stall in @[@NO, @YES]) {
        NSData *bytes = PatternBytes((NSUInteger)(2 * kWindowBytes + 1));
        _chunkGate = dispatch_semaphore_create(0);
        NSURL *track = [self tailedTrack:bytes name:stall.boolValue ? @"stalled.flac" : @"failed.flac" chunk:256 * 1024
                                    tail:^DropboxStubResponse(NSURLRequest *request) {
            if (stall.boolValue) {
                return (DropboxStubResponse){.hang = YES};
            }
            return DropboxStubJSON(500, @{@"error_summary": @"internal/"});
        } tailGate:nil];
        [self recordAvailabilities];
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
        CloudFileAvailability *availability = [self awaitAvailability];
        XCTAssertTrue([self eventually:^BOOL { return [self tailReads].count == 1; }], @"stall %@", stall);

        dispatch_semaphore_t blocked = dispatch_semaphore_create(0);
        __block CloudFileAvailabilityWait waited = CloudFileAvailabilityFailed;
        __block uint64_t copied = 0;
        uint8_t *buffer = malloc(4096);
        dispatch_semaphore_t returned = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            __block BOOL signalled = NO;
            uint64_t got = 0;
            waited = [availability waitForBytesAt:bytes.length - 128 length:128 windowInto:buffer capacity:4096
                                           copied:&got interrupted:^BOOL{
                if (!signalled) {
                    signalled = YES;
                    dispatch_semaphore_signal(blocked);
                }
                return NO;
            } deadline:nil error:NULL];
            copied = got;
            dispatch_semaphore_signal(returned);
        });
        XCTAssertTrue([self await:blocked]);
        XCTAssertNotEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5)), 0,
                          @"stall %@: the tail waits for the download", stall);
        XCTAssertEqual(availability.windowLength, 0u);
        [self releaseChunks:bytes.length / (256 * 1024) + 1];

        XCTAssertTrue([self await:returned]);
        XCTAssertEqual(waited, CloudFileAvailabilityReady);
        XCTAssertEqual(copied, 0u, @"read from the disk");
        free(buffer);
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertTrue(_fetched, @"stall %@: %@", stall, _fetchError);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes);
        XCTAssertEqual([self tailReads].count, 1u, @"stall %@: one read, never retried", stall);
        [self assertFinishedOnce:availability error:nil];
        [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
            return [self defaultResponseFor:request json:json];
        }];
        os_unfair_lock_lock(&sStubLock);
        [sStubRequests removeAllObjects];
        os_unfair_lock_unlock(&sStubLock);
    }
}

// The tail read goes out beside the download, before its first response, and
// whichever answer lands second installs the window, only when both name one
// rev and the download's size is the listing's: a tail of another version, a
// tail naming none, or an offset taken from a stale listing is dropped and
// the transfer goes on whole.
- (void)testTheTailIsReadBesideTheDownloadAndKeptOnlyForItsVersion {
    typedef NS_ENUM(NSInteger, Case) { TailFirst, DownloadFirst, TailFirstOtherRev, DownloadFirstOtherRev, NoRev, StaleListing };
    NSArray<NSString *> *names = @[@"tail first", @"download first", @"tail first, another rev",
                                   @"download first, another rev", @"no rev on the tail", @"listed at another size"];
    const NSUInteger chunk = 256 * 1024;
    for (Case each = TailFirst; each <= StaleListing; each++) {
        NSString *label = names[each];
        BOOL tailFirst = each == TailFirst || each == TailFirstOtherRev || each == NoRev || each == StaleListing;
        BOOL kept = each == TailFirst || each == DownloadFirst;
        NSData *bytes = PatternBytes(4 * chunk + 1);
        uint64_t listed = each == StaleListing ? bytes.length - 10 : bytes.length;
        NSString *name = [NSString stringWithFormat:@"case%ld.flac", (long)each];
        _chunkGate = dispatch_semaphore_create(0);
        os_unfair_lock_lock(&sStubLock);
        [sStubRequests removeAllObjects];
        os_unfair_lock_unlock(&sStubLock);
        NSURL *track = [self streamingTrack:bytes name:name chunk:chunk];
        if (each == StaleListing) {
            _listings[@"/music"] = @[FileEntry(@"/Music", name, (long long)listed, kStamp)];
            [NSFileManager.defaultManager removeItemAtURL:track error:NULL];
            [self refresh:@"/Music"];
            XCTAssertEqual(StatOf(track).st_size, (off_t)listed);
        }
        dispatch_semaphore_t landed = dispatch_semaphore_create(0);
        ObserveRangedReads(^{
            dispatch_semaphore_signal(landed);
        });
        dispatch_semaphore_t tailGate = dispatch_semaphore_create(0);
        NSDictionary *metadata = @{@"server_modified": kStamp, @"size": @(bytes.length),
                                   @"rev": each == TailFirstOtherRev || each == DownloadFirstOtherRev ? @"0badc0de" : kRev};
        @synchronized (self) {
            _rangeScript = ^DropboxStubResponse(NSURLRequest *request) {
                DropboxStubResponse answer = DownloadAnswer(request, bytes, metadata);
                if (each == NoRev) {
                    answer.headers = @{@"Content-Type": @"application/octet-stream"};
                }
                if (!tailFirst) {
                    answer.chunk = answer.body.length;
                    answer.beforeChunk = ^(NSUInteger index) {
                        dispatch_semaphore_wait(tailGate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
                    };
                }
                return answer;
            };
        }
        // Tail first: the download's response waits until the tail's answer
        // has reached the mirror.
        dispatch_semaphore_t chunkGate = _chunkGate;
        [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
            DropboxStubResponse answer = [self answer:request];
            answer.chunk = chunk;
            answer.beforeChunk = ^(NSUInteger chunkIndex) {
                dispatch_semaphore_wait(chunkGate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            };
            if (tailFirst) {
                answer.beforeResponse = ^{
                    dispatch_semaphore_wait(landed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
                };
            }
            return answer;
        }];
        [self recordAvailabilities];
        XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
        XCTAssertTrue([self eventually:^BOOL { return [self tailReads].count == 1; }], @"%@", label);
        NSURLRequest *tailRead = [self tailReads].firstObject;
        XCTAssertEqualObjects([tailRead valueForHTTPHeaderField:@"Range"],
                              ([NSString stringWithFormat:@"bytes=%llu-%llu", listed - kWindowBytes, listed - 1]), @"%@", label);
        XCTAssertTrue([[tailRead valueForHTTPHeaderField:@"Dropbox-API-Arg"] containsString:
                       [@"id:/music/" stringByAppendingString:name]], @"%@: by the download's id", label);
        CloudFileAvailability *availability = [self awaitAvailability];
        uint64_t windowAtFirstNote = [[self notes].firstObject[3] unsignedLongLongValue];
        if (tailFirst) {
            XCTAssertEqual(windowAtFirstNote, kept ? kWindowBytes : 0u, @"%@: settled as the stream was made", label);
        }
        else {
            XCTAssertEqual(windowAtFirstNote, 0u, @"%@", label);
            dispatch_semaphore_signal(tailGate);
            XCTAssertTrue([self await:landed], @"%@", label);
        }
        XCTAssertEqual(availability.windowLength, kept ? kWindowBytes : 0u, @"%@", label);
        if (kept) {
            uint8_t probe[16];
            uint64_t copied = 0;
            XCTAssertEqual([availability waitForBytesAt:bytes.length - 16 length:16 windowInto:probe capacity:16
                                                 copied:&copied interrupted:^BOOL { return YES; } deadline:nil error:NULL],
                           CloudFileAvailabilityReady, @"%@", label);
            XCTAssertEqual(memcmp(probe, (const uint8_t *)bytes.bytes + bytes.length - 16, 16), 0, @"%@", label);
        }
        [self releaseChunks:5];
        [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
        XCTAssertTrue(_fetched, @"%@: %@", label, _fetchError);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:track], bytes, @"%@", label);
        XCTAssertEqual([self tailReads].count, 1u, @"%@", label);
        [self assertFinishedOnce:availability error:nil];
        ObserveRangedReads(nil);
        @synchronized (self) {
            _rangeScript = nil;
        }
    }
}

// A tag parse of a file streaming now asks Dropbox for none of what the
// stream is about to hold: a head read waits for the download, a trailer read
// is the window's, and any other range takes what is on disk, asking only for
// the rest.
- (void)testATagReadDuringAStreamTakesWhatTheStreamHolds {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = PatternBytes(2 * 1024 * 1024);
    NSURL *track = [self streamingTrack:bytes name:@"tagged.flac" chunk:chunk];
    [self recordAvailabilities];
    XCTestExpectation *fetched = [self fetch:track materializer:[CloudFileMaterializer new] onReadable:nil];
    CloudFileAvailability *availability = [self awaitAvailability];
    XCTAssertTrue([self eventually:^BOOL { return availability.windowLength == kWindowBytes; }]);
    XCTAssertEqual([self tailReads].count, 1u);

    // The parse's first read, 384 KB from the head, waits for the download.
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    __block NSData *head = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        head = [self->_mirror readPlaceholderAtURL:track offset:0 length:6 * chunk error:NULL];
        dispatch_semaphore_signal(returned);
    });
    XCTAssertNotEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5)), 0,
                      @"waiting for the head");
    [self releaseChunks:18];
    XCTAssertTrue([self await:returned]);
    XCTAssertEqualObjects(head, [bytes subdataWithRange:NSMakeRange(0, 6 * chunk)]);
    [self awaitNoted:18 * chunk count:0];
    // Polled: the observer sees a note before it lands, and the reads below take what has.
    XCTAssertTrue([self eventually:^BOOL { return availability.writtenBytes == 18 * chunk; }]);

    NSError *error = nil;
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:bytes.length - 128 length:128 error:&error],
                          [bytes subdataWithRange:NSMakeRange(bytes.length - 128, 128)], @"%@", error);
    XCTAssertEqual([self tailReads].count, 1u, @"head and trailer asked nothing of Dropbox");

    // Past the first MB and the window: the part file's prefix, one request for the rest.
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:17 * chunk length:2 * chunk error:&error],
                          [bytes subdataWithRange:NSMakeRange(17 * chunk, 2 * chunk)], @"%@", error);
    XCTAssertEqual([self tailReads].count, 2u);
    XCTAssertEqualObjects([[self tailReads].lastObject valueForHTTPHeaderField:@"Range"],
                          ([NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)(18 * chunk),
                            (unsigned long)(19 * chunk - 1)]));
    // Nothing of it held: all by range.
    XCTAssertEqualObjects([_mirror readPlaceholderAtURL:track offset:24 * chunk length:chunk error:&error],
                          [bytes subdataWithRange:NSMakeRange(24 * chunk, chunk)], @"%@", error);
    XCTAssertEqual([self tailReads].count, 3u);

    [self releaseChunks:bytes.length / chunk];
    [self waitForExpectations:@[fetched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(_fetched, @"%@", _fetchError);
    [self assertFinishedOnce:availability error:nil];
}

#pragma mark The row's loading bar

// Spins main, which carries the registry's edges and fractions.
- (BOOL)eventually:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow <= 0) {
            return NO;
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
}

- (void)cloudTransferRegistry:(CloudTransferRegistry *)registry didMoveTransferForPath:(NSString *)path {
    @synchronized (self) {
        [_moves addObject:path];
    }
}

// A playback open of a mirrored track through the real coordinator, the
// download held back a chunk at a time; the listing says `listedBytes`, the
// download answers `bytes`.
- (NSURL *)openRowTrack:(NSData *)bytes listed:(long long)listedBytes chunk:(NSUInteger)chunk {
    NSURL *track = [self streamingTrack:bytes name:@"row.wav" chunk:chunk];
    _listings[@"/music"] = @[FileEntry(@"/Music", @"row.wav", listedBytes, kStamp)];
    [self refresh:@"/Music"];
    _coordinator = [[AudioFileMaterializationCoordinator alloc] init];
    _openToken = [_coordinator openURL:track purpose:VibeAudioFileOpenPurposePlayback
                      completionQueue:dispatch_get_main_queue()
                           completion:^(AudioFileHandle *file, NSError *error, NSTimeInterval elapsed) {
        self->_delivered = file;
    }];
    return track;
}

- (NSData *)rowWAV:(NSUInteger)length {
    NSURL *wav = VibeWriteWAV([_root URLByAppendingPathComponent:@"source.wav"], [NSMutableData dataWithLength:length],
                              44100, 2, 16, (uint32_t)length);
    NSData *bytes = [NSData dataWithContentsOfURL:wav];
    [NSFileManager.defaultManager removeItemAtURL:wav error:NULL];
    return bytes;
}

// The row's fraction is the transfer's written bytes over its size, within a
// whole percent and a poll.
- (BOOL)row:(NSURL *)track showsWritten:(uint64_t)written of:(uint64_t)size {
    float wanted = (float)written / (float)size;
    return [self eventually:^BOOL {
        return fabsf([CloudTransferRegistry.sharedRegistry progressForURL:track] - wanted) <= 0.011f;
    }];
}

// The row a stream plays from keeps following its transfer once the player
// has started on it, from the begin, through readable, to the end, and the
// transfer's movement reaches an observer under the row's own path.
- (void)testAStreamsRowFollowsItsTransferFromBeginToEnd {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = [self rowWAV:16 * chunk];
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    _moves = [NSMutableArray array];
    [registry addObserver:self];
    NSURL *track = [self openRowTrack:bytes listed:(long long)bytes.length chunk:chunk];

    XCTAssertTrue([self eventually:^BOOL { return [registry isTransferringURL:track]; }], @"begin, before any byte");
    XCTAssertEqual([registry progressForURL:track], -1);
    [self releaseChunks:2];
    XCTAssertTrue([self row:track showsWritten:2 * chunk of:bytes.length], @"%.3f", [registry progressForURL:track]);
    [self releaseChunks:6];
    XCTAssertTrue([self eventually:^BOOL { return self->_delivered != nil; }], @"readable: the player starts on it");
    XCTAssertTrue([registry isTransferringURL:track], @"and the transfer runs on");
    [self releaseChunks:6];
    XCTAssertTrue([self row:track showsWritten:14 * chunk of:bytes.length],
                  @"the row froze at %.3f after the start", [registry progressForURL:track]);
    @synchronized (self) {
        XCTAssertGreaterThan(_moves.count, 0u);
        XCTAssertEqualObjects(_moves.firstObject, VibeStandardizedAudioOpenPath(track));
    }

    [self releaseChunks:100];
    XCTAssertTrue([self eventually:^BOOL { return ![registry isTransferringURL:track]; }], @"end on complete");
    XCTAssertEqual([registry progressForURL:track], -1);
    [registry removeObserver:self];
}

// A file re-uploaded since its listing downloads at its new size; the row
// counts against that, never the placeholder's.
- (void)testARowCountsAgainstTheSizeBeingDownloaded {
    const NSUInteger chunk = 64 * 1024;
    NSData *bytes = [self rowWAV:16 * chunk];
    NSURL *track = [self openRowTrack:bytes listed:8 * chunk chunk:chunk];
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    XCTAssertTrue([self eventually:^BOOL { return [registry isTransferringURL:track]; }]);
    [self releaseChunks:4];
    XCTAssertTrue([self row:track showsWritten:4 * chunk of:bytes.length],
                  @"%.3f against the listed size", [registry progressForURL:track]);
    [self releaseChunks:100];
    XCTAssertTrue([self eventually:^BOOL { return ![registry isTransferringURL:track]; }]);
}

#pragma mark The account

- (void)testAnExpiredAccessTokenIsRefreshedOnceAndTheCallRetried {
    _listings[@"/a"] = @[FileEntry(@"/A", @"a.flac", 5, kStamp)];
    __block NSInteger listCalls = 0;
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/2/files/list_folder"]) {
            listCalls++;
            if ([[request valueForHTTPHeaderField:@"Authorization"] isEqualToString:@"Bearer A1"]) {
                return DropboxStubJSON(401, @{@"error_summary": @"expired_access_token/",
                                              @"error": @{@".tag": @"expired_access_token"}});
            }
        }
        return [self defaultResponseFor:request json:json];
    }];
    NSURL *folder = [self refresh:@"/A"];
    XCTAssertNotNil(folder);
    XCTAssertEqual(listCalls, 2);
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 2u);
    XCTAssertTrue(_client.isLinked);
}

// The launch's warm-up: with no account (before first unlock reads as none)
// it asks nothing; with one, one refresh and one content-host request per
// session, once, however often it is called.
- (void)testTheWarmUpRunsOnceAndOnlyWithAnAccount {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[DropboxStubProtocol.class];
    DropboxClient *unlinked = [[DropboxClient alloc] initWithAppKey:@"testkey" keychainService:nil
                                                      configuration:configuration];
    [unlinked warmUp];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 0u);
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 0u);

    [_client warmUp];
    XCTAssertTrue([self eventually:^BOOL { return [self requestsToPath:@"/2/files/download"].count == 2; }]);
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 1u);
    for (NSURLRequest *request in [self requestsToPath:@"/2/files/download"]) {
        XCTAssertEqualObjects(request.URL.host, @"content.dropboxapi.com");
        XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Authorization"], @"Bearer A1");
    }
    [_client warmUp];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 2u, @"once a launch");
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 1u);
}

- (void)testConcurrentCallsShareOneRefresh {
    _listings[@"/a"] = @[];
    _listings[@"/b"] = @[];
    XCTestExpectation *both = [self expectationWithDescription:@"both"];
    both.expectedFulfillmentCount = 2;
    for (NSString *path in @[@"/A", @"/B"]) {
        [_mirror refreshDropboxFolder:path completion:^(NSURL *folderURL, NSError *error) {
            XCTAssertNil(error);
            [both fulfill];
        }];
    }
    [self waitForExpectations:@[both] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 1u);
}

- (void)testARevokedGrantUnlinksTheAccount {
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/2/files/list_folder"]) {
            return DropboxStubJSON(401, @{@"error_summary": @"invalid_access_token/",
                                          @"error": @{@".tag": @"invalid_access_token"}});
        }
        return [self defaultResponseFor:request json:json];
    }];
    [self spinMainQueue];
    XCTNSNotificationExpectation *unlinked =
            [[XCTNSNotificationExpectation alloc] initWithName:VibeDropboxAccountDidChangeNotification
                                                        object:_client];
    XCTestExpectation *done = [self expectationWithDescription:@"refresh"];
    [_mirror refreshDropboxFolder:@"/A" completion:^(NSURL *folderURL, NSError *error) {
        XCTAssertNil(folderURL);
        XCTAssertEqualObjects(error.domain, VibeDropboxErrorDomain);
        XCTAssertEqual(error.code, VibeDropboxErrorNotLinked);
        [done fulfill];
    }];
    [self waitForExpectations:@[done, unlinked] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse(_client.isLinked);
    XCTAssertNil(_mirror.accountURL);
}

- (void)testSigningOutWithAnExpiredAccessTokenRefreshesBeforeRevoking {
    __block BOOL expiresAtOnce = YES;
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/oauth2/token"]) {
            return DropboxStubJSON(200, @{@"access_token": expiresAtOnce ? @"A1" : @"A2",
                                          @"expires_in": expiresAtOnce ? @0 : @14400});
        }
        return [self defaultResponseFor:request json:json];
    }];
    _listings[@"/a"] = @[];
    XCTAssertNotNil([self refresh:@"/A"]);
    expiresAtOnce = NO;
    [_client signOut];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:@"/2/auth/token/revoke"].count == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    NSArray<NSURLRequest *> *revokes = [self requestsToPath:@"/2/auth/token/revoke"];
    XCTAssertEqual(revokes.count, 1u);
    XCTAssertEqualObjects([revokes.firstObject valueForHTTPHeaderField:@"Authorization"], @"Bearer A2");
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 2u);
    XCTAssertFalse(_client.isLinked);
}

// An account-name answer that outlives its account names nothing: stamped on
// the next one, the mirror would follow the wrong ID and prune the right cache.
- (void)testALateAccountNameAnswerDoesNotStampTheNextAccount {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/2/users/get_current_account"]) {
            dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)));
            return DropboxStubJSON(200, @{@"account_id": @"dbid:test", @"name": @{@"display_name": @"First"}});
        }
        return [self defaultResponseFor:request json:json];
    }];
    XCTestExpectation *answered = [self expectationWithDescription:@"name"];
    [_client refreshAccountNameWithCompletion:^{ [answered fulfill]; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:@"/2/users/get_current_account"].count == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual([self requestsToPath:@"/2/users/get_current_account"].count, 1u);
    [_client adoptRefreshToken:@"R2" accountID:@"dbid:second"];
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[answered] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(_client.accountID, @"dbid:second");
    XCTAssertNil(_client.accountName);
}

- (void)testARefusedRefreshTokenUnlinksTheAccount {
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/oauth2/token"]) {
            return DropboxStubJSON(400, @{@"error": @"invalid_grant"});
        }
        return [self defaultResponseFor:request json:json];
    }];
    XCTestExpectation *done = [self expectationWithDescription:@"refresh"];
    [_mirror refreshDropboxFolder:@"/A" completion:^(NSURL *folderURL, NSError *error) {
        XCTAssertEqual(error.code, VibeDropboxErrorNotLinked);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse(_client.isLinked);
}

@end
