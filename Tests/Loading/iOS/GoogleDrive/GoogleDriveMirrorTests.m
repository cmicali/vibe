//
//  GoogleDriveMirrorTests.m
//
//  The real GoogleDriveClient and GoogleDriveMirror over DropboxStubProtocol
//  and a per-test temp root: listing, names, versions, the download's
//  lookup, search, and the account.
//

#import "DropboxMirrorTestCase.h"
#import "GoogleDriveClient.h"
#import "GoogleDriveMirror.h"
#import "GoogleDriveRules.h"
#import "OAuthAccountClientInternal.h"
#import "VibeFakeHTTPProtocol.h"

static NSString *const kDriveStamp = @"2020-01-02T03:04:05.000Z";
static const time_t kDriveStampSeconds = 1577934245;
static NSString *const kRootFolderID = @"ROOTID";

static NSDictionary *DriveFile(NSString *identifier, NSString *name, NSString *parent, long long size,
                               NSString *version) {
    return @{@"id": identifier, @"name": name, @"mimeType": @"audio/flac", @"size": @(size).stringValue,
             @"modifiedTime": kDriveStamp, @"md5Checksum": version, @"parents": @[parent]};
}

static NSDictionary *DriveFolder(NSString *identifier, NSString *name, NSString *parent) {
    return @{@"id": identifier, @"name": name, @"mimeType": VIBE_GOOGLE_DRIVE_FOLDER_TYPE, @"parents": @[parent]};
}

static struct stat DriveStat(NSURL *url) {
    struct stat st = {0};
    lstat(url.fileSystemRepresentation, &st);
    return st;
}

static NSDictionary<NSString *, NSString *> *DriveQuery(NSURLRequest *request) {
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO].queryItems) {
        query[item.name] = item.value ?: @"";
    }
    return query;
}

// files.get?alt=media as Drive answers it, by the debug fake's Range rule:
// with its length, whole or from a Range's first byte.
static DropboxStubResponse DriveMedia(NSURLRequest *request, NSData *bytes) {
    NSMutableDictionary<NSString *, NSString *> *headers = [@{@"Content-Type": @"application/octet-stream"} mutableCopy];
    uint64_t first = 0, length = 0;
    NSInteger status = VibeFakeHTTPRangeStatus([request valueForHTTPHeaderField:@"Range"], bytes.length,
                                               headers, &first, &length);
    return (DropboxStubResponse){status, headers,
                                 [bytes subdataWithRange:NSMakeRange((NSUInteger)first, (NSUInteger)length)], NO};
}

@interface GoogleDriveMirrorTests : XCTestCase
@end

@implementation GoogleDriveMirrorTests {
    NSURL *_root;
    GoogleDriveClient *_client;
    GoogleDriveMirror *_mirror;
    // Folder id → the entries its listing answers.
    NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *_children;
    // File or folder id → what files.get answers, over the listing's entry.
    NSMutableDictionary<NSString *, NSDictionary *> *_items;
    // File id → its bytes.
    NSMutableDictionary<NSString *, NSData *> *_contents;
    NSInteger _tokenRequests;
}

- (void)setUp {
    [super setUp];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"GoogleDriveMirrorTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _root = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    _children = [NSMutableDictionary dictionary];
    _items = [NSMutableDictionary dictionary];
    _contents = [NSMutableDictionary dictionary];

    DropboxStubClearRequests();
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        return [self defaultResponseFor:request];
    }];

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[DropboxStubProtocol.class];
    _client = [[GoogleDriveClient alloc] initWithClientID:@"123-abc.apps.googleusercontent.com"
                                          keychainService:nil
                                            configuration:configuration];
    _client.retryDelayScale = 0.01;
    _mirror = [[GoogleDriveMirror alloc] initWithClient:_client rootURL:_root downloadBudget:1000];
    _mirror.streamedTagWait = VIBE_TEST_GATE_TIMEOUT;
    [_client adoptRefreshToken:@"R1" accountID:@"perm"];
}

- (void)tearDown {
    [self installHandler:nil];
    [self spinMainQueue];
    [NSFileManager.defaultManager removeItemAtURL:_root error:NULL];
    [super tearDown];
}

#pragma mark - The harness

- (void)spinMainQueue {
    XCTestExpectation *spun = [self expectationWithDescription:@"main"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [spun fulfill];
    });
    [self waitForExpectations:@[spun] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)installHandler:(DropboxStubHandler)handler {
    DropboxStubInstall(handler);
}

