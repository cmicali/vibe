//
//  DropboxMirrorTests.m
//
//  The real client and mirror over the stub: listing reconciliation, search,
//  ranged reads, the token refresh and the unlink.
//

#import "DropboxMirrorTestCase.h"

@interface DropboxMirrorTests : DropboxMirrorTestCase
@end

@implementation DropboxMirrorTests

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

    [NSURLUtil setRemotePlaceholderRoots:@[_root]];
    XCTAssertTrue([NSURLUtil isDatalessFile:[folder URLByAppendingPathComponent:@"01 Song.flac"]]);
    XCTAssertFalse([NSURLUtil isDatalessFile:[folder URLByAppendingPathComponent:@"Album.cue"]]);
    [NSURLUtil setRemotePlaceholderRoots:@[]];
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
    [self waitForRequests:1 toPath:@"/2/files/download"];
    // The first download is held; the second refresh lists and reconciles
    // under it. The short wait is the negative check's: time for a second
    // download to have been asked for, had one been coming.
    [_mirror refreshDropboxFolder:@"/Music/Album" completion:refreshed];
    [self waitForRequests:2 toPath:@"/2/files/list_folder"];
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
// A folder that leaves Dropbox and comes back is made empty here: it must
// not still read as listed, or an open of it would skip the listing.
- (void)testAFolderThatComesBackIsNotStillListed {
    _listings[@"/a"] = @[FolderEntry(@"/A", @"X")];
    _listings[@"/a/x"] = @[FileEntry(@"/A/X", @"a.flac", 5, kStamp)];
    [self refresh:@"/A"];
    NSURL *folder = [self refresh:@"/A/X"];
    XCTAssertTrue([_mirror hasListedDirectory:folder]);

    _listings[@"/a"] = @[];
    [self refresh:@"/A"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:folder.path]);

    _listings[@"/a"] = @[FolderEntry(@"/A", @"X")];
    [self refresh:@"/A"];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:folder.path]);
    XCTAssertFalse([_mirror hasListedDirectory:folder]);
}

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
    [self waitForRequests:1 toPath:@"/2/auth/token/revoke"];
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
            DropboxStubResponse response = DropboxStubJSON(200, @{@"account_id": @"dbid:test",
                                                                  @"name": @{@"display_name": @"First"}});
            response.gate = gate;
            return response;
        }
        return [self defaultResponseFor:request json:json];
    }];
    XCTestExpectation *answered = [self expectationWithDescription:@"name"];
    [_client refreshAccountNameWithCompletion:^{ [answered fulfill]; }];
    [self waitForRequests:1 toPath:@"/2/users/get_current_account"];
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
