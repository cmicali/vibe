//
//  DropboxMirrorFetchTests.m
//
//  The placeholder-to-bytes fetch through CloudFileMaterializer, the
//  download budget, cancellation, and a download resumed in place.
//

#import "DropboxMirrorTestCase.h"

@interface DropboxMirrorFetchTests : DropboxMirrorTestCase
@end

@implementation DropboxMirrorFetchTests

#pragma mark Fetch

- (void)testMaterializingAPlaceholderDownloadsItsBytesInPlace {
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"Café.flac", 5, kStamp)];
    _contents[@"/music/café.flac"] = [@"BYTES" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *track = [[self refresh:@"/Music"] URLByAppendingPathComponent:@"Café.flac"];
    [self installMirrorFetch];
    XCTAssertTrue([PlaceholderFiles isDatalessFile:track]);

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    NSError *error = nil;
    XCTAssertTrue([materializer materializeURL:track token:[materializer prepareMaterialization] onReadable:nil error:&error]);
    XCTAssertNil(error);

    XCTAssertEqualObjects([NSString stringWithContentsOfURL:track encoding:NSUTF8StringEncoding error:NULL], @"BYTES");
    struct stat st = StatOf(track);
    XCTAssertEqual(st.st_mode & 0777, 0644);
    XCTAssertEqual(st.st_mtimespec.tv_sec, kStampSeconds);
    XCTAssertFalse([PlaceholderFiles isDatalessFile:track]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[PlaceholderFiles remotePlaceholderPartURL:track].path]);

    // By the listed id, composed as Dropbox sent it, though the URL's own
    // path comes back decomposed.
    NSURLRequest *download = [self requestsToPath:@"/2/files/download"].lastObject;
    NSString *argument = [download valueForHTTPHeaderField:@"Dropbox-API-Arg"];
    XCTAssertTrue([argument containsString:@"id:/music/caf\\u00e9.flac"], @"%@", argument);
}

// VibeDropboxIndexKey, for a folder: listed by its URL, it is asked
// for by the path its parent's listing recorded, not its decomposed name.
- (void)testAFolderWithAnAccentIsRelistedByItsRecordedPath {
    _listings[@"/music"] = @[VibeFolderEntry(@"/Music", @"Café")];
    _listings[@"/music/café"] = @[VibeFileEntry(@"/Music/Café", @"a.flac", 1, kStamp)];
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

- (BOOL)materialize:(NSURL *)url {
    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    return [materializer materializeURL:url token:[materializer prepareMaterialization] onReadable:nil error:NULL];
}

// The budget is 8 bytes here: the second 5-byte download pushes the first
// back to a placeholder, with the size and mtime its cache key was made from.
- (void)testDownloadsPastTheBudgetGoBackToPlaceholdersOldestFirst {
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"one.flac", 5, kStamp),
                             VibeFileEntry(@"/Music", @"two.flac", 5, kStamp)];
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