- (NSArray<NSURLRequest *> *)requestsToPath:(NSString *)path {
    return DropboxStubRequestsToPath(path);
}

// The lookups and media requests of one file, apart.
- (NSArray<NSURLRequest *> *)requestsToFile:(NSString *)identifier media:(BOOL)media {
    return [[self requestsToPath:[@"/drive/v3/files/" stringByAppendingString:identifier]] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        return [DriveQuery(request)[@"alt"] isEqualToString:@"media"] == media;
    }]];
}

- (DropboxStubResponse)defaultResponseFor:(NSURLRequest *)request {
    NSString *path = request.URL.path;
    NSDictionary<NSString *, NSString *> *query = DriveQuery(request);
    if ([path isEqualToString:@"/token"]) {
        @synchronized (self) {
            _tokenRequests++;
            return DropboxStubJSON(200, @{@"access_token": [NSString stringWithFormat:@"A%ld", (long)_tokenRequests],
                                         @"expires_in": @3599});
        }
    }
    if ([path isEqualToString:@"/revoke"]) {
        return DropboxStubJSON(200, @{});
    }
    if ([path isEqualToString:@"/drive/v3/about"]) {
        return DropboxStubJSON(200, @{@"user": @{@"permissionId": @"perm", @"emailAddress": @"me@example.com",
                                                 @"displayName": @"Me"}});
    }
    if ([path isEqualToString:@"/drive/v3/files"]) {
        NSString *q = query[@"q"];
        NSRange quote = [q rangeOfString:@"' in parents"];
        if ([q hasPrefix:@"'"] && quote.location != NSNotFound) {
            NSString *folder = [q substringWithRange:NSMakeRange(1, quote.location - 1)];
            NSArray *entries = _children[folder];
            if (!entries) {
                return DropboxStubJSON(404, @{@"error": @{@"code": @404, @"message": @"File not found"}});
            }
            return DropboxStubJSON(200, @{@"files": entries, @"incompleteSearch": @NO});
        }
        return DropboxStubJSON(200, @{@"files": @[]});
    }
    if ([path hasPrefix:@"/drive/v3/files/"]) {
        NSString *identifier = [path substringFromIndex:@"/drive/v3/files/".length];
        if ([query[@"alt"] isEqualToString:@"media"]) {
            NSData *bytes = _contents[identifier];
            return bytes ? DriveMedia(request, bytes)
                         : DropboxStubJSON(404, @{@"error": @{@"code": @404, @"message": @"File not found"}});
        }
        if ([identifier isEqualToString:@"root"]) {
            return DropboxStubJSON(200, @{@"id": kRootFolderID});
        }
        NSDictionary *item = _items[identifier];
        for (NSArray<NSDictionary *> *entries in _children.allValues) {
            for (NSDictionary *entry in entries) {
                if (!item && [entry[@"id"] isEqual:identifier]) {
                    item = entry;
                }
            }
        }
        return item ? DropboxStubJSON(200, item)
                    : DropboxStubJSON(404, @{@"error": @{@"code": @404, @"message": @"File not found"}});
    }
    return DropboxStubJSON(400, @{@"error": @{@"code": @400, @"message": @"unexpected"}});
}

