//
//  DropboxMirrorTests.m
//
//  The real client and mirror over a stubbed HTTP boundary (an NSURLProtocol
//  in the session's configuration) and a per-test temp root: listing
//  reconciliation, the placeholder-to-bytes fetch through
//  CloudFileMaterializer, its cancellation, the token refresh and the unlink.
//

#import <XCTest/XCTest.h>

#include <os/lock.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/time.h>

#import "CloudFileMaterializer.h"
#import "DropboxClientInternal.h"
#import "DropboxMirror.h"
#import "NSURLUtil.h"

#pragma mark - The stub

// A response: status, headers, body; or hang until the task is cancelled.
typedef struct {
    NSInteger status;
    NSDictionary<NSString *, NSString *> *_Nullable headers;
    NSData *_Nullable body;
    BOOL hang;
} DropboxStubResponse;

typedef DropboxStubResponse (^DropboxStubHandler)(NSURLRequest *request, NSDictionary *_Nullable json);

static os_unfair_lock sStubLock = OS_UNFAIR_LOCK_INIT;
static DropboxStubHandler sStubHandler;
static NSMutableArray<NSURLRequest *> *sStubRequests;

static DropboxStubResponse DropboxStubJSON(NSInteger status, id object) {
    return (DropboxStubResponse){status, @{@"Content-Type": @"application/json"},
            [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL], NO};
}

@interface DropboxStubProtocol : NSURLProtocol
@end

@implementation DropboxStubProtocol

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
    [sStubRequests addObject:self.request];
    os_unfair_lock_unlock(&sStubLock);
    DropboxStubResponse response = handler(self.request, [json isKindOfClass:NSDictionary.class] ? json : nil);
    if (response.hang) {
        return;
    }
    NSHTTPURLResponse *http = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                          statusCode:response.status
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:response.headers];
    [self.client URLProtocol:self didReceiveResponse:http cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (response.body) {
        [self.client URLProtocol:self didLoadData:response.body];
    }
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

#pragma mark - Tests

static NSString *const kStamp = @"2020-01-02T03:04:05Z";
static const time_t kStampSeconds = 1577934245;

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

@interface DropboxMirrorTests : XCTestCase
@end

@implementation DropboxMirrorTests {
    NSURL *_root;
    DropboxClient *_client;
    DropboxMirror *_mirror;
    // Path → entries the stub's list_folder answers.
    NSMutableDictionary<NSString *, NSArray *> *_listings;
    // Dropbox path → bytes the stub's files/download answers.
    NSMutableDictionary<NSString *, NSData *> *_contents;
    NSInteger _tokenRequests;
    // What the stub's files/search_v2 answers.
    NSArray<NSDictionary *> *_searchEntries;
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
    _mirror = [[DropboxMirror alloc] initWithClient:_client rootURL:_root downloadBudget:8];
    [_client adoptRefreshToken:@"R1" accountID:@"dbid:test"];
}

- (void)tearDown {
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil];
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
        NSString *range = [request valueForHTTPHeaderField:@"Range"];
        if (range) {
            unsigned long long first = 0, last = 0;
            sscanf(range.UTF8String, "bytes=%llu-%llu", &first, &last);
            last = MIN(last, (unsigned long long)bytes.length - 1);
            NSData *slice = [bytes subdataWithRange:NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1))];
            return (DropboxStubResponse){206, @{}, slice, NO};
        }
        NSDictionary *metadata = @{@"server_modified": kStamp, @"size": @(bytes.length)};
        NSString *result = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metadata
                                                                                          options:0 error:NULL]
                                                 encoding:NSUTF8StringEncoding];
        return (DropboxStubResponse){200, @{@"Dropbox-API-Result": result}, bytes, NO};
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
    [CloudFileMaterializer setRemoteRoot:_root fetch:^BOOL(NSURL *url, void (^onCancel)(dispatch_block_t), NSError **error) {
        return [mirror fetchPlaceholderAtURL:url onCancel:onCancel error:error];
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        return [mirror readPlaceholderAtURL:url offset:offset length:length error:error];
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
    XCTAssertTrue([materializer materializeURL:track token:[materializer prepareMaterialization] error:&error]);
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
    return [materializer materializeURL:url token:[materializer prepareMaterialization] error:NULL];
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
                                         completion:^(NSData *data, NSError *error) {
        XCTAssertNil(data);
        XCTAssertEqual(error.code, VibeDropboxErrorCancelled);
        [read fulfill];
    }];
    XCTestExpectation *download = [self expectationWithDescription:@"download"];
    dispatch_block_t cancelDownload = [_client downloadPath:@"/Music/a.flac"
                                                      toURL:[_root URLByAppendingPathComponent:@"a.part"]
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
        materialized = [materializer materializeURL:track token:token error:&error];
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