// A smaller budget applies at once, not at the next download: the oldest go
// back to placeholders until the rest fit, and the new total is posted for
// the settings screen.
- (void)testASmallerBudgetSendsTheOldestBackAtOnceAndPostsTheTotal {
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"one.flac", 3, kStamp),
                             VibeFileEntry(@"/Music", @"two.flac", 3, kStamp)];
    _contents[@"/music/one.flac"] = [@"111" dataUsingEncoding:NSUTF8StringEncoding];
    _contents[@"/music/two.flac"] = [@"222" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *folder = [self refresh:@"/Music"];
    NSURL *one = [folder URLByAppendingPathComponent:@"one.flac"];
    NSURL *two = [folder URLByAppendingPathComponent:@"two.flac"];
    [self installMirrorFetch];
    XCTAssertTrue([self materialize:one]);
    XCTAssertTrue([self materialize:two]);
    XCTAssertEqual([self measuredDownloads], 6, @"both fit the 8-byte budget");

    XCTestExpectation *posted = [self expectationForNotification:VibeDropboxDownloadsDidChangeNotification
                                                          object:_mirror
                                                         handler:^BOOL(NSNotification *notification) {
        return [notification.userInfo[VibeDropboxDownloadsBytesKey] longLongValue] == 3;
    }];
    _mirror.downloadBudget = 4;
    XCTAssertEqual(_mirror.downloadBudget, 4);
    [self waitForExpectations:@[posted] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(StatOf(one).st_mode & 0777, 0, @"the oldest went back");
    XCTAssertEqualObjects([NSString stringWithContentsOfURL:two encoding:NSUTF8StringEncoding error:NULL], @"222");
    XCTAssertEqual([self measuredDownloads], 3);
}

// A file changed on Dropbox after it was downloaded goes back to a
// placeholder at the next listing, and the downloads' readers are told.
- (void)testARelistThatDiscardsADownloadTellsItsReaders {
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"one.flac", 5, kStamp)];
    _contents[@"/music/one.flac"] = [@"11111" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *folder = [self refresh:@"/Music"];
    [self installMirrorFetch];
    XCTAssertTrue([self materialize:[folder URLByAppendingPathComponent:@"one.flac"]]);

    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"one.flac", 6, @"2021-01-02T03:04:05Z")];
    XCTestExpectation *told = [self expectationForNotification:VibeDropboxDownloadsDidChangeNotification
                                                        object:_mirror
                                                       handler:^BOOL(NSNotification *notification) {
        return [notification.userInfo[VibeDropboxDownloadsBytesKey] longLongValue] == 0;
    }];
    [self refresh:@"/Music"];
    [self waitForExpectations:@[told] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(StatOf([folder URLByAppendingPathComponent:@"one.flac"]).st_mode & 0777, 0);
}

- (void)testRemovingDownloadsLeavesPlaceholdersAndSheets {
    NSData *sheet = [@"FILE \"one.flac\" WAVE\n" dataUsingEncoding:NSUTF8StringEncoding];
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"one.flac", 5, kStamp),
                             VibeFileEntry(@"/Music", @"one.cue", (long long)sheet.length, kStamp)];
    _contents[@"/music/one.flac"] = [@"11111" dataUsingEncoding:NSUTF8StringEncoding];
    _contents[@"/music/one.cue"] = sheet;
    NSURL *folder = [self refresh:@"/Music"];
    [self installMirrorFetch];
    XCTAssertTrue([self materialize:[folder URLByAppendingPathComponent:@"one.flac"]]);

    // The readers of a row's downloaded state (Search, the browser,
    // Settings) hear the removal, with nothing left counted. The fetch's own
    // post may still be in flight, so the handler waits for the empty one.
    XCTestExpectation *told = [self expectationForNotification:VibeDropboxDownloadsDidChangeNotification
                                                        object:_mirror
                                                       handler:^BOOL(NSNotification *notification) {
        return [notification.userInfo[VibeDropboxDownloadsBytesKey] longLongValue] == 0;
    }];
    XCTestExpectation *removed = [self expectationWithDescription:@"remove"];
    [_mirror removeDownloadsWithCompletion:^{
        [removed fulfill];
    }];
    [self waitForExpectations:@[told, removed] timeout:VIBE_TEST_HANG_TIMEOUT];
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
    dispatch_block_t cancelRead = [_client readTarget:@"/Music/a.flac" offset:0 length:8
                                         completion:^(NSData *data, NSDictionary *metadata, NSError *error) {
        XCTAssertNil(data);
        XCTAssertEqual(error.code, VibeDropboxErrorCancelled);
        [read fulfill];
    }];
    XCTestExpectation *download = [self expectationWithDescription:@"download"];
    dispatch_block_t cancelDownload = [_client downloadTarget:@"/Music/a.flac"
                                                      toURL:[_root URLByAppendingPathComponent:@"a.part"]
                                                   progress:nil
                                                 completion:^(NSDictionary *metadata, NSError *error) {
        XCTAssertNil(metadata);
        XCTAssertEqual(error.code, VibeDropboxErrorCancelled);
        [download fulfill];
    }];
    [self waitForRequests:1 toPath:@"/oauth2/token"];
    XCTAssertEqual([self requestsToPath:@"/oauth2/token"].count, 1u);
    cancelRead();
    cancelDownload();
    [self waitForExpectations:@[read, download] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 0u);
}