- (NSURL *)refreshURL:(NSURL *)url {
    XCTestExpectation *done = [self expectationWithDescription:url.path];
    __block NSURL *folder = nil;
    [_mirror refreshDirectoryAtURL:url completion:^(NSURL *folderURL, NSError *error) {
        XCTAssertNil(error);
        folder = folderURL;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    return folder;
}

- (NSError *)failedRefreshOfURL:(NSURL *)url {
    XCTestExpectation *done = [self expectationWithDescription:url.path];
    __block NSError *failure = nil;
    [_mirror refreshDirectoryAtURL:url completion:^(NSURL *folderURL, NSError *error) {
        XCTAssertNil(folderURL);
        failure = error;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    return failure;
}

- (NSError *)fetch:(NSURL *)url {
    NSError *error = nil;
    [_mirror fetchPlaceholderAtURL:url onReadable:nil onCancel:^(dispatch_block_t cancel) {} error:&error];
    return error;
}

#pragma mark Listing

- (void)testAListingWritesPlaceholdersAndRecordsEachID {
    _children[@"root"] = @[DriveFolder(@"F1", @"Music", @"root"),
                           DriveFile(@"A1", @"a.flac", @"root", 5, @"m1"),
                           @{@"id": @"J1", @"name": @"cover.jpg", @"size": @"9", @"parents": @[@"root"]},
                           @{@"id": @"D1", @"name": @"Notes", @"mimeType": @"application/vnd.google-apps.document"}];
    NSURL *account = [self refreshURL:_mirror.accountURL];
    XCTAssertEqualObjects(account.path, _mirror.accountURL.path);
    NSURL *music = [account URLByAppendingPathComponent:@"Music" isDirectory:YES];
    NSURL *track = [account URLByAppendingPathComponent:@"a.flac"];
    XCTAssertEqualObjects([_mirror folderIDForURL:music], @"F1");
    XCTAssertEqualObjects([_mirror folderIDForURL:account], @"root");
    struct stat st = DriveStat(track);
    XCTAssertEqual(st.st_size, 5);
    XCTAssertEqual(st.st_mtimespec.tv_sec, kDriveStampSeconds);
    XCTAssertEqual(st.st_mode & 0777, 0, @"a placeholder");
    XCTAssertEqualObjects([_mirror identityOfURL:track], @"A1");
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[account URLByAppendingPathComponent:@"cover.jpg"].path]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[account URLByAppendingPathComponent:@"Notes"].path]);
    XCTAssertTrue([_mirror hasListedDirectory:account]);
    XCTAssertFalse([_mirror hasListedDirectory:music], @"made by its parent's listing, not listed itself");
    XCTAssertTrue([_mirror isAccountRootURL:account]);
    XCTAssertTrue([_mirror isMirroredURL:track]);
}

// GoogleDriveRules.h: a listing's order never moves a copy suffix.
- (void)testDuplicateNamesKeepTheirSlotsAcrossListings {
    NSDictionary *b = DriveFile(@"B", @"Song.flac", @"root", 5, @"mb");
    NSDictionary *a = DriveFile(@"A", @"Song.flac", @"root", 6, @"ma");
    _children[@"root"] = @[b, a];
    NSURL *account = [self refreshURL:_mirror.accountURL];
    NSURL *plain = [account URLByAppendingPathComponent:@"Song.flac"];
    NSURL *copy = [account URLByAppendingPathComponent:@"Song (2).flac"];
    XCTAssertEqualObjects([_mirror identityOfURL:plain], @"A");
    XCTAssertEqualObjects([_mirror identityOfURL:copy], @"B");
    XCTAssertEqual(DriveStat(plain).st_size, 6);
    XCTAssertEqual(DriveStat(copy).st_size, 5);

    _children[@"root"] = @[a, b];
    [self refreshURL:account];
    XCTAssertEqualObjects([_mirror identityOfURL:plain], @"A");
    XCTAssertEqualObjects([_mirror identityOfURL:copy], @"B");
    NSError *error = nil;
    XCTAssertEqualObjects([_mirror remoteTargetForURL:copy error:&error], @"B");
}

// The version decides, never the date: a client kept the date across an
// upload of the same size, and the cache key must still move.
- (void)testANewVersionWhoseDateDidNotMoveIsDatedPastTheOld {
    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m1")];
    NSURL *account = [self refreshURL:_mirror.accountURL];
    NSURL *track = [account URLByAppendingPathComponent:@"a.flac"];
    XCTAssertEqual(DriveStat(track).st_mtimespec.tv_sec, kDriveStampSeconds);

    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m2")];
    [self refreshURL:account];
    XCTAssertEqual(DriveStat(track).st_mtimespec.tv_sec, kDriveStampSeconds + 1);
    [self refreshURL:account];
    XCTAssertEqual(DriveStat(track).st_mtimespec.tv_sec, kDriveStampSeconds + 1, @"an unchanged version stays");
}

// A playlist naming another folder, or a restored bookmark, reaches a folder
// no listing made: its parent is listed first.
- (void)testAFolderNoListingMadeIsReachedThroughItsParent {
    _children[@"root"] = @[DriveFolder(@"F1", @"Music", @"root")];
    _children[@"F1"] = @[DriveFile(@"A1", @"a.flac", @"F1", 5, @"m1")];
    NSURL *music = [_mirror.accountURL URLByAppendingPathComponent:@"Music" isDirectory:YES];
    XCTAssertNotNil([self refreshURL:music]);
    XCTAssertEqual(DriveStat([music URLByAppendingPathComponent:@"a.flac"]).st_size, 5);
    XCTAssertEqual([self requestsToPath:@"/drive/v3/files"].count, 2u, @"the root, then Music");

    NSURL *missing = [_mirror.accountURL URLByAppendingPathComponent:@"Gone" isDirectory:YES];
    XCTAssertEqual([self failedRefreshOfURL:missing].code, VibeAccountErrorAPI);
}

- (void)testAListingFollowsEveryPageToken {
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/drive/v3/files"]) {
            NSString *token = DriveQuery(request)[@"pageToken"];
            if (!token) {
                return DropboxStubJSON(200, @{@"files": @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m1")],
                                              @"nextPageToken": @"p2"});
            }
            if ([token isEqualToString:@"p2"]) {
                return DropboxStubJSON(200, @{@"files": @[], @"nextPageToken": @"p3"});
            }
            return DropboxStubJSON(200, @{@"files": @[DriveFile(@"B1", @"b.flac", @"root", 5, @"m2")]});
        }
        return [self defaultResponseFor:request];
    }];
    NSURL *account = [self refreshURL:_mirror.accountURL];
    XCTAssertEqual(DriveStat([account URLByAppendingPathComponent:@"a.flac"]).st_size, 5);
    XCTAssertEqual(DriveStat([account URLByAppendingPathComponent:@"b.flac"]).st_size, 5, @"past an empty page");
    XCTAssertEqual([self requestsToPath:@"/drive/v3/files"].count, 3u);
}

