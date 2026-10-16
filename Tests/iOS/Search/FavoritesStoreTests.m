// FavoritesStore over the process's in-memory defaults and real bookmarks of
// temp folders. A store of its own (initPrivate) reads what a relaunch reads.

#import "IOSShellTestCase.h"

#import "FavoritesStoreInternal.h"
#import "FilePaths.h"

@interface FavoritesStoreTests : IOSShellTestCase
@end

@implementation FavoritesStoreTests {
    NSUInteger _changes;
    id _observer;
}

- (void)setUp {
    [super setUp];
    _changes = 0;
    __weak FavoritesStoreTests *weakSelf = self;
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:VibeFavoritesDidChangeNotification
                                                                object:nil queue:nil
                                                            usingBlock:^(NSNotification *note) {
        FavoritesStoreTests *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_changes++;
        }
    }];
}

- (void)tearDown {
    [NSNotificationCenter.defaultCenter removeObserver:_observer];
    [super tearDown];
}

- (NSData *)bookmark:(NSURL *)url {
    return [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];
}

- (NSURL *)star:(NSString *)relativePath {
    NSURL *folder = [self folder:relativePath];
    [FavoritesStore.shared addFolderURL:folder bookmark:[self bookmark:folder]];
    return folder;
}

- (NSArray<NSString *> *)names:(FavoritesStore *)store {
    return [store.favorites valueForKey:@"name"];
}

#pragma mark - Adding and removing

- (void)testAStarRecordsWhatTheRowDrawsInStarOrder {
    NSURL *disc = [self star:@"Album/Disc 1"];
    [self star:@"Other"];
    XCTAssertEqualObjects([self names:FavoritesStore.shared], (@[@"Disc 1", @"Other"]));
    FavoriteFolder *first = FavoritesStore.shared.favorites.firstObject;
    XCTAssertEqualObjects(first.location, @"Album", @"the containing folder tells two Disc 1s apart");
    XCTAssertEqualObjects(first.path, VibeComparablePath(disc.path));
    XCTAssertTrue([FavoritesStore.shared containsFolderURL:disc]);
    XCTAssertEqual(_changes, 2u);
}

- (void)testStarringTwiceOrWithoutABookmarkIsANoOp {
    NSURL *folder = [self star:@"Album"];
    [FavoritesStore.shared addFolderURL:folder bookmark:[self bookmark:folder]];
    NSData *none = nil;
    [FavoritesStore.shared addFolderURL:[self folder:@"Unminted"] bookmark:none];
    XCTAssertEqual(FavoritesStore.shared.favorites.count, 1u);
    XCTAssertEqual(_changes, 1u);
}

- (void)testNestedFavoritesAreDistinctPlaces {
    NSURL *outer = [self star:@"Music"];
    NSURL *inner = [self star:@"Music/Album"];
    XCTAssertEqual(FavoritesStore.shared.favorites.count, 2u);
    [FavoritesStore.shared removeFolderURL:outer];
    XCTAssertTrue([FavoritesStore.shared containsFolderURL:inner]);
    XCTAssertFalse([FavoritesStore.shared containsFolderURL:outer]);
}

- (void)testRemovalByIndexOrUnknownURLStaysInRange {
    [self star:@"A"];
    [FavoritesStore.shared removeFolderURL:[self folder:@"NotStarred"]];
    [FavoritesStore.shared removeFavoriteAtIndex:5];
    XCTAssertEqual(FavoritesStore.shared.favorites.count, 1u);
    [FavoritesStore.shared removeFavoriteAtIndex:0];
    XCTAssertEqualObjects(FavoritesStore.shared.favorites, @[]);
}

#pragma mark - Persistence

- (void)testARelaunchReadsTheFavoritesInStarOrder {
    [self star:@"B"];
    [self star:@"A"];
    FavoritesStore *relaunched = [[FavoritesStore alloc] initPrivate];
    XCTAssertEqualObjects([self names:relaunched], (@[@"B", @"A"]));
    XCTAssertEqualObjects(relaunched.searchRoots, @[], @"nothing resolves at launch");
}