- (void)testCancellingAFetchStopsTheTransferAndLeavesThePlaceholder {
    _listings[@"/music"] = @[VibeFileEntry(@"/Music", @"slow.flac", 5, kStamp)];
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

    [self waitForRequests:1 toPath:@"/2/files/download"];
    XCTAssertEqual([self requestsToPath:@"/2/files/download"].count, 1u);
    [materializer cancel];

    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertFalse(materialized);
    XCTAssertEqualObjects(failure.domain, NSCocoaErrorDomain);
    XCTAssertEqual(failure.code, NSUserCancelledError);
    XCTAssertEqual(StatOf(track).st_mode & 0777, 0);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[PlaceholderFiles remotePlaceholderPartURL:track].path]);
}

#pragma mark Resumed downloads

// A resend can follow only a response that ended early, since Dropbox's
// status comes before any byte: a throttle or an expired token "mid-way" is
// the answer to the resume after a dropped connection.

// This test's downloads, whole and resumed, in order. TRAP: not every
// files/download request: an earlier test's mirror fetch reads its tail by a
// closed range beside the download, and on a loaded machine that read can
// start after this test's setUp, landing in this test's log.
- (NSArray<NSURLRequest *> *)downloadRequests {
    return [[self requestsToPath:@"/2/files/download"] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        return !VibeIsClosedRange(request);
    }]];
}

- (NSError *)downloadSong:(NSDictionary **)metadata {
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    __block NSError *failure = nil;
    __block NSDictionary *result = nil;
    [_client downloadTarget:@"/song.flac" toURL:[self partURL] progress:nil
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
    while ([self downloadRequests].count < count && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual([self downloadRequests].count, count);
}

- (void)testAThrottledResumeAppendsToTheSameFile {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    NSURL *part = [self partURL];
    NSMutableArray<NSNumber *> *inodes = [NSMutableArray array];
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return VibeDropped([self answer:request], request, 1600, [self partURL]);
        }
        @synchronized (inodes) {
            [inodes addObject:@(StatOf(part).st_ino)];
        }
        if (index == 1) {
            return DropboxStubJSON(429, @{@"error_summary": @"too_many_requests/"});
        }
        // Marked, to show the completion reports the first response's.
        return VibeDownloadAnswer(request, bytes, @{@"rev": kRev, @"server_modified": @"2021-01-01T00:00:00Z"});
    }];

    NSDictionary *metadata = nil;
    XCTAssertNil([self downloadSong:&metadata]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:part], bytes);
    XCTAssertEqualObjects(metadata[@"server_modified"], kStamp);
    NSArray<NSURLRequest *> *requests = [self downloadRequests];
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
            return VibeDropped([self answer:request], request, 1200, [self partURL]);
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
    NSURLRequest *resumed = [self downloadRequests].lastObject;
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
        return index < 3 ? VibeDropped([self answer:request], request, 1000, [self partURL]) : [self answer:request];
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    NSArray<NSURLRequest *> *requests = [self downloadRequests];
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
            return VibeDropped([self answer:request], request, 1000, [self partURL]);
        }
        DropboxStubResponse unreachable = {0};
        unreachable.failure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                                              userInfo:nil];
        return unreachable;
    }];

    NSError *error = [self downloadSong:NULL];
    XCTAssertEqualObjects(error.domain, NSURLErrorDomain);
    XCTAssertEqual(error.code, NSURLErrorNotConnectedToInternet);
    XCTAssertEqual([self downloadRequests].count, 3u, @"the first, then two resumes");
    XCTAssertEqual(StatOf([self partURL]).st_size, 1000, @"kept for the next download");
}

- (void)testAResumeAnsweringAnotherRevisionFailsAndDeletesThePart {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return VibeDropped([self answer:request], request, 1600, [self partURL]);
        }
        return VibeDownloadAnswer(request, bytes, @{@"rev": @"0200beef", @"server_modified": kStamp});
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
        DropboxStubResponse answer = VibeDownloadAnswer(request, bytes, @{@"server_modified": kStamp});
        return drop && index == 1 ? VibeDropped(answer, request, 1600, [self partURL]) : answer;
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
            return VibeDropped([self answer:request], request, 1600, [self partURL]);
        }
        NSMutableURLRequest *unranged = [request mutableCopy];
        [unranged setValue:nil forHTTPHeaderField:@"Range"];
        return [self answer:unranged];
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    XCTAssertEqualObjects([[self downloadRequests].lastObject valueForHTTPHeaderField:@"Range"],
                          @"bytes=1600-");
}