- (void)testAnIncompleteListingDeletesNothing {
    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m1")];
    NSURL *account = [self refreshURL:_mirror.accountURL];
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/drive/v3/files"]) {
            return DropboxStubJSON(200, @{@"files": @[], @"incompleteSearch": @YES});
        }
        return [self defaultResponseFor:request];
    }];
    XCTAssertEqual([self failedRefreshOfURL:account].code, VibeAccountErrorAPI);
    XCTAssertEqual(DriveStat([account URLByAppendingPathComponent:@"a.flac"]).st_size, 5);
}

#pragma mark The download

- (void)testADownloadIsLookedUpFirstAndKeepsItsKey {
    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m1")];
    _contents[@"A1"] = [@"ABCDE" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *track = [[self refreshURL:_mirror.accountURL] URLByAppendingPathComponent:@"a.flac"];
    XCTAssertNil([self fetch:track]);
    XCTAssertEqualObjects([NSString stringWithContentsOfURL:track encoding:NSUTF8StringEncoding error:NULL], @"ABCDE");
    struct stat st = DriveStat(track);
    XCTAssertEqual(st.st_mode & 0777, 0644);
    XCTAssertEqual(st.st_mtimespec.tv_sec, kDriveStampSeconds, @"the same version keeps the cache key");

    NSArray<NSURLRequest *> *lookups = [self requestsToFile:@"A1" media:NO];
    NSArray<NSURLRequest *> *media = [self requestsToFile:@"A1" media:YES];
    XCTAssertEqual(lookups.count, 1u);
    XCTAssertEqual(media.count, 1u);
    XCTAssertTrue([DriveQuery(lookups.firstObject)[@"fields"] containsString:@"md5Checksum"]);
    XCTAssertEqualObjects([media.firstObject valueForHTTPHeaderField:@"Accept-Encoding"], @"identity");
    XCTAssertTrue([[media.firstObject valueForHTTPHeaderField:@"Authorization"] hasPrefix:@"Bearer A"]);
}

// Re-uploaded since the listing, with its date kept: the bytes take a new
// stamp and their version, so nothing cached for the old bytes is served and
// the next listing keeps them.
- (void)testADownloadOfANewerVersionTakesANewStamp {
    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m1")];
    _contents[@"A1"] = [@"VWXYZ" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *track = [[self refreshURL:_mirror.accountURL] URLByAppendingPathComponent:@"a.flac"];
    _items[@"A1"] = DriveFile(@"A1", @"a.flac", @"root", 5, @"m2");
    XCTAssertNil([self fetch:track]);
    XCTAssertEqual(DriveStat(track).st_mtimespec.tv_sec, kDriveStampSeconds + 1);

    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m2")];
    [self refreshURL:_mirror.accountURL];
    XCTAssertEqual(DriveStat(track).st_mode & 0777, 0644, @"still the download");
    XCTAssertEqual(DriveStat(track).st_mtimespec.tv_sec, kDriveStampSeconds + 1);
}

// GoogleDriveClient.h: a resend looks the file up again, and bytes of
// another version never continue the first's.
- (void)testAResendLooksAgainAndRefusesAnotherVersion {
    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m1")];
    _contents[@"A1"] = [@"ABCDE" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *track = [[self refreshURL:_mirror.accountURL] URLByAppendingPathComponent:@"a.flac"];
    NSURL *part = [PlaceholderFiles remotePlaceholderPartURL:track];
    __block NSInteger lookups = 0;
    __block NSInteger downloads = 0;
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/drive/v3/files/A1"]) {
            if ([DriveQuery(request)[@"alt"] isEqualToString:@"media"]) {
                NSInteger index;
                @synchronized (self) {
                    index = downloads++;
                }
                DropboxStubResponse answer = DriveMedia(request, self->_contents[@"A1"]);
                return index == 0 ? VibeDropped(answer, request, 2, part) : answer;
            }
            NSInteger index;
            @synchronized (self) {
                index = lookups++;
            }
            return DropboxStubJSON(200, DriveFile(@"A1", @"a.flac", @"root", 5, index == 0 ? @"m1" : @"m2"));
        }
        return [self defaultResponseFor:request];
    }];
    NSError *error = [self fetch:track];
    XCTAssertEqualObjects(error.domain, VibeAccountErrorDomain);
    XCTAssertEqual(error.code, VibeAccountErrorFileChanged);
    XCTAssertEqual(lookups, 2, @"the resend looked again");
    XCTAssertEqual(DriveStat(track).st_mode & 0777, 0, @"still the placeholder");
}