- (void)testARelaunchSkipsAMalformedRecord {
    [self star:@"Kept"];
    NSMutableArray *records = [[NSUserDefaults.standardUserDefaults arrayForKey:@"VibeiOSFavoriteFolders"] mutableCopy];
    [records addObject:@{@"name": @"No bookmark", @"location": @"", @"path": @"/x"}];
    [records addObject:@{@"name": @"Empty path", @"location": @"", @"path": @"", @"bookmark": [NSData data]}];
    [records addObject:@"junk"];
    [NSUserDefaults.standardUserDefaults setObject:records forKey:@"VibeiOSFavoriteFolders"];
    XCTAssertEqualObjects([self names:[[FavoritesStore alloc] initPrivate]], @[@"Kept"]);
}

- (void)testRemovingTheLastFavoriteForgetsTheKey {
    [self star:@"A"];
    [FavoritesStore.shared removeFavoriteAtIndex:0];
    XCTAssertNil([NSUserDefaults.standardUserDefaults objectForKey:@"VibeiOSFavoriteFolders"]);
}

#pragma mark - Resolving

- (NSURL *)resolve:(FavoriteFolder *)favorite {
    XCTestExpectation *resolved = [self expectationWithDescription:@"resolved"];
    __block NSURL *answer = nil;
    [FavoritesStore.shared resolveFavorite:favorite completion:^(NSURL *url) {
        XCTAssertTrue(NSThread.isMainThread);
        answer = url;
        [resolved fulfill];
    }];
    [self waitForExpectations:@[resolved] timeout:VIBE_TEST_HANG_TIMEOUT];
    return answer;
}

- (void)testATapResolvesWhereTheFolderIsNow {
    NSURL *folder = [self star:@"Album"];
    NSURL *moved = [self.root URLByAppendingPathComponent:@"Renamed" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:folder toURL:moved error:NULL]);
    NSURL *url = [self resolve:FavoritesStore.shared.favorites.firstObject];
    XCTAssertEqualObjects(VibeComparablePath(url.path), VibeComparablePath(moved.path));
}

- (void)testAnUnreachableFavoriteResolvesToNilAndKeepsItsRow {
    [self star:@"Gone"];
    [NSFileManager.defaultManager removeItemAtURL:[self.root URLByAppendingPathComponent:@"Gone"] error:NULL];
    XCTAssertNil([self resolve:FavoritesStore.shared.favorites.firstObject]);
    XCTAssertEqual(FavoritesStore.shared.favorites.count, 1u);
}

#pragma mark - The search scope

- (void)testTheSearchScopeResolvesOnlyWhenPreparedAndAnswersTheLongestMatch {
    NSURL *outer = [self star:@"Music"];
    NSURL *inner = [self star:@"Music/Album"];
    NSURL *song = [inner URLByAppendingPathComponent:@"Song.mp3"];
    XCTAssertNil([FavoritesStore.shared resolvedRootCoveringURL:song], @"nothing resolved before Search");
    [FavoritesStore.shared prepareSearchScope];
    XCTAssertTrue([self eventually:^BOOL { return FavoritesStore.shared.searchRoots.count == 2; }]);
    XCTAssertEqualObjects(VibeComparablePath([FavoritesStore.shared resolvedRootCoveringURL:song].path),
                          VibeComparablePath(inner.path));
    XCTAssertEqualObjects(VibeComparablePath([FavoritesStore.shared resolvedRootCoveringURL:[outer URLByAppendingPathComponent:@"x.mp3"]].path),
                          VibeComparablePath(outer.path));
    XCTAssertNil([FavoritesStore.shared resolvedRootCoveringURL:[self file:@"Elsewhere/x.mp3"]]);

    [FavoritesStore.shared removeFolderURL:inner];
    XCTAssertEqualObjects(VibeComparablePath([FavoritesStore.shared resolvedRootCoveringURL:song].path),
                          VibeComparablePath(outer.path), @"a removed favorite is no longer a root");
}

- (void)testAStarAfterSearchAppearedJoinsTheScope {
    [FavoritesStore.shared prepareSearchScope];
    [self star:@"Late"];
    XCTAssertTrue([self eventually:^BOOL { return FavoritesStore.shared.searchRoots.count == 1; }]);
}

@end