- (void)testCancellingDuringAResumeKeepsThePartAndCompletesOnce {
    _contents[@"/song.flac"] = PatternBytes(4000);
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return VibeDropped([self answer:request], request, 1600, [self partURL]);
        }
        return (DropboxStubResponse){0, nil, nil, YES};
    }];
    XCTestExpectation *done = [self expectationWithDescription:@"download"];
    __block NSInteger completions = 0;
    __block NSError *failure = nil;
    dispatch_block_t cancel = [_client downloadTarget:@"/song.flac" toURL:[self partURL] progress:nil
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
    NSArray<NSURLRequest *> *requests = [self downloadRequests];
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
        return VibeDownloadAnswer(request, newer, @{@"rev": @"0200beef", @"server_modified": kStamp});
    }];

    NSDictionary *metadata = nil;
    XCTAssertNil([self downloadSong:&metadata]);
    XCTAssertEqualObjects(metadata[@"rev"], @"0200beef");
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], newer);
    NSArray<NSURLRequest *> *requests = [self downloadRequests];
    XCTAssertEqual(requests.count, 2u, @"the resume, then the whole file");
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Range"], @"bytes=1600-");
    XCTAssertNil([requests[1] valueForHTTPHeaderField:@"Range"]);
}

// A kept part longer than the version now current asks for a range past
// that version's end, which Dropbox answers 416: the download starts over,
// whole, rather than failing the play.
- (void)testAKeptPartLongerThanTheCurrentVersionIsStartedOver {
    _contents[@"/song.flac"] = PatternBytes(4000);
    [self cancelADownloadAfter:1600];
    NSData *shorter = PatternBytes(1000);
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        return VibeDownloadAnswer(request, shorter, @{@"rev": @"0200beef", @"server_modified": kStamp});
    }];

    NSDictionary *metadata = nil;
    XCTAssertNil([self downloadSong:&metadata]);
    XCTAssertEqualObjects(metadata[@"rev"], @"0200beef");
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], shorter);
    NSArray<NSURLRequest *> *requests = [self downloadRequests];
    XCTAssertEqual(requests.count, 2u, @"the resume, then the whole file");
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Range"], @"bytes=1600-");
    XCTAssertNil([requests[1] valueForHTTPHeaderField:@"Range"]);
}

// A download of song.flac cancelled once its part holds `written` bytes,
// leaving the part; the request log is cleared for what follows.
- (void)cancelADownloadAfter:(NSUInteger)written {
    [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
        if (index == 0) {
            return VibeDropped([self answer:request], request, written, [self partURL]);
        }
        return (DropboxStubResponse){0, nil, nil, YES};
    }];
    XCTestExpectation *done = [self expectationWithDescription:@"cancelled"];
    dispatch_block_t cancel = [_client downloadTarget:@"/song.flac" toURL:[self partURL] progress:nil
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
        return VibeDropped([self answer:request], request, bytes.length, [self partURL]);
    }];

    XCTAssertNil([self downloadSong:NULL]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:[self partURL]], bytes);
    XCTAssertEqual([self downloadRequests].count, 1u);
}

// Short or long against its version's size, a file is not that version.
- (void)testADownloadOfAnotherLengthThanItsSizeFailsAndDeletesThePart {
    NSData *bytes = PatternBytes(4000);
    _contents[@"/song.flac"] = bytes;
    for (NSNumber *size in @[@3000, @5000]) {
        [self scriptDownloads:^DropboxStubResponse(NSInteger index, NSURLRequest *request) {
            return VibeDownloadAnswer(request, bytes, @{@"rev": kRev, @"server_modified": kStamp, @"size": size});
        }];
        NSError *error = [self downloadSong:NULL];
        XCTAssertEqualObjects(error.domain, VibeDropboxErrorDomain, @"size %@", size);
        XCTAssertEqual(error.code, VibeDropboxErrorAPI, @"size %@", size);
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[self partURL].path], @"size %@", size);
    }
}

@end