#pragma mark Search

- (void)testSearchPlacesItsHitsAndLeavesOutWhatIsNotInMyDrive {
    _items[@"F2"] = DriveFolder(@"F2", @"Album", @"F1");
    _items[@"F1"] = DriveFolder(@"F1", @"Music", kRootFolderID);
    _items[@"X"] = @{@"id": @"X", @"name": @"Shared", @"mimeType": VIBE_GOOGLE_DRIVE_FOLDER_TYPE};
    NSDictionary *hit = DriveFile(@"S1", @"hit.flac", @"F2", 5, @"m1");
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/drive/v3/files"]
                && [DriveQuery(request)[@"q"] hasPrefix:@"name contains 'hit'"]) {
            return DropboxStubJSON(200, @{@"files": @[
                hit,
                @{@"id": @"S2", @"name": @"shared hit.flac", @"size": @"5"},
                DriveFile(@"S3", @"orphan hit.flac", @"X", 5, @"m3"),
                @{@"id": @"S4", @"name": @"hit.jpg", @"size": @"5", @"parents": @[@"F2"]},
            ]});
        }
        return [self defaultResponseFor:request];
    }];
    XCTestExpectation *searched = [self expectationWithDescription:@"search"];
    __block NSArray<NSDictionary *> *entries = nil;
    [_mirror searchQuery:@"hit" completion:^(NSArray<NSDictionary *> *found, NSError *error) {
        XCTAssertNil(error);
        entries = found;
        [searched fulfill];
    }];
    [self waitForExpectations:@[searched] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects([entries valueForKey:@"id"], @[@"S1"]);
    XCTAssertEqualObjects([_mirror parentNameOfEntry:entries.firstObject], @"Album");
    XCTAssertEqualObjects([entries.firstObject[@"ancestry"] valueForKey:@"id"], (@[@"F1", @"F2"]));
    XCTAssertEqual([self requestsToPath:@"/drive/v3/files/F2"].count, 1u, @"each folder looked up once");

    _children[@"F2"] = @[hit];
    XCTestExpectation *placed = [self expectationWithDescription:@"place"];
    __block NSURL *local = nil;
    [_mirror localURLForEntry:entries.firstObject completion:^(NSURL *url, NSError *error) {
        XCTAssertNil(error);
        local = url;
        [placed fulfill];
    }];
    [self waitForExpectations:@[placed] timeout:VIBE_TEST_HANG_TIMEOUT];
    NSURL *expected = [_mirror.accountURL URLByAppendingPathComponent:@"Music/Album/hit.flac"];
    XCTAssertEqualObjects(local.path, expected.path);
    XCTAssertEqual(DriveStat(local).st_size, 5);
    XCTAssertEqualObjects([_mirror folderIDForURL:local.URLByDeletingLastPathComponent], @"F2");
    XCTAssertEqualObjects([_mirror folderIDForURL:local.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent], @"F1");
    XCTAssertEqual([self requestsToPath:@"/drive/v3/files"].count, 2u, @"the search, then Album alone");

    // Music's own listing later keeps the folder the hit made.
    _children[@"root"] = @[DriveFolder(@"F1", @"Music", @"root")];
    _children[@"F1"] = @[DriveFolder(@"F2", @"Album", @"F1")];
    [self refreshURL:_mirror.accountURL];
    [self refreshURL:[_mirror.accountURL URLByAppendingPathComponent:@"Music" isDirectory:YES]];
    XCTAssertEqual(DriveStat(local).st_size, 5);
}

