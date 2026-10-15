// The search screen's Dropbox section over the real client and mirror, which
// answer from DropboxStubProtocol (DropboxMirrorTestCase).

#import "DropboxMirrorTestCase.h"

#import "DropboxSearch.h"

@interface DropboxSearchTests : DropboxMirrorTestCase
@end

@implementation DropboxSearchTests {
    DropboxSearch *_search;
    NSUInteger _changes;
}

- (void)setUp {
    [super setUp];
    _search = [[DropboxSearch alloc] initWithMirror:_mirror];
    __weak DropboxSearchTests *weakSelf = self;
    _search.changeHandler = ^{
        DropboxSearchTests *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_changes++;
        }
    };
    _searchEntries = @[VibeFileEntry(@"/Music", @"Song.mp3", 10, kStamp),
                       VibeFileEntry(@"/Music", @"Other.mp3", 10, kStamp),
                       VibeFolderEntry(@"/Music", @"Album")];
}

- (void)tearDown {
    [_search reset];
    [super tearDown];
}

- (NSArray<NSString *> *)hitNames {
    return [_search.hits valueForKey:@"name"];
}

- (void)testAQueryAsksAfterThePauseAndLeavesOutThePlaylist {
    _search.playlistPaths = [NSSet setWithObject:@"/music/other.mp3"];
    [_search searchQuery:@"so"];
    XCTAssertTrue(_search.isSearching);
    XCTAssertEqual([self requestsToPath:@"/2/files/search_v2"].count, 0u, @"nothing before the pause");
    XCTAssertTrue([self eventually:^BOOL { return !self->_search.isSearching; }]);
    XCTAssertFalse(_search.failed);
    XCTAssertEqualObjects(self.hitNames, (@[@"Song.mp3", @"Album"]));
    XCTAssertGreaterThan(_changes, 0u);
}

- (void)testTypingPastAQueryAsksOnlyTheLast {
    NSMutableArray<NSString *> *queries = [NSMutableArray array];
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/2/files/search_v2"]) {
            @synchronized (queries) {
                [queries addObject:json[@"query"] ?: @"?"];
            }
        }
        return [self defaultResponseFor:request json:json];
    }];
    [_search searchQuery:@"s"];
    [_search searchQuery:@"so"];
    [_search searchQuery:@"son"];
    XCTAssertTrue([self eventually:^BOOL { return !self->_search.isSearching; }]);
    @synchronized (queries) {
        XCTAssertEqualObjects(queries, @[@"son"]);
    }
}

- (void)testTheSameQueryReappliesTheExclusionAndAsksNothing {
    [_search searchQuery:@"so"];
    XCTAssertTrue([self eventually:^BOOL { return !self->_search.isSearching; }]);
    [self clearRequests];
    _search.playlistPaths = [NSSet setWithObject:@"/music/song.mp3"];
    [_search searchQuery:@"so"];
    XCTAssertFalse(_search.isSearching);
    XCTAssertEqualObjects(self.hitNames, (@[@"Other.mp3", @"Album"]));
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    XCTAssertEqual([self requestsToPath:@"/2/files/search_v2"].count, 0u);
}

- (void)testAFailureIsNotAnEmptyAnswer {
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        if ([request.URL.path isEqualToString:@"/2/files/search_v2"]) {
            return DropboxStubJSON(400, @{@"error_summary": @"bad"});
        }
        return [self defaultResponseFor:request json:json];
    }];
    [_search searchQuery:@"so"];
    XCTAssertTrue([self eventually:^BOOL { return !self->_search.isSearching; }]);
    XCTAssertTrue(_search.failed);
    XCTAssertEqualObjects(_search.hits, @[]);
}

- (void)testAResetDropsTheAnswerInFlight {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [self installHandler:^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        DropboxStubResponse answer = [self defaultResponseFor:request json:json];
        if ([request.URL.path isEqualToString:@"/2/files/search_v2"]) {
            answer.gate = gate;
        }
        return answer;
    }];
    [_search searchQuery:@"so"];
    [self waitForRequests:1 toPath:@"/2/files/search_v2"];
    [_search reset];
    NSUInteger changes = _changes;
    dispatch_semaphore_signal(gate);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    XCTAssertEqual(_changes, changes);
    XCTAssertEqualObjects(_search.hits, @[]);
    XCTAssertFalse(_search.isSearching);
}

- (void)testTheDownloadedSetIsTheFilesTheMirrorHoldsBytesFor {
    NSURL *song = [_mirror.accountURL URLByAppendingPathComponent:@"Music/Song.mp3"];
    [NSFileManager.defaultManager createDirectoryAtURL:song.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSData dataWithBytes:"bytes" length:5] writeToURL:song atomically:YES];
    [_search searchQuery:@"so"];
    XCTAssertTrue([self eventually:^BOOL { return self->_search.downloaded.count > 0; }]);
    XCTAssertEqualObjects(_search.downloaded, [NSSet setWithObject:@"/music/song.mp3"]);
}

@end
