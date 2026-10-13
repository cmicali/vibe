//
//  DropboxMirrorTestCase.m
//

#import "DropboxMirrorTestCase.h"

DropboxStubResponse VibeDownloadAnswer(NSURLRequest *request, NSData *bytes, NSDictionary *metadata) {
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
    if (first >= bytes.length) {
        NSData *body = [@"{\"error_summary\": \"range not satisfiable\"}" dataUsingEncoding:NSUTF8StringEncoding];
        return (DropboxStubResponse){416, @{@"Content-Type": @"application/json"}, body, NO};
    }
    last = MIN(last, (unsigned long long)bytes.length - 1);
    NSData *slice = [bytes subdataWithRange:NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1))];
    return (DropboxStubResponse){206, headers, slice, NO};
}

DropboxStubResponse VibeDropped(DropboxStubResponse answer, NSURLRequest *request, NSUInteger delivered,
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

NSDictionary *VibeFileEntry(NSString *folder, NSString *name, long long size, NSString *modified) {
    NSString *path = [folder stringByAppendingPathComponent:name];
    return @{@".tag": @"file", @"name": name, @"path_display": path, @"id": [@"id:" stringByAppendingString:path.lowercaseString],
             @"path_lower": path.lowercaseString, @"size": @(size), @"server_modified": modified};
}

NSDictionary *VibeFolderEntry(NSString *folder, NSString *name) {
    NSString *path = [folder stringByAppendingPathComponent:name];
    return @{@".tag": @"folder", @"name": name, @"path_display": path, @"id": [@"id:" stringByAppendingString:path.lowercaseString],
             @"path_lower": path.lowercaseString};
}

BOOL VibeIsClosedRange(NSURLRequest *request) {
    NSString *range = [request valueForHTTPHeaderField:@"Range"];
    return range && ![range hasSuffix:@"-"];
}

@implementation DropboxMirrorTestCase

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
    _client.retryDelayScale = 0.01;
    _mirror = [[DropboxMirror alloc] initWithClient:_client rootURL:_root downloadBudget:8];
    // A held stream must never fall through to a ranged read under a test.
    _mirror.streamedTagWait = VIBE_TEST_GATE_TIMEOUT;
    [_client adoptRefreshToken:@"R1" accountID:@"dbid:test"];
}

- (void)tearDown {
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

- (void)waitForRequests:(NSUInteger)count toPath:(NSString *)path {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while ([self requestsToPath:path].count < count && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
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
        return VibeDownloadAnswer(request, bytes, @{@"server_modified": kStamp, @"size": @(bytes.length), @"rev": kRev});
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

- (NSURL *)partURL {
    NSURL *account = _mirror.accountURL;
    [NSFileManager.defaultManager createDirectoryAtURL:account withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    return [account URLByAppendingPathComponent:@"song.flac.part"];
}

- (void)scriptDownloads:(DropboxStubResponse (^)(NSInteger index, NSURLRequest *request))script {
    __block NSInteger downloads = 0;
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if (![request.URL.path isEqualToString:@"/2/files/download"]) {
            return [self defaultResponseFor:request json:json];
        }
        if (VibeIsClosedRange(request)) {
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

@end