#pragma mark The account

- (void)testTheIdentityNamesTheAccountByItsPermissionID {
    XCTestExpectation *named = [self expectationWithDescription:@"name"];
    [_client refreshAccountNameWithCompletion:^{
        [named fulfill];
    }];
    [self waitForExpectations:@[named] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(_client.accountName, @"me@example.com");
    XCTAssertEqualObjects(_client.accountID, @"perm");
    NSURLRequest *about = [self requestsToPath:@"/drive/v3/about"].firstObject;
    XCTAssertTrue([DriveQuery(about)[@"fields"] containsString:@"permissionId"]);
}

- (void)testA401RefreshesOnceThenUnlinks {
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/drive/v3/files"]) {
            return DropboxStubJSON(401, @{@"error": @{@"code": @401, @"message": @"Invalid Credentials",
                                                      @"errors": @[@{@"reason": @"authError"}]}});
        }
        return [self defaultResponseFor:request];
    }];
    [self spinMainQueue];
    XCTNSNotificationExpectation *unlinked =
            [[XCTNSNotificationExpectation alloc] initWithName:VibeAccountDidChangeNotification object:_client];
    NSURL *account = _mirror.accountURL;
    NSError *error = [self failedRefreshOfURL:account];
    [self waitForExpectations:@[unlinked] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(error.code, VibeAccountErrorNotLinked);
    XCTAssertEqual([self requestsToPath:@"/drive/v3/files"].count, 2u);
    XCTAssertEqual([self requestsToPath:@"/token"].count, 2u, @"one refresh after the first refusal");
    XCTAssertFalse(_client.isLinked);
}

- (void)testARateLimitIsWaitedOutAndResent {
    __block NSInteger lists = 0;
    _children[@"root"] = @[];
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/drive/v3/files"] && lists++ == 0) {
            return DropboxStubJSON(403, @{@"error": @{@"code": @403, @"message": @"Rate Limit Exceeded",
                                                      @"errors": @[@{@"reason": @"rateLimitExceeded"}]}});
        }
        return [self defaultResponseFor:request];
    }];
    XCTAssertNotNil([self refreshURL:_mirror.accountURL]);
    XCTAssertEqual(lists, 2);
    XCTAssertTrue(_client.isLinked);
}

- (void)testAForbiddenFileIsAFailureNotAnUnlink {
    _children[@"root"] = @[DriveFile(@"A1", @"a.flac", @"root", 5, @"m1")];
    NSURL *track = [[self refreshURL:_mirror.accountURL] URLByAppendingPathComponent:@"a.flac"];
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([DriveQuery(request)[@"alt"] isEqualToString:@"media"]) {
            return DropboxStubJSON(403, @{@"error": @{@"code": @403, @"message": @"The user cannot download.",
                                                      @"errors": @[@{@"reason": @"cannotDownloadFile"}]}});
        }
        return [self defaultResponseFor:request];
    }];
    NSError *error = [self fetch:track];
    XCTAssertEqual(error.code, VibeAccountErrorAPI);
    XCTAssertTrue([error.localizedDescription containsString:@"cannotDownloadFile"]);
    XCTAssertTrue(_client.isLinked);
}

- (void)testSigningOutRevokesTheRefreshToken {
    [_client signOut];
    XCTAssertFalse(_client.isLinked);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:@"/revoke"].count == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    NSURLRequest *revoke = [self requestsToPath:@"/revoke"].firstObject;
    XCTAssertEqualObjects(revoke.HTTPMethod, @"POST");
    XCTAssertEqualObjects([revoke valueForHTTPHeaderField:@"Content-Type"], @"application/x-www-form-urlencoded");
    XCTAssertEqual([self requestsToPath:@"/token"].count, 0u, @"no access token needed");
}

@end
